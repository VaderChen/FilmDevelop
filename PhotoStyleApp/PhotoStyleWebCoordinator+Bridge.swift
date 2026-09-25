import WebKit

extension PhotoStyleWebCoordinator {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isTerminating, message.frameInfo.isMainFrame, message.name == "nativeBridge",
              let bridgeMessage = PhotoStyleWebBridgeMessage(body: message.body) else {
            return
        }

        // Read-only hover requests quietly ignore busy/stale photos, and cancellation
        // always works even when another operation has just started.
        if bridgeMessage.action == .previewFilmHover {
            filmHoverPreview.begin(bridgeMessage.payload)
            return
        }
        if bridgeMessage.action == .cancelFilmHover {
            filmHoverPreview.cancel(requestID: bridgeMessage.payload["requestID"] as? String)
            return
        }
        // Preparation replies even when busy so the toolbar never remains pending.
        if bridgeMessage.action == .prepareRepairBrush {
            prepareRepairBrush(bridgeMessage.payload)
            return
        }
        if isMCPMutating && ![PhotoStyleWebBridgeAction.getState, .requestPhotoThumbnails, .copyMCPConfiguration, .cancelComputation, .setLanguage,
                              .cancelDownload, .cancelImport, .cancelModelDirectoryScan, .cancelModelRepositoryQuery].contains(bridgeMessage.action) {
            sendToast("MCP 正在更新照片，請稍候。")
            return
        }
        if (isLoadingImage || isComputing || isSavingImage || isRepairingImage),
           ![PhotoStyleWebBridgeAction.getState, .requestPhotoThumbnails, .copyMCPConfiguration, .setMCPEnabled, .setLanguage,
             .cancelRepairBrush, .cancelDownload, .cancelImport, .cancelComputation, .cancelSubjectMaskDetection, .cancelModelDirectoryScan, .cancelModelRepositoryQuery].contains(bridgeMessage.action) {
            sendToast("請等目前的處理完成後再操作。")
            return
        }
        // Commit pending Web edits together before the command takes its snapshot.
        // Pending portrait edits are explicit edits too. AI obtains its own mask;
        // export waits for this preview, while a new photo discards stale results.
        if [.saveCustomFilm, .deleteCustomFilm, .undoEdit, .redoEdit, .importColorCalibration, .clearColorCalibration, .applyStyle, .saveImage, .browseFiles, .browsePhotoDirectory, .selectDirectoryPhoto, .setStyle].contains(bridgeMessage.action),
           let adjustments = bridgeMessage.payload["adjustments"] as? [[String: Any]] {
            updateAdjustments(adjustments, detectSubjectMask: bridgeMessage.action != .applyStyle)
        }
        if [.saveImage, .applyStyle].contains(bridgeMessage.action) {
            commitAdjustmentPreview()
        }
        switch bridgeMessage.action {
        case .prepareRepairBrush:
            prepareRepairBrush(bridgeMessage.payload)
        case .applyRepairBrush:
            applyRepairBrush(bridgeMessage.payload)
        case .cancelRepairBrush:
            cancelRepairBrush()
        case .previewFilmHover, .cancelFilmHover:
            break
        case .checkAppUpdate:
            Task { @MainActor in appUpdater.check() }
        case .setMCPEnabled:
            setMCPEnabled(bridgeMessage.payload)
        case .copyMCPConfiguration:
            mcpServer.copyConnectionConfiguration()
            sendToast("已複製 MCP 連線設定（包含存取權杖）。")
        case .importColorCalibration:
            openColorCalibrationPicker()
        case .clearColorCalibration:
            setColorCalibration(nil)
        case .retryPreview:
            guard sourceImage != nil, !isRenderingPreview else { return }
            photoPreviewCache.removeAllObjects()
            // 解碼失敗後，即使重新渲染的位元組相同，也必須重新傳送圖片。
            lastSentPreviewImages = nil
            applySelectedStyle()
            sendState(includeImages: true)
        case .getState:
            lastSentPreviewImages = nil
            sendState(includeImages: true)
        case .browseFiles:
            openFilePicker()
        case .importCustomFilm:
            importCustomFilm()
        case .exportCustomFilm:
            exportCustomFilm(bridgeMessage.payload)
        case .saveCustomFilm:
            promptToSaveCustomFilm()
        case .deleteCustomFilm:
            promptToDeleteCustomFilm(bridgeMessage.payload)
        case .sampleWhiteBalance:
            sampleWhiteBalance(bridgeMessage.payload)
        case .showPreviewMenu:
            showPreviewMenu(bridgeMessage.payload)
        case .browsePhotoDirectory:
            openPhotoDirectoryPicker()
        case .selectDirectoryPhoto:
            selectDirectoryPhoto(bridgeMessage.payload)
        case .requestPhotoThumbnails:
            requestPhotoThumbnails(bridgeMessage.payload)
        case .openCustomModel:
            openCustomModelPicker()
        case .openModelDirectory:
            openModelDirectoryPicker()
        case .cancelModelDirectoryScan:
            aiModelStore.cancelModelDirectoryScan()
        case .selectModel:
            if let id = bridgeMessage.payload["id"] as? String {
                aiModelStore.selectModel(id: id)
                sendState(includeImages: false)
            }
        case .searchModelRepositories, .inspectModelRepository:
            let query = (bridgeMessage.payload["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let format = bridgeMessage.payload["format"] as? String == "gguf" ? "gguf" : "mlx"
            guard !query.isEmpty, query.count <= 500 else { sendToast("請輸入模型名稱或 Hugging Face repository。"); return }
            if bridgeMessage.action == .searchModelRepositories {
                aiModelStore.repositoryBrowser.search(query, format: format)
            } else {
                aiModelStore.repositoryBrowser.inspect(query, format: format)
            }
        case .cancelModelRepositoryQuery:
            aiModelStore.repositoryBrowser.cancel()
        case .downloadModelRepository:
            aiModelStore.downloadRepository(mainPath: bridgeMessage.payload["mainPath"] as? String,
                                            projectorPath: bridgeMessage.payload["projectorPath"] as? String)
        case .setStyle:
            setStyle(bridgeMessage.payload)
        case .setLanguage:
            setLanguage(bridgeMessage.payload)
        case .setOriginalResolutionEditing:
            setOriginalResolutionEditing(bridgeMessage.payload)
        case .setExposureExpansionEnabled:
            setExposureExpansionEnabled(bridgeMessage.payload)
        case .setHighlightProtectionEnabled:
            setHighlightProtectionEnabled(bridgeMessage.payload)
        case .setHDRFeatureEnabled:
            setHDRFeatureEnabled(bridgeMessage.payload)
        case .beginAdjustmentPreview:
            beginAdjustmentPreview(bridgeMessage.payload)
        case .endAdjustmentPreview:
            endAdjustmentPreview(bridgeMessage.payload)
        case .updateAdjustment:
            if bridgeMessage.payload["interactionID"] != nil {
                guard acceptsAdjustmentPreview(bridgeMessage.payload) else { return }
                updateAdjustments([bridgeMessage.payload], interactive: true)
            } else if let adjustments = bridgeMessage.payload["adjustments"] as? [[String: Any]] {
                updateAdjustments(adjustments)
            } else {
                updateAdjustment(bridgeMessage.payload)
            }
        case .updateStylePrompt:
            updateStylePrompt(bridgeMessage.payload)
        case .resetStylePrompt:
            resetStylePrompt(bridgeMessage.payload)
        case .undoEdit:
            restoreEditHistory(redo: false)
        case .redoEdit:
            restoreEditHistory(redo: true)
        case .resetAdjustments:
            resetAdjustments(bridgeMessage.payload)
        case .applyStyle:
            runStyleComputation()
        case .saveImage:
            saveOutputImageWhenReady()
        case .downloadPreset:
            downloadPreset(bridgeMessage.payload)
        case .deletePreset:
            deletePreset(bridgeMessage.payload)
        case .cancelImport:
            aiModelStore.cancelImport()
        case .cancelDownload:
            aiModelStore.cancelDownload()
        case .cancelComputation:
            cancelStyleComputation()
        case .cancelSubjectMaskDetection:
            cancelSubjectMaskDetection()
        case .setActiveModel:
            if let fileName = bridgeMessage.payload["fileName"] as? String {
                aiModelStore.setActiveModel(fileName: fileName)
            }
        }
    }
}
