/// Metal source for the 3D cloth viewer. The RTI is evaluated per fragment with the light expressed in
/// that fragment's own surface frame (tangent = panel x, bitangent = panel y, normal), rotated into the
/// textile's frame (grain) and mirrored for mirrored tiles. See docs/cloth-viewer.md.
let clothShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U {
    float4x4 viewProj;
    float4x4 lightViewProj;
    float4 camPos;
    float4 lightDir;      // towards the light, world
    float4 grain;         // cos, sin, tiling (0 off, 1 repeat, 2 mirror), unused
    float4 sample;        // sample width, height, tile width, tile height (metres)
    float4 rrect;         // repeat rect u0, v0, du, dv
    float4 params;        // k, basis (0 ptm, 1 hsh), gain, mode (0 rti, 1 specular, 2 shaded, 3 normals)
    float4 params2;       // sheen, use mask, has verso, show grainline
    float4 params3;       // verso k, verso basis, ambient, shadow bias
    float4 scale[7];
    float4 bias[7];
    float4 vscale[7];
    float4 vbias[7];
};

struct CV { float4 pos; float4 nrm; float4 tan; float4 panel; };
struct PV { float4 pos; float4 nrm; };

struct COut {
    float4 position [[position]];
    float3 world;
    float3 n;
    float3 t;
    float2 panel;
    float4 lpos;
};

vertex COut clothVS(uint vid [[vertex_id]], const device CV* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    CV c = v[vid];
    COut o;
    o.position = u.viewProj * float4(c.pos.xyz, 1);
    o.world = c.pos.xyz;
    o.n = c.nrm.xyz;
    o.t = c.tan.xyz;
    o.panel = c.panel.xy;
    o.lpos = u.lightViewProj * float4(c.pos.xyz, 1);
    return o;
}

vertex float4 clothShadowVS(uint vid [[vertex_id]], const device CV* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    return u.lightViewProj * float4(v[vid].pos.xyz, 1);
}

static float at(constant float4* a, int i) { return a[i / 4][i % 4]; }

static void basisWeights(float2 l, int basis, thread float* w) {
    if (basis == 0) {
        w[0] = 1; w[1] = l.x; w[2] = l.y; w[3] = l.x * l.x; w[4] = l.x * l.y; w[5] = l.y * l.y;
        w[6] = 0; w[7] = 0; w[8] = 0;
        return;
    }
    float lz = sqrt(max(0.0, 1.0 - dot(l, l)));
    float phi = atan2(l.y, l.x);
    if (phi < 0) phi += 2.0 * M_PI_F;
    float theta = min(acos(min(1.0, lz)), M_PI_F / 2.0 - 0.01);
    float cosP = cos(phi), sinP = sin(phi), cosT = cos(theta), cosT2 = cosT * cosT;
    float s = sqrt(max(0.0, cosT - cosT2));
    w[0] = 1.0 / sqrt(2.0 * M_PI_F);
    w[1] = sqrt(6.0 / M_PI_F) * cosP * s;
    w[2] = sqrt(3.0 / (2.0 * M_PI_F)) * (-1.0 + 2.0 * cosT);
    w[3] = sqrt(6.0 / M_PI_F) * s * sinP;
    w[4] = sqrt(30.0 / M_PI_F) * cos(2.0 * phi) * (-cosT + cosT2);
    w[5] = sqrt(30.0 / M_PI_F) * cosP * (-1.0 + 2.0 * cosT) * s;
    w[6] = sqrt(5.0 / (2.0 * M_PI_F)) * (1.0 - 6.0 * cosT + 6.0 * cosT2);
    w[7] = sqrt(30.0 / M_PI_F) * (-1.0 + 2.0 * cosT) * s * sinP;
    w[8] = sqrt(30.0 / M_PI_F) * (-cosT + cosT2) * sin(2.0 * phi);
}

/// Σ_j w_j(L) · (tex_j − bias) · scale, with L in the textile frame. Grazing lights are clamped to
/// ~6° elevation: RTI fits are not reliable below what was captured.
static float3 evalRTI(texture2d_array<float> planes, sampler s, float2 uv, float2 gx, float2 gy, float3 L, int k, int basis,
                      constant float4* sc, constant float4* bi) {
    float3 l = L;
    if (l.z < 0.1) {
        float r = length(l.xy);
        l.xy = r > 0 ? l.xy / r * 0.995 : float2(0);
    }
    float w[9];
    basisWeights(l.xy, basis, w);
    float3 rgb = float3(0);
    for (int j = 0; j < k; j++) {
        float3 c = planes.sample(s, uv, uint(j), gradient2d(gx, gy)).rgb;
        float3 scl = float3(at(sc, j * 3), at(sc, j * 3 + 1), at(sc, j * 3 + 2));
        float3 b = float3(at(bi, j * 3), at(bi, j * 3 + 1), at(bi, j * 3 + 2));
        rgb += w[j] * (c - b) * scl;
    }
    return max(rgb, float3(0));
}

static float2 rot(float2 v, float c, float s) { return float2(c * v.x + s * v.y, -s * v.x + c * v.y); }   // by −angle
static float2 rotBack(float2 v, float c, float s) { return float2(c * v.x - s * v.y, s * v.x + c * v.y); } // by +angle

static float shadowAt(depth2d<float> shadow, float4 lpos, float bias) {
    float3 lp = lpos.xyz / lpos.w;
    float2 suv = float2(lp.x * 0.5 + 0.5, 0.5 - lp.y * 0.5);
    if (suv.x < 0 || suv.y < 0 || suv.x > 1 || suv.y > 1) return 1.0;
    constexpr sampler ss(filter::linear, compare_func::less_equal, address::clamp_to_edge);
    float sum = 0;
    float texel = 1.0 / 2048.0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            sum += shadow.sample_compare(ss, suv + float2(x, y) * texel * 1.5, lp.z - bias);
    return sum / 9.0;
}

fragment float4 clothFS(COut in [[stage_in]], bool front [[front_facing]], constant U& u [[buffer(1)]],
                        texture2d_array<float> planes [[texture(0)]], texture2d<float> normals [[texture(1)]],
                        texture2d<float> mask [[texture(2)]], depth2d<float> shadow [[texture(3)]],
                        texture2d_array<float> vplanes [[texture(4)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
    float c = u.grain.x, sn = u.grain.y;
    int tiling = int(u.grain.z);
    float2 q = rot(in.panel, c, sn);                       // textile frame (metres)
    float2 uv, uvc, flip = float2(1, 1);
    if (tiling == 0) {
        uv = float2(q.x / u.sample.x + 0.5, 0.5 - q.y / u.sample.y);
        uvc = uv;
        if (uv.x < 0 || uv.y < 0 || uv.x > 1 || uv.y > 1) discard_fragment();
        if (u.params2.y > 0.5 && mask.sample(s, uv).r < 0.5) discard_fragment();
    } else {
        float2 t = float2(q.x / u.sample.z, -q.y / u.sample.w) + 0.5;
        float2 cell = floor(t);
        float2 f = t - cell;
        if (tiling == 2) {
            if (fmod(abs(cell.x), 2.0) > 0.5) { f.x = 1 - f.x; flip.x = -1; }
            if (fmod(abs(cell.y), 2.0) > 0.5) { f.y = 1 - f.y; flip.y = -1; }
        }
        uv = u.rrect.xy + f * u.rrect.zw;
        uvc = u.rrect.xy + t * u.rrect.zw;
    }
    float2 gx = dfdx(uvc), gy = dfdy(uvc);

    float3 N = normalize(in.n);
    float3 T = normalize(in.t - N * dot(N, in.t));
    float3 B = cross(N, T);
    bool back = !front;
    if (back) { N = -N; T = -T; }                          // the reverse is a mirror image
    float3 L = normalize(u.lightDir.xyz);
    float3 V = normalize(u.camPos.xyz - in.world);
    float3 Ll = float3(dot(L, T), dot(L, B), dot(L, N));
    float3 Vl = float3(dot(V, T), dot(V, B), dot(V, N));
    Ll.xy = rot(Ll.xy, c, sn) * flip;
    Vl.xy = rot(Vl.xy, c, sn) * flip;

    float sh = shadowAt(shadow, in.lpos, u.params3.w);
    float facing = smoothstep(0.0, 0.12, Ll.z);
    int mode = int(u.params.w);

    // detail normal from the photometric-stereo map, back into world space
    float3 nd = normals.sample(s, back ? float2(1 - uv.x, uv.y) : uv, gradient2d(gx, gy)).rgb * 2.0 - 1.0;
    if (back && u.params2.z < 0.5) nd = float3(0, 0, 1);
    nd.xy *= flip;
    nd.xy = rotBack(nd.xy, c, sn);
    float3 Nw = normalize(T * nd.x + B * nd.y + N * nd.z);

    if (mode == 3) return float4(Nw * 0.5 + 0.5, 1);
    if (mode == 2) {
        float d = max(dot(Nw, L), 0.0) * sh;
        return float4(float3(0.05 + 0.9 * d), 1);
    }

    float3 Le = Ll;
    if (u.params2.x > 0.5) {
        // sheen: keep highlights where the half vector says they should be (capture view = +z)
        float3 H = normalize(Ll + Vl);
        Le = 2.0 * H.z * H - float3(0, 0, 1);
    }
    float ambient = u.params3.z;
    float3 rgb;
    if (back && u.params2.z < 0.5) {
        rgb = float3(0.58, 0.53, 0.46) * (ambient + (1.0 - ambient) * max(dot(N, L), 0.0) * sh);
    } else if (back) {
        float2 vuv = float2(1 - uv.x, uv.y);
        int vk = int(u.params3.x), vb = int(u.params3.y);
        float3 lit = evalRTI(vplanes, s, vuv, gx, gy, Le, vk, vb, u.vscale, u.vbias);
        float3 amb = evalRTI(vplanes, s, vuv, gx, gy, float3(0, 0, 1), vk, vb, u.vscale, u.vbias);
        rgb = lit * facing * sh + amb * ambient;
    } else {
        int k = int(u.params.x), b = int(u.params.y);
        float3 lit = evalRTI(planes, s, uv, gx, gy, Le, k, b, u.scale, u.bias);
        float3 amb = evalRTI(planes, s, uv, gx, gy, float3(0, 0, 1), k, b, u.scale, u.bias);
        rgb = lit * facing * sh + amb * ambient;
    }
    if (mode == 1) {
        float3 H = normalize(L + V);
        rgb = rgb * 0.8 + float3(pow(max(dot(Nw, H), 0.0), 40.0) * 0.5 * sh);
    }
    rgb *= u.params.z;
    if (u.params2.w > 0.5 && abs(q.x) < 0.0025) rgb = mix(rgb, float3(0.9, 0.1, 0.1), 0.85);   // warp grainline
    return float4(saturate(rgb), 1);
}

struct POut {
    float4 position [[position]];
    float3 world;
    float3 n;
    float4 lpos;
};

vertex POut propVS(uint vid [[vertex_id]], const device PV* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    POut o;
    o.position = u.viewProj * float4(v[vid].pos.xyz, 1);
    o.world = v[vid].pos.xyz;
    o.n = v[vid].nrm.xyz;
    o.lpos = u.lightViewProj * float4(v[vid].pos.xyz, 1);
    return o;
}

vertex float4 propShadowVS(uint vid [[vertex_id]], const device PV* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    return u.lightViewProj * float4(v[vid].pos.xyz, 1);
}

fragment float4 propFS(POut in [[stage_in]], constant U& u [[buffer(1)]], constant float4& color [[buffer(2)]],
                       depth2d<float> shadow [[texture(3)]]) {
    float3 N = normalize(in.n);
    float3 V = normalize(u.camPos.xyz - in.world);
    if (dot(N, V) < 0) N = -N;
    float3 L = normalize(u.lightDir.xyz);
    float sh = shadowAt(shadow, in.lpos, u.params3.w * 2.0);
    float d = max(dot(N, L), 0.0) * sh;
    return float4(color.rgb * (0.22 + 0.78 * d), 1);
}

// AR: the camera image as background (BT.601 full-range Y'CbCr from ARKit)
struct BGOut {
    float4 position [[position]];
    float2 uv;
};

vertex BGOut bgVS(uint vid [[vertex_id]], constant float4* q [[buffer(0)]]) {
    BGOut o;
    o.position = float4(q[vid].xy, 1.0, 1.0);
    o.uv = q[vid].zw;
    return o;
}

fragment float4 bgFS(BGOut in [[stage_in]], texture2d<float> yTex [[texture(0)]], texture2d<float> cTex [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = yTex.sample(s, in.uv).r;
    float2 c = cTex.sample(s, in.uv).rg - 0.5;
    float3 rgb = float3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x);
    return float4(saturate(rgb), 1);
}

// AR: invisible floor that only darkens where the cloth and form cast shadows
fragment float4 catcherFS(POut in [[stage_in]], constant U& u [[buffer(1)]], depth2d<float> shadow [[texture(3)]]) {
    float sh = shadowAt(shadow, in.lpos, u.params3.w * 2.0);
    return float4(0, 0, 0, (1.0 - sh) * 0.5);
}

struct PinOut {
    float4 position [[position]];
    float size [[point_size]];
};

vertex PinOut pinVS(uint vid [[vertex_id]], const device float4* p [[buffer(0)]], constant U& u [[buffer(1)]]) {
    PinOut o;
    o.position = u.viewProj * float4(p[vid].xyz, 1);
    o.size = p[vid].w;
    return o;
}

fragment float4 pinFS(PinOut in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5);
    if (d > 0.5) discard_fragment();
    return d < 0.3 ? float4(0.85, 0.12, 0.16, 1) : float4(0.97, 0.97, 0.95, 1);
}
"""
