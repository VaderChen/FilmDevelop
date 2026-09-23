import CoreImage

/// All film stocks use the shared spectral negative / print / viewing pipeline.
/// Old analytic selections are migrated by PhotoFilmEffects, without retaining
/// a parallel three-band approximation. Profiles remain original artistic data.
public enum PhotoFilmStockProcessor {
    public static func apply(to image: CIImage, stock: PhotoFilmStock,
                             effects: PhotoFilmEffects = .neutral, strength: Double = 1) -> CIImage {
        PhotoFilmSpectralProcessor.apply(to: image, stock: stock, effects: effects, strength: strength)
    }
    static var kernelIsAvailable: Bool { PhotoFilmSpectralProcessor.kernelIsAvailable }
}
