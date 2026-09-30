import Foundation

extension PhotoStyleWebCoordinator {
    func setComputeBackend(_ payload: [String: Any]) {
        guard !isTerminating, !isLoadingImage, !isComputing, !isSavingImage, !isRepairingImage,
              !isMCPMutating, !isRenderingPreview,
              let value = payload["backend"] as? String,
              let backend = PhotoComputeBackend(rawValue: value), backend != computeBackend else {
            sendState(includeImages: false)
            return
        }
        do {
            try PhotoBackendRouter.validate(backend)
            cancelAdjustmentPreview()
            computeBackend = backend
            renderer = CoreImagePhotoStyleRenderer(backend: backend)
            if backend == .system { PhotoBackendRouter.releaseIdleComputeResources() }
            UserDefaults.standard.set(backend.rawValue, forKey: PhotoComputeBackend.defaultsKey)
            photoPreviewCache.removeAllObjects()
            let sourceCache = previewSourcePayloadCache
            previewRenderQueue.async { [weak self] in
                sourceCache.begin(photoGeneration: UUID())
                // 舊的懸停預覽可能尚未取得 provider；等佇列排空再清一次，
                // 並確認使用者沒有再次切回 Vulkan。
                DispatchQueue.main.async { [weak self] in
                    guard self?.computeBackend == .system else { return }
                    PhotoBackendRouter.releaseIdleComputeResources()
                }
            }
            previewRevision &+= 1
            pendingPreviewRender = nil
            applySelectedStyle()
            sendState(includeImages: true)
        } catch {
            sendToast(error.localizedDescription)
            sendState(includeImages: false)
        }
    }

    func setRAWDecoderBackend(_ payload: [String: Any]) {
        guard !isTerminating, !isLoadingImage, !isComputing, !isSavingImage, !isRepairingImage, !isMCPMutating,
              let value = payload["backend"] as? String,
              let backend = PhotoRAWBackend(rawValue: value), backend != rawDecoderBackend else {
            sendState(includeImages: false)
            return
        }
        reloadRAWConfiguration(backend: backend, lensCorrection: lensCorrectionEnabled)
    }

    func setLensCorrectionEnabled(_ payload: [String: Any]) {
        guard !isTerminating, !isLoadingImage, !isComputing, !isSavingImage, !isRepairingImage, !isMCPMutating,
              let enabled = payload["enabled"] as? Bool, enabled != lensCorrectionEnabled else {
            sendState(includeImages: false)
            return
        }
        reloadRAWConfiguration(backend: rawDecoderBackend, lensCorrection: enabled)
    }

    // 解析器與鏡頭設定共用重建流程，成功後才儲存偏好，失敗時還原。
    private func reloadRAWConfiguration(backend: PhotoRAWBackend, lensCorrection: Bool) {
        commitAdjustmentPreview()
        let previous = rawDecoderBackend
        let previousLensCorrection = lensCorrectionEnabled
        guard sourceImage?.rawDecoderBackend != nil else {
            lensCorrectionEnabled = lensCorrection
            UserDefaults.standard.set(lensCorrection, forKey: "lensCorrectionEnabled.v1")
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
        lensCorrectionEnabled = lensCorrection
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
                let decoded = self.decodePickedImage(data: data, url: url, backend: backend, lensCorrection: lensCorrection)
                let processing = decoded?.processingPreview(maxPixel: Self.processingPreviewMaxPixel)
                let preview = decoded?.editingWebPreview()
                DispatchQueue.main.async {
                    guard !self.isTerminating else { return }
                    self.isLoadingImage = false
                    guard let decoded, decoded.rawDecoderBackend == backend
                        || (backend == .software && decoded.softwareRAWFallback) else {
                        self.rawDecoderBackend = previous
                        self.lensCorrectionEnabled = previousLensCorrection
                        self.sendToast("RAW 解析失敗，已保留原本的解析方式與照片。")
                        self.applySelectedStyle()
                        self.sendState(includeImages: true)
                        return
                    }
                    // 保留調整、裁切、修復、歷史與照片身分；鏡頭設定改變時重新建立主體遮罩。
                    self.cancelCurrentSubjectMaskDetection()
                    if previousLensCorrection != lensCorrection {
                        self.sourceSubjectMask = nil
                        self.subjectMaskAttemptedGeneration = nil
                    }
                    self.sourceImage = decoded
                    if decoded.softwareRAWFallback {
                        self.sendToast("內建解析器無法解析這張 RAW，已改用系統原生解析；其他照片仍優先使用內建軟體解析。")
                    }
                    self.processingImage = processing
                    self.previewImage = preview
                    self.previewImagePayload = [:]
                    self.outputImage = nil
                    UserDefaults.standard.set(lensCorrection, forKey: "lensCorrectionEnabled.v1")
                    UserDefaults.standard.set(backend.rawValue, forKey: PhotoRAWBackend.defaultsKey)
                    self.applySelectedStyle()
                    self.sendState(includeImages: true, externalEdit: true)
                }
            }
        }
    }
}
