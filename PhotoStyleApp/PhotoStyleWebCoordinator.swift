import Combine
import PhotoStyleShared
import CoreImage
import AppKit
import WebKit

final class PhotoStyleWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, ObservableObject {
    weak var webView: WKWebView? { didSet { lastSentPreviewImages = nil } }
    lazy var filmHoverPreview = PhotoStyleFilmHoverPreview(coordinator: self)
    @MainActor lazy var appUpdater = PhotoAppUpdater(coordinator: self)

    static let imageDecodeContext = PhotoImageRenderPrecision.makeContext()
    static let selectedStyleDefaultsKey = "selectedStyle.v1"
    static let lastImageImportDirectoryPathDefaultsKey = "lastImageImportDirectoryPath.v1"
    static let lastImageImportFilePathDefaultsKey = "lastImageImportFilePath.v1"
    static let lastImageImportFileBookmarkDefaultsKey = "lastImageImportFileBookmark.v1"
    static let lastPhotoDirectoryPathDefaultsKey = "lastPhotoDirectoryPath.v1"
    static let lastPhotoDirectoryBookmarkDefaultsKey = "lastPhotoDirectoryBookmark.v1"
    static let lastSourceImagePathDefaultsKey = "lastSourceImagePath.v1"
    static let lastSourceImageIdentifierDefaultsKey = "lastSourceImageIdentifier.v1"
    static let promptLanguageDefaultsKey = "promptLanguage.v1"
    // 2048 px 處理模式預設關閉原檔編輯，之後仍保留使用者選擇。
    static let originalResolutionEditingDefaultsKey = "originalResolutionEditing.v2"
    static let processingPreviewMaxPixel: CGFloat = 2048
    static let hdrFeatureEnabledDefaultsKey = "hdrFeatureEnabled.v1"
    static let aiComputationItems = [
        "場景、主體與整體亮度分析",
        "亮部／中調／暗部調整參數",
        "單張局部動態範圍壓縮曲線",
        "風格比例與背景模糊",
        "膚色、美白與磨皮",
        "降噪、顆粒與暗角",
        "套用參數並產生預覽"
    ]

    let adjustmentStore = StyleAdjustmentStore()
    let stylePromptStore = StylePromptStore()
    let aiModelStore: AIModelStore
    let photoDirectoryStore: PhotoDirectoryStore
    let photoEditStore: PhotoEditStore
    let customFilmStore: CustomFilmStore
    var selectedCustomFilmID: String?
    var customFilmBaseAdjustment: StyleAdjustment?
    let previewSourcePayloadCache = PhotoPreviewSourcePayloadCache()
    var lastSentPreviewImages: [String: String]?
    let photoPreviewCache = NSCache<NSString, PhotoEditPreview>()
    var currentPhotoEditKey: String?
    var isRestoringPhotoEdits = false
    var repairPatches: [PhotoRepairPatch] = []
    var isRepairingImage = false
    var repairStep = ""
    var repairModelProgress: PhotoRepairModelProgress?
    var isCancellingRepair = false
    var repairOperationID = UUID()
    var repairTask: Task<Void, Never>?
    struct EditSnapshot: Equatable {
        var style: PhotoStyle
        var adjustments: [PhotoStyle: StyleAdjustment]
        var customFilmID: String? = nil
        var customFilmBaseAdjustment: StyleAdjustment? = nil
        var repairPatches: [PhotoRepairPatch] = []
    }
    var editUndoStack: [EditSnapshot] = []
    var editRedoStack: [EditSnapshot] = []
    var lastEditSnapshot: EditSnapshot?
    var editHistoryBatchID: String?
    var lastEditInteractionID: String?
    var isRestoringEditHistory = false
    var reportedPhotoEditError = false
    let renderer: any PhotoStyleRendering
    let computer: any PhotoStyleComputing
    let persistsImportedImages: Bool
    let sourcePersistenceDirectory: URL?
    var currentSourceIdentifier: String?
    var cancellables: Set<AnyCancellable> = []
    var selectedStyle: PhotoStyle = {
        guard let rawValue = UserDefaults.standard.string(forKey: "selectedStyle.v1"),
              let style = PhotoStyle(rawValue: rawValue) else {
            return .japaneseColor1
        }
        return style
    }()
    @Published var promptLanguage = PhotoL10n.language
    var appDisplayName: String {
        switch promptLanguage {
        case "english": return "FilmDevelop"
        case "japanese": return "写真現像"
        case "korean": return "사진 현상"
        default: return "照片沖洗"
        }
    }

    var aboutAppTitle: String {
        switch promptLanguage {
        case "english": return "About \(appDisplayName)"
        case "japanese": return "\(appDisplayName)について"
        case "korean": return "\(appDisplayName) 정보"
        default: return "關於 \(appDisplayName)"
        }
    }

    var highlightProtectionEnabled = UserDefaults.standard.object(forKey: "highlightProtectionEnabled.v1") as? Bool ?? true
    var hdrFeatureEnabled: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "hdrFeatureEnabled.v1") != nil else {
            return true
        }
        return defaults.bool(forKey: "hdrFeatureEnabled.v1")
    }()
    var originalResolutionEditing = UserDefaults.standard.object(forKey: originalResolutionEditingDefaultsKey) as? Bool ?? false
    var processingImage: PhotoImage?
    var editingImage: PhotoImage? {
        guard let sourceImage else { return nil }
        if originalResolutionEditing { return sourceImage }
        if processingImage == nil {
            processingImage = sourceImage.resizedForWebPreview(maxPixel: Self.processingPreviewMaxPixel)
        }
        return processingImage
    }

    func isCurrentPhotoImage(_ image: PhotoImage) -> Bool {
        image.cgImage === sourceImage?.cgImage || image.cgImage === previewImage?.cgImage || image.cgImage === processingImage?.cgImage
    }

    var photoGeneration = UUID()
    var sourceImage: PhotoImage? {
        didSet {
            processingImage = nil
            photoGeneration = UUID()
            cancelAdjustmentPreview()
        }
    }
    var previewImage: PhotoImage?
    var outputImage: PhotoImage?
    var sourceSubjectMask: CIImage?
    var subjectMaskAttemptedGeneration: UUID?
    let previewRenderQueue = DispatchQueue(label: "person.vader.PhotoStyleApp.preview", qos: .userInitiated)
    var adjustmentPreviewInteractionID: String?
    var adjustmentPreviewNeedsMask = false
    var delayedProcessingRender: DispatchWorkItem?
    var adjustmentPreviewGeneration = UUID()
    static let adjustmentSettleDelay: TimeInterval = 0.5
    var previewRevision: UInt64 = 0
    var pendingPreviewRender: PhotoStylePreviewJob?
    var previewRenderRunning = false
    var previewRenderWaiters: [CheckedContinuation<Void, Never>] = []
    var cancellablePreviewWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var previewImagePayload: [String: Any] = [:]
    var loadingPreviewImagePayload: String?
    var isRenderingPreview: Bool { previewRenderRunning || pendingPreviewRender != nil || delayedProcessingRender != nil || adjustmentPreviewInteractionID != nil }
    var hasAttemptedLastSourceImageRestore = false
    var hasAttemptedLastPhotoDirectoryRestore = false
    var isDetectingSubjectMask = false
    var subjectMaskDetectionID = UUID()
    var subjectMaskWorkItem: DispatchWorkItem?
    var isLoadingImage = false
    var isTerminating = false
    var isComputing = false
    var isCancellingComputation = false
    var computationID: UUID?
    var computationStep = ""
    var computationCompletedItemCount = 0
    var isSavingImage = false
    var exportWorker: Task<CGSize, Error>?
    var savingStep = ""
    var shouldExpandAdjustmentsAfterComputation = false
    var inferenceTask: Task<Void, Never>?
    var isWebReady = false
    var pendingOpenURL: URL?
    @Published var canImport = true
    @Published var canExport = false
    @Published var canCompute = false
    var sourceFileName = ""
    var sourceFileURL: URL?
    var lastExportedPath = ""
    var lastMessage = ""
    var isMCPMutating = false
    var mcpEnabled = UserDefaults.standard.object(forKey: "mcpEnabled.v1") as? Bool ?? true
    lazy var mcpServer = PhotoStyleMCPServer()

    init(renderer: any PhotoStyleRendering = CoreImagePhotoStyleRenderer(), persistsImportedImages: Bool = true, aiModelStore: AIModelStore? = nil, computer: any PhotoStyleComputing = LocalPhotoStyleComputer(), sourcePersistenceDirectory: URL? = nil, photoDirectoryStore: PhotoDirectoryStore? = nil, photoEditStore: PhotoEditStore? = nil) {
        self.renderer = renderer
        self.computer = computer
        self.aiModelStore = aiModelStore ?? AIModelStore()
        self.persistsImportedImages = persistsImportedImages
        self.sourcePersistenceDirectory = sourcePersistenceDirectory
        self.photoDirectoryStore = photoDirectoryStore ?? PhotoDirectoryStore()
        let editDirectory = sourcePersistenceDirectory?.appendingPathComponent("PhotoEdits", isDirectory: true)
            ?? (persistsImportedImages ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("PhotoStyleApp/PhotoEdits", isDirectory: true) : nil)
        self.photoEditStore = photoEditStore ?? PhotoEditStore(directory: editDirectory)
        self.customFilmStore = CustomFilmStore(fileURL: editDirectory?.deletingLastPathComponent().appendingPathComponent("CustomFilms.json"))
        super.init()
        photoPreviewCache.countLimit = 6
        photoPreviewCache.totalCostLimit = 96 * 1024 * 1024
        adjustmentStore.onChange = { [weak self] in
            self?.recordEditHistory()
            self?.persistCurrentPhotoEdits()
        }
        resetEditHistory()
        self.photoEditStore.onError = { [weak self] error in
            guard let self, !self.reportedPhotoEditError else { return }
            self.reportedPhotoEditError = true
            self.sendToast("照片調整暫時無法儲存：\(error.localizedDescription)")
        }
        self.photoDirectoryStore.onChange = { [weak self] in
            self?.rememberPhotoDirectory()
            self?.sendPhotoDirectoryState()
        }
    }

    func startObservingModelStore() {
        guard cancellables.isEmpty else { return }

        aiModelStore.repositoryBrowser.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendState(includeImages: false) }
            .store(in: &cancellables)

        aiModelStore.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendState(includeImages: false) }
            .store(in: &cancellables)

        aiModelStore.$directoryCatalog
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendState(includeImages: false) }
            .store(in: &cancellables)

        aiModelStore.$downloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendState(includeImages: false) }
            .store(in: &cancellables)

        aiModelStore.$importProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendState(includeImages: false) }
            .store(in: &cancellables)

        aiModelStore.$message
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let message else { return }
                self?.sendToast(message)
                self?.aiModelStore.message = nil
            }
            .store(in: &cancellables)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastSentPreviewImages = nil
        isWebReady = true
        restoreLastPhotoDirectoryIfNeeded()
        if let url = pendingOpenURL {
            pendingOpenURL = nil
            hasAttemptedLastSourceImageRestore = true
            loadPickedImage(from: url)
        } else if !restoreLastSourceImageIfNeeded() {
            sendState(includeImages: true)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }
}
