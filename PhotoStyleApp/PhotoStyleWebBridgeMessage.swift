import Foundation

enum PhotoStyleWebBridgeAction: String {
    case prepareRepairBrush
    case applyRepairBrush
    case cancelRepairBrush
    case previewFilmHover
    case cancelFilmHover
    case checkAppUpdate
    case importColorCalibration
    case clearColorCalibration
    case retryPreview
    case getState
    case setMCPEnabled
    case copyMCPConfiguration
    case browseFiles
    case importCustomFilm
    case exportCustomFilm
    case saveCustomFilm
    case deleteCustomFilm
    case sampleWhiteBalance
    case showPreviewMenu
    case browsePhotoDirectory
    case selectDirectoryPhoto
    case requestPhotoThumbnails
    case openCustomModel
    case chooseExportDirectory
    case openModelDirectory
    case selectModel
    case cancelModelDirectoryScan
    case searchModelRepositories
    case inspectModelRepository
    case cancelModelRepositoryQuery
    case downloadModelRepository
    case setStyle
    case setLanguage
    case setOriginalResolutionEditing
    case setShowAllFilms
    case setExposureExpansionEnabled
    case setHighlightProtectionEnabled
    case setHDRFeatureEnabled
    case beginAdjustmentPreview
    case endAdjustmentPreview
    case updateAdjustment
    case updateStylePrompt
    case resetStylePrompt
    case undoEdit
    case redoEdit
    case resetAdjustments
    case applyStyle
    case saveImage
    case downloadPreset
    case deletePreset
    case cancelImport
    case cancelDownload
    case cancelComputation
    case cancelSubjectMaskDetection
    case setActiveModel
}

struct PhotoStyleWebBridgeMessage {
    let action: PhotoStyleWebBridgeAction
    let payload: [String: Any]

    init?(body: Any) {
        guard let payload = body as? [String: Any],
              let rawAction = payload["action"] as? String,
              let action = PhotoStyleWebBridgeAction(rawValue: rawAction) else {
            return nil
        }
        self.action = action
        self.payload = payload
    }
}
