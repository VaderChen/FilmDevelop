import Foundation

/// Independent printing/viewing illuminants sampled at the profile wavelengths.
/// Planck spectra are analytic blackbodies, not measured lamps or CIE D65.
public enum PhotoFilmIllumination {
    public static func spectrum(_ light: PhotoFilmEffects.Illuminant, wavelengths: [Double]) -> [Double] {
        guard !wavelengths.isEmpty else { return [] }
        guard let temperature = light.temperature else { return wavelengths.map { _ in 1 } }
        let samples = wavelengths.map { nm -> Double in
            guard nm.isFinite, nm > 0 else { return 0 }
            let wavelength = nm * 1e-9
            return 1 / (pow(wavelength, 5) * expm1(0.01438776877 / (wavelength * temperature)))
        }
        let mean = samples.reduce(0,+) / Double(samples.count)
        return mean > 0 && mean.isFinite ? samples.map { $0 / mean } : samples.map { _ in 1 }
    }
}
