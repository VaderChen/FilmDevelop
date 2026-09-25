import Foundation
import simd

/// Original artistic profiles, NOT manufacturer measurements or CIE observer
/// data. The fixed 13-band visible-light model cannot recover infrared or the
/// original spectrum from RGB. All construction/calibration uses Double.
/// Runtime projection uses these constants as Metal float, without an 8-bit LUT.
struct PhotoFilmSpectralProfile: Sendable {
    static let wavelengths = stride(from: 400.0, through: 700.0, by: 25).map { $0 }
    static let provenance = "Original artistic 13-band approximation; not measured film, CIE, or infrared data."
    static let all = PhotoFilmStock.allCases.map { Self(stock: $0) }

    let stock: PhotoFilmStock
    var reversal = false
    var monochrome: Bool { stock.isMonochrome }
    var toe = -7.0
    var shoulder = 4.5
    var bend = 1.1
    var maxDensity = 3.0
    var printSlope = 1.0
    var printMaxDensity = 2.6
    var retainedSilver = 0.0
    /// 掃描完成後的藝術性彩度意圖；避免染料分離校正將片種特色一起中和。
    /// 由原有染料頻寬設定推導，並非量測得到的物理彩度。
    var scannerChroma = 1.0
    var layerGain = SIMD3<Double>(repeating: 1)
    var layerEV = SIMD3<Double>(repeating: 0)
    var sensitivity: [SIMD3<Double>] = []
    var negativeDyes: [SIMD3<Double>] = []
    var printSensitivity: [SIMD3<Double>] = []
    var printDyes: [SIMD3<Double>] = []
    var baseDensity: [Double] = []

    /// A partition of unity supplies a nonnegative radiance shape. Its amplitude
    /// is scene-linear RGB, so values above 1 remain above 1 before development.
    /// This is a declared synthetic RGB spectral basis, not a recovered spectrum.
    static let inputBasis: [SIMD3<Double>] = wavelengths.map { lambda in
        let v = SIMD3<Double>(gaussian(lambda, 620, 45), gaussian(lambda, 540, 32), gaussian(lambda, 450, 32))
        return v / (v.x + v.y + v.z)
    }

    /// Independent broad virtual scanner channels. Calibrating against the input
    /// basis gives exact linear RGB round-trip for that basis; it does not claim
    /// calibrated CIE colorimetry for arbitrary spectra.
    static let scanner: [SIMD3<Double>] = normalizeChannels(wavelengths.map { lambda in
        SIMD3<Double>(gaussian(lambda, 610, 38), gaussian(lambda, 545, 30), gaussian(lambda, 455, 28))
    })
    static let scannerToRGB: simd_double3x3 = {
        var response = simd_double3x3(columns: (.zero, .zero, .zero))
        for index in wavelengths.indices {
            let s = scanner[index], b = inputBasis[index]
            response.columns.0 += s * b.x
            response.columns.1 += s * b.y
            response.columns.2 += s * b.z
        }
        return response.inverse
    }()

    init(stock: PhotoFilmStock) {
        self.stock = stock
        var sensitivityWidth = 1.0
        var dyeWidth = 1.0
        var dyeShift = 0.0
        var monoWeights = SIMD3<Double>(0.28, 0.61, 0.11)
        switch stock {
        case .filmPortra160:
            printSlope = 0.86; bend = 0.95; dyeWidth = 1.10
            layerEV = .init(0.04, 0, -0.04)
        case .filmPortra400:
            printSlope = 0.95; toe = -7.4; shoulder = 4.8; dyeWidth = 1.03
            layerEV = .init(0.07, 0.015, -0.05)
        case .filmPortra800:
            printSlope = 0.92; toe = -7.8; shoulder = 4.7; bend = 0.82
            dyeWidth = 1.12; layerEV = .init(0.12, 0.025, -0.09)
        case .filmEktar100:
            printSlope = 1.15; toe = -6.8; shoulder = 4.2; bend = 1.4
            dyeWidth = 0.90; sensitivityWidth = 0.90; layerGain = .init(1.04, 1, 1.025)
        case .filmVision50D:
            toe = -8.2; shoulder = 5.6; printSlope = 1.08; dyeWidth = 0.98
        case .filmVision250D:
            toe = -8; shoulder = 5.3; printSlope = 1.04; bend = 1.0
            layerEV = .init(0.025, 0.015, -0.015); layerGain = .init(1.01, 1, 0.98)
        case .filmVision200T:
            toe = -8; shoulder = 5.4; printSlope = 1.08; bend = 1.08
            dyeShift = 2
        case .filmVision500T:
            toe = -8.4; shoulder = 5.6; printSlope = 1.11; bend = 0.9
            layerGain = .init(0.98, 1, 1.02); dyeShift = 4
        case .filmEktachrome100:
            reversal = true; toe = -6.8; shoulder = 3.4; maxDensity = 3.5; bend = 1.2
            layerGain = .init(1, 1.01, 1.015); dyeWidth = 0.96
        case .filmVelvia50:
            reversal = true; toe = -5.7; shoulder = 2.8; maxDensity = 3.8; bend = 1.5
            sensitivityWidth = 0.86; dyeWidth = 0.88; layerGain = .init(1.015, 1.055, 1.02)
        case .filmProvia100F:
            reversal = true; toe = -7.4; shoulder = 3.8; maxDensity = 3.3; dyeWidth = 1.04
        case .filmHP5:
            toe = -7.6; shoulder = 4.8; printSlope = 1.05; bend = 1.15
        case .filmFP4:
            toe = -7; shoulder = 4.3; printSlope = 0.94; bend = 1.05
            monoWeights = .init(0.25, 0.63, 0.12)
        case .filmOrtho80:
            toe = -6.8; shoulder = 3.9; printSlope = 1.07; bend = 1.25
            monoWeights = .init(0, 0.67, 0.33)
        case .filmSFX200:
            toe = -7.2; shoulder = 4.3; printSlope = 1.08; monoWeights = .init(0.46, 0.51, 0.03)
        case .filmInfrared400:
            toe = -6.7; shoulder = 4.2; printSlope = 1.18; bend = 1.3
            monoWeights = .init(0.20, 0.79, 0.01)
        case .filmBleachBypass:
            toe = -7.5; shoulder = 4.8; printSlope = 1.14; retainedSilver = 0.38; dyeWidth = 1.12
        case .filmCrossProcess:
            toe = -6.2; shoulder = 3.6; printSlope = 1.12; bend = 1.3
            layerGain = .init(1.13, 0.88, 1.22); layerEV = .init(0.10, 0.16, -0.18); dyeShift = -4
        case .filmGold200:
            toe = -6.5; shoulder = 4.1; printSlope = 1.08; bend = 1.25
            dyeWidth = 0.95; layerEV = .init(0.40, 0.10, -0.33)
            layerGain = .init(1.035, 1, 0.975)
        case .filmCineStill800T:
            toe = -8.3; shoulder = 5.3; printSlope = 1.19; bend = 0.9
            // 輸入已經白平衡；不把日光下未校正的鎢絲片冷偏固定烙進每張照片。
            dyeShift = 4
            layerGain = .init(0.97, 1, 1.04)
        case .filmPolaroidSX70:
            toe = -6.6; shoulder = 3.6; printSlope = 0.74; printMaxDensity = 1.68
            bend = 0.85; dyeWidth = 1.35; sensitivityWidth = 1.18
            layerEV = .init(0.32, -0.08, -0.28); layerGain = .init(0.94, 0.89, 1.03)
        case .filmDelta3200:
            toe = -8.8; shoulder = 5.2; printSlope = 0.78; printMaxDensity = 2.2
            bend = 0.75; monoWeights = .init(0.30, 0.59, 0.11)
        case .filmLomoPurple:
            toe = -6.8; shoulder = 4.1; printSlope = 1.10; bend = 1.2
            dyeWidth = 0.90; sensitivityWidth = 0.95
        }
        scannerChroma = 1 / (dyeWidth * dyeWidth)
        // Kodak 2018 原廠比較圖：Portra 160 < 400 < 800 < Ektar 彩度。
        // 染料頻寬的倒平方是藝術近似，不能當成片種彩度量測；800 單獨校正
        // 掃描輸出意圖，保留原染料、階調與膚色設定。1.04 是定性調整而非實測值。
        if stock == .filmPortra800 { scannerChroma = 1.04 }
        sensitivity = Self.normalizeChannels(Self.wavelengths.map { lambda in
            SIMD3<Double>(Self.gaussian(lambda, 625, 30 * sensitivityWidth),
                          Self.gaussian(lambda, 540, 27 * sensitivityWidth),
                          Self.gaussian(lambda, 450, 26 * sensitivityWidth))
        })
        if monochrome {
            sensitivity = sensitivity.map { .init(repeating: simd_dot($0, monoWeights)) }
        }
        negativeDyes = Self.wavelengths.map { lambda in
            Self.normalizedDyes(lambda, centers: .init(635 + dyeShift, 540, 445 - dyeShift),
                                widths: .init(46, 38, 35) * dyeWidth)
        }
        // Independent print material, deliberately not the negative's dyes or
        // sensitivity. Equal-dye density is neutral because each row sums to 1.
        printSensitivity = Self.normalizeChannels(Self.wavelengths.map { lambda in
            SIMD3<Double>(Self.gaussian(lambda, 615, 34), Self.gaussian(lambda, 535, 29), Self.gaussian(lambda, 445, 27))
        })
        printDyes = Self.wavelengths.map { Self.normalizedDyes($0, centers: .init(625, 535, 440), widths: .init(44, 35, 32)) }
        baseDensity = Self.wavelengths.map { lambda in
            reversal ? 0 : (monochrome ? 0.04 : 0.04 + 0.18 * Self.gaussian(lambda, 435, 52) + 0.06 * Self.gaussian(lambda, 540, 48))
        }
    }

    var printBias: Double {
        let ratio = -log10(0.18) / printMaxDensity
        return log(ratio / (1 - ratio))
    }

    func density(_ ev: Double) -> Double {
        func softplus(_ x: Double) -> Double { max(x, 0) + log1p(exp(-abs(x))) }
        return maxDensity * (softplus(bend * (ev - toe)) - softplus(bend * (ev - shoulder))) / (bend * (shoulder - toe))
    }

    var reversalShift: Double {
        guard reversal else { return 0 }
        let target = maxDensity + log10(0.18)
        var low = -30.0, high = 30.0
        for _ in 0..<64 {
            let mid = (low + high) / 2
            if density(mid) < target { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// Uncast neutral negative. Layer offsets are NOT recalibrated away.
    var referencePrintExposure: SIMD3<Double> {
        let d = density(0)
        return Self.wavelengths.indices.reduce(.zero) { h, i in
            h + printSensitivity[i] * pow(10, -(d + baseDensity[i]))
        }
    }

    static func gaussian(_ lambda: Double, _ center: Double, _ width: Double) -> Double {
        exp(-0.5 * pow((lambda - center) / width, 2))
    }

    private static func normalizedDyes(_ lambda: Double, centers: SIMD3<Double>, widths: SIMD3<Double>) -> SIMD3<Double> {
        let v = SIMD3<Double>(gaussian(lambda, centers.x, widths.x), gaussian(lambda, centers.y, widths.y), gaussian(lambda, centers.z, widths.z)) + 0.006
        return v / (v.x + v.y + v.z)
    }

    private static func normalizeChannels(_ values: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let sum = values.reduce(SIMD3<Double>.zero, +)
        return values.map { $0 / sum }
    }

    static func filterTransmission(_ filter: PhotoFilmEffects.MonochromeFilter, wavelength: Double) -> Double {
        func smoothstep(_ low: Double, _ high: Double) -> Double {
            let t = min(1, max(0, (wavelength - low) / (high - low)))
            return t * t * (3 - 2 * t)
        }
        switch filter {
        case .none: return 1
        case .yellow: return 0.04 + 0.96 * smoothstep(430, 520)
        case .orange: return 0.025 + 0.975 * smoothstep(490, 590)
        case .red: return 0.015 + 0.985 * smoothstep(540, 640)
        case .green: return 0.03 + 0.97 * gaussian(wavelength, 540, 42)
        }
    }

    /// Slow FP64 reference for tests and accuracy/benchmark tools. The renderer
    /// does NOT allocate per-pixel spectra or invoke this CPU path.
    func referenceRGB(_ input: SIMD3<Double>, effects: PhotoFilmEffects = .neutral, strength: Double = 1) -> SIMD3<Double> {
        let effects = effects.clamped()
        let exposed = PhotoExposureProtection.applyLuminance(input, gain: pow(2, effects.printExposure),
                                                            protectsHighlights: effects.highlightProtectionEnabled)
        var baseline = effects
        baseline.printExposure = 0
        baseline.printContrast = 50
        let rgb = referenceBaselineRGB(exposed, effects: baseline, strength: strength)
        let contrast = pow(2, (effects.printContrast - 50) / 50)
        let contrasted = SIMD3<Double>((0..<3).map { 0.18 * pow(max(rgb[$0], 0) / 0.18, contrast) })
        return contrasted
    }

    private func referenceBaselineRGB(_ input: SIMD3<Double>, effects: PhotoFilmEffects, strength: Double) -> SIMD3<Double> {
        let effects = effects.clamped()
        let printLight = PhotoFilmIllumination.spectrum(effects.printIlluminant, wavelengths: Self.wavelengths)
        let viewLight = PhotoFilmIllumination.spectrum(effects.viewIlluminant, wavelengths: Self.wavelengths)
        let rgb = SIMD3<Double>((0..<3).map { input[$0].isFinite ? min(65536, max(0, input[$0])) : 0 })
        let filterAmount = monochrome ? effects.monochromeFilterStrength / 100 * (strength.isFinite ? min(1, max(0, strength)) : 0) : 0
        let radiance = PhotoFilmSpectralReconstruction.spectrum(rgb)
        var h = SIMD3<Double>.zero, norm = SIMD3<Double>.zero
        for i in Self.wavelengths.indices {
            let filter = 1 + filterAmount * (Self.filterTransmission(effects.monochromeFilter, wavelength: Self.wavelengths[i]) - 1)
            let sensor = sensitivity[i] * filter
            h += sensor * radiance[i]
            norm += sensor
        }
        h /= norm
        if stock == .filmLomoPurple {
            // 原廠描述保留紅色；在顯影前連續混合正常與轉色感光量。
            // 這是 RGB 藝術近似，不是原廠光譜量測。
            let dominance = (rgb.x - max(rgb.y, rgb.z)) / max(1e-7, rgb.x)
            let t = min(1, max(0, (dominance - 0.15) / 0.5))
            let preserve = t * t * (3 - 2 * t)
            let shifted = SIMD3<Double>(0.45 * h.x + 0.55 * h.y, h.z, h.y)
            h = shifted * (1 - preserve) + h * preserve
        }
        var d = SIMD3<Double>.zero
        for c in 0..<3 {
            d[c] = density(log2(max(h[c], 1e-7) / 0.18) * layerGain[c] + layerEV[c] + reversalShift)
        }
        if effects.scannerProfile != .off {
            return PhotoFilmScanner.reference(reversal ? .init(repeating:maxDensity) - d : d, profile:self, effects:effects)
        }
        let contrast = pow(2, (effects.printContrast - 50) / 50)
        if reversal {
            let anchor = -log10(0.18)
            d = SIMD3<Double>((0..<3).map { max(0, anchor + (maxDensity - d[$0] - anchor) * contrast) })
        } else {
            var printH = SIMD3<Double>.zero
            for i in Self.wavelengths.indices {
                let optical = baseDensity[i] + (monochrome ? d.x : simd_dot(negativeDyes[i], d))
                printH += printSensitivity[i] * printLight[i] * pow(10, -optical)
            }
            let reference = referencePrintExposure
            for c in 0..<3 {
                // Output compensation has the opposite sign to physical paper exposure.
                let ev = log2(max(printH[c] / reference[c], 1e-12)) - effects.printExposure
                d[c] = printMaxDensity / (1 + exp(-(ev * printSlope * contrast + printBias)))
            }
            let silver = retainedSilver * simd_dot(d, .init(0.2126, 0.7152, 0.0722))
            d += silver
        }
        if monochrome { return .init(repeating: pow(10, -d.x)) }
        let dyes = reversal ? negativeDyes : printDyes
        var scan = SIMD3<Double>.zero
        for i in Self.wavelengths.indices {
            scan += Self.scanner[i] * viewLight[i] * pow(10, -simd_dot(dyes[i], d))
        }
        let projected = Self.scannerToRGB * scan * (reversal ? pow(2, effects.printExposure) : 1)
        // A virtual scanner can leave the RGB gamut. This model clips only
        // negative output channels, never ordinary scene HDR before development.
        return simd_max(.zero, projected)
    }
}
