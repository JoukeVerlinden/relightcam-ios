# Design note: 3D cloth viewer for historical textiles

**Status: proposed, not implemented.** This describes a possible future viewer mode for relightCam.

## Goal

Let a captured textile be draped, folded, hung or handled as a virtual 3D cloth, moved by touch or by tilting
the phone, under a fixed or a moving light, while keeping its captured appearance. The focus is historical
textiles and samples: silk floats, metal threads, tapestry weave, worn and irregular fragments.

## Core idea: relight each point in its own frame

An RTI (PTM/HSH) stores, per pixel, how that point responds to a light direction measured **relative to the
flat fabric** (its tangent frame). The current viewer evaluates

```
color(p) = Σ_j  w_j(L) · coef_j(p)
```

with `L` the light direction in image space. On a deformed cloth, each fragment has its own surface frame
(tangent T, bitangent B, normal N from the mesh). Transform the world light into that frame first:

```
L_local = normalize( [T B N]ᵀ · L_world )
color(p) = Σ_j  w_j(L_local) · coef_j(p)
```

A fold facing the lamp then shows exactly what that part of the fabric looked like under a light from that
side during capture. Fine structure (weave, threads, inter-reflections) stays as captured; the large-scale
shape comes from the mesh. If `L_local.z ≤ 0` the point faces away from the light and is in shadow.

### View dependence (the honest limit)

The capture was taken from straight above. A fold seen at an angle was never captured from that angle.

- **Matte fabrics** (wool, linen, felt): view direction barely matters, so the result is correct.
- **Shiny materials** (silk, metal threads, glazed or calendered finishes): use a half-vector substitution
  that keeps highlights in the right place. With view `V_local` and light `L_local`, compute
  `H = normalize(L_local + V_local)` and evaluate the RTI at `L_eff = 2(H·Z)H − Z`, with `Z = (0,0,1)`, the
  capture view. This is plausible, not measured.

The viewer should say plainly that this is a visual simulation, not a prediction of how the real object
drapes or reflects.

## Cloth simulation

- **Method:** XPBD (extended position-based dynamics) on a regular particle grid aligned with the image,
  about 64×64 to 128×128 particles. Constraints: stretch (structural), shear, bending, plus collisions with
  supports. CPU with SIMD first; Metal compute if more resolution is needed.
- **Anisotropy:** separate warp and weft stiffness. The user sets the warp direction (default: image vertical).
- **Presets:** silk (light, low bending), linen, wool (heavier), tapestry (stiff, heavy), rigid (sample on board).
- **Supports:** hang from a rod (top edge pinned), lie on a table, drape over a padded roll or bolster, pin at
  chosen points, or float freely.
- **Real scale:** physics only looks right at real size. Ask for the reference sphere's real diameter
  (e.g. 25 mm). The app already knows its radius in pixels, which gives mm per pixel; store it as
  `pixelSizeInMM` in `info.json` (a key relight already uses).
- **Irregular fragments:** cut the textile out from the background (Vision foreground mask, with manual
  touch-up), leave out the calibration sphere, and drop particles outside the mask, so the mesh follows the
  fragment's outline.

## Interaction

| Input | Effect |
|---|---|
| One finger on the cloth | grab and drag that point (ray cast to the mesh, temporary pin) |
| Pinch / two fingers | zoom / orbit the camera |
| Tilt the phone | world gravity follows the device, so the cloth swings and slides |
| Light modes | *fixed lamp* in the room · *finger-controlled* (as now) · *orbiting raking light*, a slow circle at low elevation that shows weave structure well |
| Toggle | rigid ↔ cloth, support type, material preset |

## Rendering

- Metal mesh pipeline; per-frame vertex positions from the simulation, normals and tangents recomputed per
  frame from the grid.
- Fragment shader: the same PTM/HSH evaluation as `RTIMetalView.swift`, with the light in the local frame.
- Self-shadowing of folds with one shadow map per light; optional screen-space ambient occlusion.
- **Reverse side:** if recto and verso were captured as two RTIs, show the verso on back faces (the reverse
  of a sample often shows floats and repairs). Otherwise show a neutral textile color.

## Phases

1. **Rigid sample board in 3D:** perspective camera; tilt or orbit a flat plane; local-frame RTI evaluation;
   fixed and moving light. Tests the math with no physics and is already useful for mounted samples.
2. Textile cutout mask and real-scale calibration from the sphere diameter.
3. XPBD cloth: presets, warp/weft stiffness, supports, finger dragging, tilt as gravity.
4. Shadows, verso support, orbiting raking light, sheen approximation for silk and metal threads.
5. Optional: AR. Bake a draped snapshot to USDZ with a PBR material (albedo, normal map from photometric
   stereo, estimated roughness) to place on a real table with AR Quick Look. This is less faithful than the
   RTI viewer, because AR viewers can't evaluate an RTI.

## Open questions

- Which textiles matter most: shiny (silk, metal threads; these lean on the view approximation) or matte
  (wool, linen)?
- Will recto and verso be captured?
- Typical sample size, and whether the samples are fragile fragments or complete pieces (sets the default
  supports and presets).
- Audience: research/conservation (show the limits and measurements) or public display (simpler controls).
