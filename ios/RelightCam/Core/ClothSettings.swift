import Foundation

/// How the cloth is held in the 3D cloth viewer.
enum ClothSupport: String, Codable, CaseIterable, Identifiable {
    case board, dressForm, free
    var id: String { rawValue }

    /// Older projects may have saved supports that no longer exist: a rod is the same as hanging free,
    /// table and roll open on the board.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ClothSupport(rawValue: raw) ?? (raw == "rod" ? .free : .board)
    }
    var title: String {
        switch self {
        case .board: return "Board"
        case .dressForm: return "Dress form"
        case .free: return "Free"
        }
    }
    var symbol: String {
        switch self {
        case .board: return "rectangle"
        case .dressForm: return "figure.stand.dress"
        case .free: return "hand.raised"
        }
    }
}

/// Fabric presets. Relaxation values are dimensionless per-substep compliances (0 = rigid), so behaviour
/// does not depend on grid resolution or mass.
enum ClothMaterial: String, Codable, CaseIterable, Identifiable {
    case silk, linen, wool, tapestry
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// kg/m²
    var density: Float { [0.05, 0.18, 0.30, 0.80][index] }
    /// along the threads (warp/weft): essentially inextensible
    var threadCompliance: Float { [0.0005, 0.0003, 0.0004, 0.0001][index] }
    /// along the bias (45° to the threads): the weave shears, so this is where fabric stretches
    var biasCompliance: Float { [0.08, 0.02, 0.04, 0.004][index] }
    /// Peirce cantilever bending length c (metres): how far the fabric sticks out before it droops.
    /// Bending rigidity follows as B = weight · c³ (N·m).
    var bendingLength: Float { [0.012, 0.030, 0.025, 0.070][index] }
    /// The multi-scale bending constraints overestimate stiffness a little; these factors were
    /// calibrated so the Peirce test (overhang 2c → ≈41.5° droop) holds (tools/cloth_test.swift).
    var bendingCalibration: Float { [1.0, 0.22, 0.22, 0.62][index] }
    var bendingRigidity: Float { density * 9.81 * bendingLength * bendingLength * bendingLength * bendingCalibration }
    var friction: Float { [0.25, 0.4, 0.55, 0.6][index] }
    /// collision thickness, metres
    var thickness: Float { [0.0015, 0.002, 0.003, 0.005][index] }
    var damping: Float { [0.6, 0.9, 1.0, 1.4][index] }
    var defaultSheen: Bool { self == .silk }
    private var index: Int { ClothMaterial.allCases.firstIndex(of: self)! }
}

enum ClothTiling: String, Codable, CaseIterable, Identifiable {
    case off, repeating, mirrored
    var id: String { rawValue }
    var title: String { ["Off", "Repeat", "Mirror repeat"][ClothTiling.allCases.firstIndex(of: self)!] }
}

enum ClothLightMode: String, Codable, CaseIterable, Identifiable {
    case lamp, headlamp, orbit
    var id: String { rawValue }
    var title: String { ["Lamp", "Headlamp", "Orbit"][ClothLightMode.allCases.firstIndex(of: self)!] }
}

enum ClothTiltMode: String, Codable, CaseIterable, Identifiable {
    case off, room, walkAround
    var id: String { rawValue }
    var title: String { ["Off", "Room", "Walk around"][ClothTiltMode.allCases.firstIndex(of: self)!] }
    var help: String {
        switch self {
        case .off: return "Tilt does nothing."
        case .room: return "The scene is inside the phone; lamp and gravity stay in the room. Tilt to swing the cloth and move the light."
        case .walkAround: return "Tilt to walk around the scene."
        }
    }
}

enum ClothTool: String, CaseIterable, Identifiable {
    case move, pin, smooth
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String { ["hand.draw", "pin", "wand.and.rays"][ClothTool.allCases.firstIndex(of: self)!] }
}

struct ClothPin: Codable, Equatable {
    var particle: Int
    var x: Float
    var y: Float
    var z: Float
}

/// Saved per project in project.json, so a sample opens the same way next time.
struct ClothSettings: Codable, Equatable {
    var support: ClothSupport = .board
    var material: ClothMaterial = .linen
    var form: FormPreset = .modern
    var grainAngle: Double = 0            // degrees between the warp and the panel's vertical
    var tiling: ClothTiling = .off
    var panelWidth: Double = 1.0          // metres, used when tiling
    var panelHeight: Double = 1.1
    var repeatRect: [Double] = [0, 0, 1, 1]   // u0, v0, du, dv in image coordinates (v down)
    var sampleWidthOverride: Double?      // metres
    var sheen: Bool?
    var selfCollision = true
    var showGrainline = false
    var useMask = true
    var verso: String?                    // folder name of another project with an RTI
    var lightMode: ClothLightMode = .lamp
    var tiltMode: ClothTiltMode = .off
    var lightAzimuth: Double = 135        // degrees, in the support's light frame
    var lightElevation: Double = 40
    var pins: [ClothPin] = []
    var pinsKey: String = ""              // pins are only restored for the same scene layout

    var sheenEnabled: Bool { sheen ?? material.defaultSheen }
}
