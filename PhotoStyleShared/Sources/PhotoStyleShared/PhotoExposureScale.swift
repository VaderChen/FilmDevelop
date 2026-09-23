/// The editor's signed exposure control: zero is neutral, +100 is +5 EV,
/// and -100 retains the original -2 EV limit. Shared by rendering and analysis.
public enum PhotoExposureScale {
    public static let maximumEV = 5.0
    public static let minimumEV = -2.0

    public static func ev(fromSlider value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let value = min(max(value, -100), 100)
        return value / 100 * (value >= 0 ? maximumEV : -minimumEV)
    }

    public static func sliderValue(fromEV value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let value = min(max(value, minimumEV), maximumEV)
        return value / (value >= 0 ? maximumEV : -minimumEV) * 100
    }
}
