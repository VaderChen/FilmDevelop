import CoreImage

/// Combined pre-development path for shared renderers. The desktop materializes
/// these same processors as separate stages to bound temporary memory.
/// Optical bloom, polygon emulsion absorption / substrate return, then crystal
/// growth in a shared developer pool. No output-stage grain or red glow overlay.
public enum PhotoFilmExposureProcessor {
    public static func apply(to image: CIImage, effects: PhotoFilmEffects,
                             amounts: PhotoToneZoneGrainAmounts, strength: Double,
                             monochrome: Bool) -> CIImage {
        let effects = effects.clamped()
        let scattered = PhotoFilmEffectsProcessor.applyLightScatter(to: image, effects: effects, strength: strength)
        let exposed = PhotoEmulsionExposureProcessor.apply(to: scattered, effects: effects,
            amounts: amounts, strength: strength, monochrome: monochrome)
        // 顯影同時取樣縮小的化學場與完整影像，先保留共同曝光結果，
        // 避免 Core Image 在兩條分支重算整個乳劑模型。由 Core Image 管理中間結果的快取。
        let developmentInput = effects.developmentAmount > 0 && strength > 0
            ? exposed.insertingIntermediate(cache: true) : exposed
        return PhotoFilmDevelopmentProcessor.apply(to: developmentInput, effects: effects, strength: strength)
    }
}
