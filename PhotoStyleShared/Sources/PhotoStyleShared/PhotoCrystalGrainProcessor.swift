import CoreImage

/// Compatibility entry point. Polygon capture is now shared with the layered
/// Poisson emulsion instead of maintaining a second post-image grain algorithm.
public enum PhotoCrystalGrainProcessor {
    public static func apply(
        to image: CIImage,
        masks: PhotoToneMasks,
        highlightAmount: Double,
        midtoneAmount: Double,
        shadowAmount: Double,
        profile: PhotoGrainProfile,
        effects: PhotoFilmEffects,
        monochrome: Bool,
        seed: UInt32 = 0
    ) -> CIImage {
        PhotoEmulsionExposureProcessor.apply(to: image, effects: effects,
            amounts: .init(highlights: highlightAmount, midtones: midtoneAmount, shadows: shadowAmount),
            monochrome: monochrome, seed: seed)
    }
    static var kernelIsAvailable: Bool { PhotoEmulsionExposureProcessor.kernelsAreAvailable }
}
