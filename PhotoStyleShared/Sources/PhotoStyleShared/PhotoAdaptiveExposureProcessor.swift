import CoreImage

/// Compatibility entry point. EV is now a scene-linear gain; local shadow
/// enhancement belongs to PhotoDeepShadowExposureProcessor, not this control.
public enum PhotoAdaptiveExposureProcessor {
    public static func apply(to image: CIImage, ev: Double, renderContext: CIContext? = nil) -> CIImage {
        let value = ev.isFinite ? min(max(ev,-4),PhotoExposureScale.maximumEV) : 0
        return PhotoExposureProcessor.apply(to: image, ev: value)
    }

    /// The modern preference retains stronger protection of saturated highlights
    /// by using the largest linear channel. Both modes preserve RGB ratios.
    static func applyFilmExposure(to image: CIImage, effects: PhotoFilmEffects,
                                  strength: Double, renderContext: CIContext?) -> CIImage {
        PhotoExposureProcessor.apply(to: image, zones: effects.resolvedPrintExposure,
            globalEV: effects.printExposure, strength: strength, protectsHighlights: effects.highlightProtectionEnabled, protectsPeak: true)
    }
}
