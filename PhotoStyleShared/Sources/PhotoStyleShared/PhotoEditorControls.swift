import Foundation

/// Direct editor controls introduced in plan v3. Legacy plans omit this object.
/// These values are independent of the three tonal zones and style presets.
public struct PhotoEditorControls: Codable, Equatable, Sendable {
    public var exposure: Double = 0
    public var whiteBalanceWarmth: Double = 0
    public var whiteBalanceTint: Double = 0
    public var contrast: Double = 0
    public var brightness: Double = 50
    public var hdrAmount: Double = 0
    public var cropAspectRatio: String = "original"
    public var cropRotation: Double? = 0
    public var cropScale: Double = 100
    public var cropWidth: Double = 100
    public var cropHeight: Double = 100
    public var cropHorizontalPosition: Double = 0
    public var cropVerticalPosition: Double = 0
    public var frameEnabled: Bool = false
    public var frameStyle: String = "whitePaperThin"
    public var dateEnabled: Bool = false
    public var dateStyle: String = "numeric"

    public init() {}

    public static let numericRanges: [String: ClosedRange<Double>] = [
        "exposure": -100...100, "white_balance_warmth": -100...100,
        "white_balance_tint": -100...100, "contrast": -100...100,
        "brightness": 0...100, "hdr_amount": 0...100,
        "crop_rotation": -45...45, "crop_scale": 20...100, "crop_width": 20...100, "crop_height": 20...100,
        "crop_horizontal_position": -100...100, "crop_vertical_position": -100...100
    ]
    public static let enumValues: [String: [String]] = [
        "crop_aspect_ratio": ["original", "source", "free", "threeTwo", "oneOne", "fourThree", "sixteenNine"],
        "frame_style": ["whitePaperThin", "whitePaperWide", "whitePaperPolaroid", "blackLine", "filmStrip", "cleanInset"],
        "date_style": ["numeric", "slash", "compact", "japanese"]
    ]
    public static let booleanKeys = ["frame_enabled", "date_enabled"]

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, brightness
        case whiteBalanceWarmth = "white_balance_warmth"
        case whiteBalanceTint = "white_balance_tint"
        case hdrAmount = "hdr_amount"
        case cropAspectRatio = "crop_aspect_ratio"
        case cropRotation = "crop_rotation"
        case cropScale = "crop_scale"
        case cropWidth = "crop_width"
        case cropHeight = "crop_height"
        case cropHorizontalPosition = "crop_horizontal_position"
        case cropVerticalPosition = "crop_vertical_position"
        case frameEnabled = "frame_enabled"
        case frameStyle = "frame_style"
        case dateEnabled = "date_enabled"
        case dateStyle = "date_style"
    }
}
