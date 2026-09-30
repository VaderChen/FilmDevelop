import Foundation

extension PhotoStyleWebCoordinator {
    func setRAWDecoderBackend(_ payload: [String: Any]) {
        guard !isTerminating, !isLoadingImage, !isComputing, !isSavingImage, !isRepairingImage, !isMCPMutating,
              let value = payload["backend"] as? String,
              let backend = PhotoRAWBackend(rawValue: value), backend != rawDecoderBackend else {
            sendState(includeImages: false)
            return
        }
        commitAdjustmentPreview()
        let previous = rawDecoderBackend
        guard sourceImage?.rawDecoderBackend != nil else {
            rawDecoderBackend = backend
            UserDefaults.standard.set(backend.rawValue, forKey: PhotoRAWBackend.defaultsKey)
            sendState(includeImages: false)
            return
        }
        guard let data = sourceRAWData else {
            sendToast("無法重新讀取目前的 RAW，請重新開啟照片後再切換。")
            sendState(includeImages: false)
            return
        }
        let url = sourceFileURL ?? URL(fileURLWithPath: sourceFileName)
        rawDecoderBackend = backend
        isLoadingImage = true
        cancelAdjustmentPreview()
        previewRevision &+= 1
        pendingPreviewRender = nil
        persistCurrentPhotoEdits()
        sendState(includeImages: false)
        let workGate = photoDirectoryStore.previewWorkGate
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            workGate.withEditorWork {
                let decoded = self.decodePickedImage(data: data, url: url, backend: backend)
                let processing = decoded?.processingPreview(maxPixel: Self.processingPreviewMaxPixel)
                let preview = decoded?.editingWebPreview()
                DispatchQueue.main.async {
                    guard !self.isTerminating else { return }
                    self.isLoadingImage = false
                    guard let decoded, decoded.rawDecoderBackend == backend else {
                        self.rawDecoderBackend = previous
                        self.sendToast("RAW 解析失敗，已保留原本的解析方式與照片。")
                        self.applySelectedStyle()
                        self.sendState(includeImages: true)
                        return
                    }
                    // Replace pixel storage only. Recipe, crop, repairs, masks,
                    // history and the source identity continue to belong to this photo.
                    self.cancelCurrentSubjectMaskDetection()
                    self.sourceImage = decoded
                    self.processingImage = processing
                    self.previewImage = preview
                    self.previewImagePayload = [:]
                    self.outputImage = nil
                    UserDefaults.standard.set(backend.rawValue, forKey: PhotoRAWBackend.defaultsKey)
                    self.applySelectedStyle()
                    self.sendState(includeImages: true, externalEdit: true)
                }
            }
        }
    }
}
