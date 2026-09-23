import Foundation

extension PhotoStyle {
    var llmDescriptions: [String: String] {
        [
            "traditionalChinese": llmDescription(for: "traditionalChinese"),
            "english": llmDescription(for: "english"),
            "japanese": llmDescription(for: "japanese"),
            "korean": llmDescription(for: "korean")
        ]
    }

    var llmDescription: String {
        llmDescription(for: "english")
    }

    func llmDescription(for language: String) -> String {
        if self == .original { return "Preserve the source exposure and color. Do not apply automatic corrections or film effects." }
        switch language {
        case "traditionalChinese":
            return llmTraditionalChineseDescription
        case "japanese":
            return llmJapaneseDescription
        case "korean":
            return llmKoreanDescription
        default:
            return llmEnglishDescription
        }
    }

    var llmParameterGuidance: String {
        switch self {
        case .autoDetection:
            return "Strength 45...70. Mapping 0...15. Use only corrections required by the image. Keep fade, softness, grain, skin retouching, and background blur near zero unless clearly needed."
        case .japaneseColor1:
            return "Strength 58...74. Mapping shadows 35...55, midtones 45...65, highlights 25...50. Base tone -18...0, zone exposure +3...+18, contrast -12...+6, fade 4...12, softness 2...10, grain 2...10. Create luminous cyan-blue air, lifted readable shadows, bright creamy whites, gentle highlight rolloff, and natural warm skin without crushing blacks."
        case .japaneseColor2:
            return "Strength 54...70. Mapping shadows 30...50, midtones 40...60, highlights 30...55. Base tone -24...-8, zone exposure +4...+20, contrast -20...0, fade 8...22, softness 8...20, grain 2...8. Create luminous soft-focus highlights, cyan-lavender shadows, warm cream light, pastel color, lifted blacks, and delicate grain without turning the whole image white."
        case .japaneseBWStrong:
            return "Strength 72...88. Mapping shadows 55...80, midtones 50...75, highlights 35...60. Contrast +22...+50, shadow exposure -12...+4, highlight recovery +4...+20, fade 0...4, softness 0...6, grain 18...42. Build deep tones and strong edge separation while retaining soft gray texture; grain should vary by brightness rather than becoming uniformly coarse."
        case .japaneseBWStandard:
            return "Strength 58...74. Mapping shadows 28...52, midtones 32...56, highlights 22...45. Contrast 0...+20, shadow exposure -4...+10, highlight recovery +2...+16, fade 0...8, softness 0...8, grain 8...24. Preserve a complete smooth grayscale, clear midtone separation, and defined highlight and shadow detail."
        case .japaneseBWSoft:
            return "Strength 48...64. Mapping shadows 20...45, midtones 25...50, highlights 20...45. Contrast -18...0, shadow exposure 0...+12, highlight recovery +4...+18, fade 4...16, softness 8...22, grain 4...16. Preserve a wide tonal range, fine grain, and well-defined endpoints; avoid milky haze and weak, undefined blacks."
        case .fujiProvia:
            return "Strength 58...72. Mapping shadows 25...45, midtones 30...50, highlights 20...40. Base tone +6...+18, contrast +6...+18, fade 0...2, softness 0...3, grain 0...8. Prioritize transparent, versatile color: clear skies, vivid sunsets, lush greens, and pale natural oranges for portraits while keeping magenta controlled."
        case .fujiClassicChrome:
            return "Strength 62...76. Mapping shadows 40...65, midtones 45...70, highlights 30...55. Base tone -24...-8, contrast +4...+18, fade 2...10, softness 0...7, grain 6...18. Keep color subdued, suppress magenta, maintain cool shadows, and produce a composed documentary contrast without warm-highlight styling."
        case .fujiClassicNeg:
            return "Strength 68...82. Mapping shadows 50...75, midtones 55...80, highlights 40...65. Base tone -15...+5, contrast +18...+40, fade 0...6, softness 0...8, grain 12...28. Create cyan-green shadows, magenta-biased highlights, colorful midtones, and hard tonal and color contrast with an intentionally lo-fi imbalance."
        default:
            return "The selected film density model already provides the characteristic curve and color response. Strength 75...100. Keep extra contrast, fade, warmth, tint and mapping close to zero unless requested. Preserve explicit user values; never recreate the stock by adding another strong global look."
        }
    }

    var llmStrengthRange: ClosedRange<Int> {
        switch self {
        case .autoDetection:
            return 45...70
        case .japaneseColor1:
            return 58...74
        case .japaneseColor2:
            return 54...70
        case .japaneseBWStrong:
            return 72...88
        case .japaneseBWStandard:
            return 58...74
        case .japaneseBWSoft:
            return 48...64
        case .fujiProvia:
            return 58...72
        case .fujiClassicChrome:
            return 62...76
        case .fujiClassicNeg:
            return 68...82
        default:
            return 75...100
        }
    }

    private var llmEnglishDescription: String {
        switch self {
        case .autoDetection:
            "Auto detection: no named style; natural correction only for exposure, white balance, contrast, tonal balance, skin cleanup, denoise, and subtle finishing."
        case .japaneseColor1:
            "Japanese cyan-air color: high-key but not globally washed out, low-to-medium contrast, softly lifted readable shadows, luminous cyan-blue air, clean creamy whites, gentle highlight rolloff, natural warm skin, fresh greens, restrained red, very fine grain, and almost no vignette. Preserve dark detail and avoid hard black clipping, heavy gray-blue casts, or aggressive desaturation."
        case .japaneseColor2:
            "Japanese style two: ethereal everyday light, low contrast, softly lifted blacks, cyan-to-lavender shadows, warm cream and pale pink highlights, restrained pastel saturation, delicate bloom, soft focus, and very fine grain. Allow luminous overexposure around light sources while preserving a readable subject; avoid hard blacks, orange skin, heavy magenta casts, or uniform white wash."
        case .japaneseBWStrong:
            "Japanese black and white strong: high-contrast monochrome with deep tones, strong edge separation, crisp detail, brightness-dependent fine-to-medium grain, and enough soft gray gradation to preserve texture instead of clipping everything to black and white."
        case .japaneseBWStandard:
            "Japanese black and white standard: balanced monochrome with a complete smooth grayscale, medium contrast, clear midtone separation, well-defined highlights and shadows, fine restrained grain, and natural sharpness without an exaggerated print effect."
        case .japaneseBWSoft:
            "Japanese black and white soft: low-contrast monochrome with wide tonal range, fine restrained grain, gentle shadow and highlight transitions, defined endpoints, and long gray gradation without milky haze or crushed detail."
        case .fujiProvia:
            "Film Provia: versatile transparent color built around memory color; clear skies, vivid sunsets, lush greenery, pale natural oranges for portraits, clean tonal separation, and controlled magenta without a heavy global cast."
        case .fujiClassicChrome:
            "Film Classic Chrome: subdued documentary color with suppressed magenta, cool shadows, restrained saturation, composed contrast, and a calm versatile look that remains consistent across subjects and light sources."
        case .fujiClassicNeg:
            "Film Classic Neg: lo-fi consumer-negative character with cyan-green shadows, magenta-biased highlights, colorful midtones, hard tonal and color contrast, visible grain, and a deliberately unbalanced but cohesive snapshot feel."
        default:
            filmStock?.promptDescription ?? title
        }
    }

    private var llmTraditionalChineseDescription: String {
        switch self {
        case .autoDetection:
            "自然色彩：不套用特定底片、復古、黑白、日式、粉彩或強烈風格；只做曝光、白平衡、對比、明暗平衡、皮膚整理、降噪與細微收尾的自然修正。"
        case .japaneseColor1:
            "日式風格一：高明度但不能全圖洗白，低至中對比，暗部柔和抬升且保留細節，帶明亮青藍空氣感，白色乾淨偏奶油，高光柔順滾降，膚色自然微暖，綠色清新、紅色克制，顆粒極細且幾乎不加暗角。避免硬黑壓死、厚重藍灰覆蓋與過度降飽和。"
        case .japaneseColor2:
            "日式風格二：呈現夢幻的日常光線、低對比、柔和抬升黑位、淡青至薰衣草色陰影、暖奶油與淡粉高光、克制的粉彩飽和、細緻柔霧與極細顆粒。光源周圍可以明亮過曝，但主體仍需可辨識；避免硬黑、橘黃膚色、厚重洋紅與整片均勻白霧。"
        case .japaneseBWStrong:
            "日式黑白強烈：高反差黑白、深沉階調、清楚邊緣分離與銳利細節；顆粒應隨亮度變化，維持細至中等質感，並保留柔和灰階過渡，避免只剩死黑與死白。"
        case .japaneseBWStandard:
            "日式標準黑白：均衡完整的平滑灰階、中等對比、清楚的中調分離、亮暗細節皆有明確邊界，搭配克制細顆粒與自然銳度，不刻意製造厚重印相效果。"
        case .japaneseBWSoft:
            "日式黑白淡雅：低對比、寬廣階調與細緻克制顆粒，暗部至高光平順過渡但端點仍要清楚，保留長灰階與完整細節，避免乳白霧感或黑位鬆散。"
        case .fujiProvia:
            "底片 Provia：以記憶色與透明感為核心的泛用色彩，天空清澈、夕陽鮮明、綠色茂盛，人物橘色調淡雅自然，階調分離乾淨並抑制洋紅，不加入厚重全域偏色。"
        case .fujiClassicChrome:
            "底片 Classic Chrome：沉穩克制的紀實色彩，壓低洋紅、保留冷調陰影與低飽和，對比沉著且不躁進，在不同主體與光源下維持一致、安靜的畫面。"
        case .fujiClassicNeg:
            "底片 Classic Neg.：帶低保真消費型負片性格，青綠陰影、偏洋紅高光、色彩鮮明的中調、硬朗明暗與色彩對比，搭配可見顆粒，形成刻意不平衡但仍一致的快照感。"
        default:
            "\(title)：\(subtitle)。底片模型已套用感色、密度與顯影響應，AI 僅調整必要的曝光及局部影調，避免重複加重反差或偏色。"
        }
    }

    private var llmJapaneseDescription: String {
        switch self {
        case .autoDetection:
            "自然色：特定のフィルム、レトロ、モノクロ、日本風、パステル、強い作風は適用せず、露出、ホワイトバランス、コントラスト、階調バランス、肌の整え、ノイズ低減、控えめな仕上げだけを自然に補正する。"
        case .japaneseColor1:
            "日本風シアン・エアカラー：高キーでも全体を白く洗わず、低〜中コントラスト、柔らかく持ち上げて質感を残した影、明るいシアンブルーの空気感、清潔でクリーミーな白、滑らかなハイライト、自然に温かい肌、爽やかな緑、抑えた赤、極細粒子、ほぼビネットなし。黒つぶれ、重いブルーグレー、過度な低彩度は避ける。"
        case .japaneseColor2:
            "日本風スタイル二：幻想的な日常光、低コントラスト、柔らかく持ち上げた黒、シアンからラベンダーの影、暖かなクリームと淡いピンクのハイライト、抑えたパステル彩度、繊細なブルーム、柔らかな焦点、極細粒子を表現する。光源周辺の明るい露出は許容するが被写体は読めるようにし、硬い黒、オレンジ肌、強いマゼンタ、均一な白い霞は避ける。"
        case .japaneseBWStrong:
            "日本風モノクロ強：高コントラスト、深い階調、明確なエッジ分離と鋭いディテール。粒子は明るさに応じて変化する微細〜中程度に抑え、黒白だけに潰さず柔らかなグレーの階調と質感を残す。"
        case .japaneseBWStandard:
            "日本風標準モノクロ：滑らかで完全なグレースケール、中程度のコントラスト、明確な中間調分離、輪郭のあるハイライトとシャドウ、控えめな微粒子と自然なシャープネスを保ち、過度なプリント感は加えない。"
        case .japaneseBWSoft:
            "日本風モノクロ淡：低コントラスト、広い階調、控えめな微粒子、シャドウからハイライトまでの穏やかな移行を持たせる。端点と細部は明確に保ち、乳白色の霞や締まりのない黒は避ける。"
        case .fujiProvia:
            "フィルム Provia：記憶色と透明感を軸にした汎用カラー。澄んだ空、鮮やかな夕景、豊かな緑、人物の淡く自然なオレンジ、明快な階調分離を保ち、マゼンタと全体的な色かぶりを抑える。"
        case .fujiClassicChrome:
            "フィルム Classic Chrome：マゼンタを抑え、クールなシャドウと低彩度を保つ落ち着いたドキュメンタリーカラー。被写体や光源が変わっても、控えめで安定したコントラストと静かな印象を維持する。"
        case .fujiClassicNeg:
            "フィルム Classic Neg.：ローファイな一般向けネガの性格。シアングリーンの影、マゼンタ寄りのハイライト、色彩豊かな中間調、硬い明暗と色コントラスト、目に見える粒子で、意図的に不均衡ながら統一感のあるスナップ感を作る。"
        default:
            "\(title)。フィルムの感色性・濃度曲線は既に適用済みです。必要な露出と局所階調だけを補正し、コントラストや色かぶりを重ねすぎないでください。"
        }
    }

    private var llmKoreanDescription: String {
        switch self {
        case .autoDetection:
            "자연 색감: 특정 필름, 레트로, 흑백, 일본풍, 파스텔, 강한 스타일을 적용하지 않고 노출, 화이트 밸런스, 대비, 톤 밸런스, 피부 정리, 노이즈 감소, 미세한 마감만 자연스럽게 보정한다."
        case .japaneseColor1:
            "일본식 시안 에어 컬러: 하이키이지만 전체를 하얗게 씻지 않고, 낮거나 중간 정도의 대비, 부드럽게 올리면서 디테일을 남긴 그림자, 밝은 시안 블루 공기감, 깨끗한 크림 화이트, 부드러운 하이라이트, 자연스럽게 따뜻한 피부, 산뜻한 녹색, 절제된 빨강, 매우 미세한 그레인, 거의 없는 비네팅을 유지한다. 검은색 뭉개짐, 무거운 블루그레이, 과도한 저채도는 피한다."
        case .japaneseColor2:
            "일본식 스타일 2: 몽환적인 일상광, 낮은 대비, 부드럽게 올린 블랙, 시안에서 라벤더로 이어지는 그림자, 따뜻한 크림과 옅은 핑크 하이라이트, 절제된 파스텔 채도, 섬세한 블룸과 소프트 포커스, 매우 미세한 그레인을 표현한다. 광원 주변의 밝은 노출은 허용하되 피사체는 식별 가능하게 유지하고 딱딱한 블랙, 주황 피부, 강한 마젠타, 균일한 흰 안개는 피한다."
        case .japaneseBWStrong:
            "일본식 흑백 강함: 높은 대비, 깊은 톤, 뚜렷한 가장자리 분리와 선명한 디테일을 만든다. 그레인은 밝기에 따라 달라지는 미세~중간 정도로 유지하고, 검정과 흰색으로만 뭉개지지 않도록 부드러운 회색 계조와 질감을 남긴다."
        case .japaneseBWStandard:
            "일본식 표준 흑백: 완전하고 부드러운 그레이스케일, 중간 대비, 명확한 중간톤 분리, 잘 정의된 하이라이트와 섀도, 절제된 미세 그레인과 자연스러운 선명도를 유지하며 과장된 인화 느낌은 피한다."
        case .japaneseBWSoft:
            "일본식 흑백 담백함: 낮은 대비, 넓은 톤 범위, 절제된 미세 그레인, 섀도에서 하이라이트까지 부드러운 전환을 만든다. 양 끝과 디테일은 분명히 유지하고 우윳빛 안개나 힘없는 블랙은 피한다."
        case .fujiProvia:
            "필름 Provia: 기억색과 투명감을 중심으로 한 범용 컬러. 맑은 하늘, 선명한 노을, 풍부한 녹색, 인물의 옅고 자연스러운 오렌지, 깨끗한 톤 분리를 유지하고 마젠타와 무거운 전체 색 편향을 억제한다."
        case .fujiClassicChrome:
            "필름 Classic Chrome: 마젠타를 억제하고 차가운 그림자와 낮은 채도를 유지하는 차분한 다큐멘터리 컬러. 피사체와 광원이 달라도 절제되고 안정적인 대비와 조용한 인상을 유지한다."
        case .fujiClassicNeg:
            "필름 Classic Neg.: 로파이 소비자용 네거티브 성격. 시안그린 그림자, 마젠타 쪽 하이라이트, 다채로운 중간톤, 강한 명암과 색 대비, 눈에 보이는 그레인으로 의도적으로 불균형하지만 일관된 스냅 느낌을 만든다."
        default:
            "\(title). 필름 감색성과 농도 곡선은 이미 적용되어 있습니다. 필요한 노출과 국부 톤만 보정하고 대비나 색조를 중복해서 과하게 적용하지 마세요."
        }
    }
}
