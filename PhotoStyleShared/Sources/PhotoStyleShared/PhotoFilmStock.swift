import Foundation

/// Independently designed film-inspired profiles, not manufacturer-calibrated
/// measurements or licensed reproductions. IDs remain stable in saved styles.
public enum PhotoFilmStock: String, CaseIterable, Codable, Sendable {
    case filmPortra160, filmPortra400, filmPortra800, filmEktar100
    case filmVision50D, filmVision250D, filmVision200T, filmVision500T
    case filmEktachrome100, filmVelvia50, filmProvia100F
    case filmHP5, filmFP4, filmOrtho80, filmSFX200, filmInfrared400
    case filmBleachBypass, filmCrossProcess
    case filmGold200, filmCineStill800T, filmPolaroidSX70, filmDelta3200, filmLomoPurple

    public var title: String { descriptor.title }
    public var subtitle: String { descriptor.subtitle }
    public var family: String {
        switch self {
        case .filmPortra160, .filmPortra400, .filmPortra800, .filmEktar100, .filmGold200: return "negative"
        case .filmVision50D, .filmVision250D, .filmVision200T, .filmVision500T, .filmCineStill800T: return "cinema"
        case .filmEktachrome100, .filmVelvia50, .filmProvia100F: return "reversal"
        case .filmHP5, .filmFP4, .filmOrtho80, .filmSFX200, .filmInfrared400, .filmDelta3200: return "monochrome"
        case .filmBleachBypass, .filmCrossProcess, .filmLomoPurple: return "creative"
        case .filmPolaroidSX70: return "instant"
        }
    }
    public var familyTitle: String {
        switch family {
        case "negative": return "彩色負片"
        case "cinema": return "電影負片"
        case "reversal": return "彩色反轉片"
        case "monochrome": return "黑白底片"
        case "instant": return "即影即有"
        default: return "特殊底片／製程"
        }
    }
    public var isMonochrome: Bool { family == "monochrome" }
    public var palette: [String] { descriptor.palette.map { "#" + $0 } }
    public var defaultGrain: Double { descriptor.grain }
    public var defaultEffects: PhotoFilmEffects {
        var effects = PhotoFilmEffects(
            grainMode: .emulsion, grainSize: descriptor.size,
            grainClumping: descriptor.clumping, grainChroma: isMonochrome ? 0 : 22,
            bloomAmount: 0, halationAmount: 0, colorModel: .spectral,
            developmentAmount: family == "cinema" ? 16 : (isMonochrome ? 12 : 8)
        )
        switch self {
        case .filmCineStill800T:
            // 降低抗暈並同步回收強度，避免返照能量無意間加倍。
            effects.halationBase = 35
            effects.halationAmount = 28; effects.halationRadius = 0.14
            effects.bloomAmount = 6
        case .filmPolaroidSX70:
            effects.bloomAmount = 12; effects.bloomRadius = 0.55
            effects.developmentAmount = 4
        case .filmDelta3200:
            effects.developmentAmount = 20
        default: break
        }
        let material = materialDefaults
        effects.grainDistribution = material.distribution
        effects.emulsionMTF = material.mtf
        effects.layerResponse = material.layers
        effects.couplerAmount = material.coupler
        // 這是新增選用時的藝術預設；舊配方解碼不補套片種預設。
        // 保留銀 0 表示不額外疊加，Bleach Bypass 自帶的印片銀密度仍保留。
        // 紙材 reference 保留 SX-70 的低密度；拍攝／沖洗條件沿用中性基準。
        effects.scannerProfile = .neutral
        return effects
    }
    /// 保守的藝術起點，非原廠量測。順序：粒徑分布、解析衰減、色層差異、色層抑制。
    private var materialDefaults: (distribution: Double, mtf: Double, layers: Double, coupler: Double) {
        switch self {
        case .filmPortra160: return (12, 3, 6, 3)
        case .filmPortra400: return (22, 5, 8, 5)
        case .filmPortra800: return (32, 8, 8, 4)
        case .filmEktar100: return (8, 1, 3, 4)
        case .filmVision50D: return (10, 2, 4, 8)
        case .filmVision250D: return (20, 4, 5, 8)
        case .filmVision200T: return (18, 4, 4, 7)
        case .filmVision500T: return (30, 7, 5, 7)
        case .filmEktachrome100: return (12, 2, 3, 0)
        case .filmVelvia50: return (8, 1, 0, 0)
        case .filmProvia100F: return (10, 2, 2, 0)
        case .filmHP5: return (38, 6, 0, 0)
        case .filmFP4: return (16, 3, 0, 0)
        case .filmOrtho80: return (12, 2, 0, 0)
        case .filmSFX200: return (26, 5, 0, 0)
        case .filmInfrared400: return (30, 5, 0, 0)
        case .filmBleachBypass: return (32, 5, 0, 0)
        case .filmCrossProcess: return (24, 4, 12, 2)
        case .filmGold200: return (28, 6, 6, 3)
        case .filmCineStill800T: return (36, 8, 4, 5)
        case .filmPolaroidSX70: return (18, 12, 0, 0)
        case .filmDelta3200: return (48, 8, 0, 0)
        case .filmLomoPurple: return (24, 4, 0, 0)
        }
    }

    public var algorithmDescription: String {
        switch self {
        case .filmGold200: return "暖黃感色層偏移、較鮮明的中調，搭配日常負片顆粒；與 Portra 的柔和膚色方向區隔。"
        case .filmCineStill800T: return "以已白平衡影像為基準保留鎢絲片階調，預設開啟亮部紅暈；色溫可依光源調整。"
        case .filmPolaroidSX70: return "即影即有的暖色、較低印相密度與柔光。"
        case .filmDelta3200: return "高感度黑白靈感的大尺寸顆粒、柔展階調與顯影局部反差；與 HP5 的中等顆粒區隔。"
        case .filmLomoPurple: return "保留紅色並重新配置感色層響應，讓綠色轉紫、黃色轉粉、藍色轉綠。"
        case .filmOrtho80: return "藍綠感光、抑制紅色響應，再經銀鹽與印相雙曲線。"
        case .filmSFX200: return "加重紅色感光的黑白雙曲線，讓紅色物體呈現較亮階調。"
        case .filmInfrared400: return "提亮綠葉、壓暗藍天，強調明暗分離。"
        case .filmBleachBypass: return "印片端加入保留銀密度，產生深黑與更強反差。"
        case .filmCrossProcess: return "各感色層使用不同曝光斜率與偏移，形成隨明暗變化的色偏。"
        default:
            if isMonochrome { return "先計算全色感光，再經銀鹽負片與印相雙曲線。" }
            if family == "reversal" { return "反轉片下降密度曲線、染料重疊與指數透射。" }
            return "對數曝光、底片密度與印相雙曲線，使用 LHTSS 光譜重建、多波段染料透射與獨立印片。"
        }
    }
    public var promptDescription: String {
        let method: String
        switch self {
        case .filmGold200: method = "warm golden color negative with vivid everyday color"
        case .filmCineStill800T: method = "white-balanced tungsten color negative; highlight-dependent red halation is enabled in the baseline"
        case .filmPolaroidSX70: method = "instant-film-inspired warm soft tones and reduced maximum print density, not a calibrated instant chemistry model"
        case .filmDelta3200: method = "high-speed monochrome with large grain and softer tonal progression"
        case .filmLomoPurple: method = "color-shifting negative with remapped layer sensitivities: red preserved, green to purple, yellow to pink, blue to green"
        case .filmOrtho80: method = "orthochromatic monochrome, blue/green sensitive, dark red objects"
        case .filmSFX200: method = "extended-red monochrome RGB approximation"
        case .filmInfrared400: method = "creative infrared-like monochrome RGB approximation; no recovered infrared data"
        case .filmBleachBypass: method = "print-stage retained-silver density, deeper shadows and contrast"
        case .filmCrossProcess: method = "cross-processing-inspired channel-specific density curves and tonal color crossover"
        default: method = isMonochrome ? "panchromatic monochrome negative and paper density curves" : (family == "reversal" ? "reversal density and dye transmission" : "color negative and print density curves")
        }
        return "\(title): \(method). This independently designed, uncalibrated stock density profile is already rendered before your adjustments. Do not recreate its film curve, color cast or monochrome conversion. Grain, development and print/viewing controls are separate from the stock profile; follow the supplied baseline and the user's explicit requests."
    }

    private struct Descriptor {
        let title: String
        let subtitle: String
        let palette: [String]
        let grain: Double
        let size: Double
        let clumping: Double
        init(_ title: String, _ subtitle: String, _ palette: [String], _ grain: Double, _ size: Double, _ clumping: Double) {
            self.title = title; self.subtitle = subtitle; self.palette = palette
            self.grain = grain; self.size = size; self.clumping = clumping
        }
    }
    private var descriptor: Descriptor {
        switch self {
        case .filmPortra160: return .init("Portra 160", "柔和膚色・細緻日光負片", ["D7BA9D", "A78E75", "637D72"], 10, 0.65, 8)
        case .filmPortra400: return .init("Portra 400", "自然人像・均衡階調", ["D8AD8A", "A58C6B", "677D76"], 16, 0.9, 14)
        case .filmPortra800: return .init("Portra 800", "低光氛圍・柔暖顆粒", ["D19F77", "88745F", "546B71"], 24, 1.2, 20)
        case .filmEktar100: return .init("Ektar 100", "鮮明色彩・細緻風景", ["C66545", "D5B861", "437A84"], 8, 0.55, 6)
        case .filmVision50D: return .init("VISION3 50D", "日光電影・細膩高光", ["D2B995", "9A9C71", "60807C"], 7, 0.55, 7)
        case .filmVision250D: return .init("VISION3 250D", "日光電影・寬容層次", ["C6AA87", "7D8C77", "526B75"], 13, 0.8, 12)
        case .filmVision200T: return .init("VISION3 200T", "鎢光電影・冷暖分離", ["BCAD96", "758785", "456880"], 12, 0.75, 10)
        case .filmVision500T: return .init("VISION3 500T", "鎢光夜景・豐富暗部", ["BB9573", "65777C", "355C76"], 23, 1.15, 18)
        case .filmEktachrome100: return .init("Ektachrome E100", "中性反轉・清透層次", ["D9C497", "5C8F89", "376789"], 10, 0.65, 8)
        case .filmVelvia50: return .init("Velvia 50", "濃郁反轉・深邃風景", ["BB554E", "76944F", "405B88"], 9, 0.6, 8)
        case .filmProvia100F: return .init("Provia 100F", "自然反轉・平衡色階", ["BFA080", "6B8B75", "517C98"], 8, 0.6, 6)
        case .filmHP5: return .init("HP5 PLUS 400", "全色黑白・紀實顆粒", ["D4D0C8", "85837E", "30312F"], 28, 1.25, 24)
        case .filmFP4: return .init("FP4 PLUS 125", "全色黑白・精細層次", ["E1DDD5", "96938B", "46443F"], 15, 0.8, 10)
        case .filmOrtho80: return .init("ORTHO PLUS 80", "正色黑白・紅色深沉", ["CEC9BE", "787F78", "2F3434"], 12, 0.7, 9)
        case .filmSFX200: return .init("SFX 200", "延伸紅感・明亮紅色", ["DEDCD3", "848B80", "344345"], 21, 1.0, 17)
        case .filmInfrared400: return .init("Infrared 400", "紅外線意象・亮葉深空", ["E7E7D9", "A3AB98", "263A42"], 24, 1.1, 18)
        case .filmBleachBypass: return .init("Bleach Bypass", "保留銀・深黑強反差", ["B8B3A7", "787C78", "303B42"], 26, 1.1, 23)
        case .filmCrossProcess: return .init("Cross Process", "交叉沖洗・色彩交錯", ["D3B353", "799B75", "55577F"], 18, 0.9, 14)
        case .filmGold200: return .init("Kodak Gold 200", "暖金日常・鮮明懷舊", ["D9AD58", "BD754D", "708A64"], 20, 1.0, 16)
        case .filmCineStill800T: return .init("CineStill 800T", "鎢光夜景・亮部紅暈", ["D06449", "607E92", "274E65"], 28, 1.3, 22)
        case .filmPolaroidSX70: return .init("Polaroid SX-70", "即影即有・暖色柔階", ["DBD0B5", "B8937E", "81938C"], 9, 0.7, 12)
        case .filmDelta3200: return .init("ILFORD Delta 3200", "高感黑白・粗顆粒柔階", ["D2CFC9", "8B8985", "454645"], 52, 1.9, 36)
        case .filmLomoPurple: return .init("LomoChrome Purple", "綠轉紫・超現實變色", ["AF70BE", "D29ABB", "54988B"], 18, 0.95, 14)
        }
    }
}
