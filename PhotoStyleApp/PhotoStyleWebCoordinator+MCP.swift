import AppKit
import WebKit

extension PhotoStyleWebCoordinator {
    func startMCPServer() {
        guard !isTerminating else { return }
        mcpServer.toolHandler = { [weak self] name, arguments in
            guard let self else { throw PhotoStyleMCPTools.failure("App 已關閉。") }
            return try await self.handleMCPTool(name, arguments: arguments)
        }
        mcpServer.onStatusChange = { [weak self] in self?.sendState(includeImages: false) }
        if mcpEnabled { mcpServer.start() }
    }

    func setMCPEnabled(_ payload: [String: Any]) {
        guard let enabled = payload["enabled"] as? Bool else { return }
        mcpEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "mcpEnabled.v1")
        if enabled { startMCPServer() } else { mcpServer.stop() }
        sendState(includeImages: false)
    }

    var mcpState: [String: Any] {
        let adjustment = adjustmentStore.adjustment(for: selectedStyle)
        let outputSize = sourceImage.map { image in
            let size = PhotoStyleProcessor.renderedOutputSize(for: image.size, adjustment: adjustment)
            return ["width": size.width, "height": size.height]
        } ?? [:]
        return ["hasImage": sourceImage != nil, "fileName": sourceFileName,
         "selectedStyle": selectedStyle.rawValue, "isMonochrome": selectedStyle.isMonochrome,
         "imageSize": imageSizePayload(sourceImage) ?? [:],
         "outputSize": outputSize,
         "adjustment": adjustmentPayload(adjustment), "hdrFeatureEnabled": hdrFeatureEnabled,
         "isLoadingImage": isLoadingImage, "isRenderingPreview": isRenderingPreview, "isComputing": isComputing, "isCancellingComputation": isCancellingComputation, "canCancelComputation": canCancelComputation, "isSavingImage": isSavingImage,
         "computationStep": computationStep, "savingStep": savingStep,
         "isDetectingSubjectMask": isDetectingSubjectMask, "aiReady": aiModelStore.status.ready && !aiModelStore.isBusy,
         "uiReady": isWebReady, "lastMessage": lastMessage, "lastExportedPath": lastExportedPath]
    }

    @MainActor
    func handleMCPTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard !isTerminating else { throw PhotoStyleMCPTools.failure("App 正在關閉。") }
        try Task.checkCancellation()
        try PhotoStyleMCPTools.validate(name, arguments: arguments)
        switch name {
        case "get_state": return PhotoStyleMCPTools.result(mcpState)
        case "list_styles":
            return PhotoStyleMCPTools.result(["styles": PhotoStyle.allCases.map { style -> [String: Any] in
                ["id": style.rawValue, "title": style.title, "subtitle": style.subtitle,
                 "isMonochrome": style.isMonochrome, "isFilmStock": style.filmStock != nil,
                 "filmFamily": style.filmStock?.family ?? "",
                 "filmFamilyTitle": style.filmStock?.familyTitle ?? "",
                 "filmAlgorithm": style.filmStock?.algorithmDescription ?? ""]
            }])
        case "cancel_ai":
            cancelStyleComputation()
            return PhotoStyleMCPTools.result(mcpState)
        case "get_preview":
            try await waitForPreviewRenderCancellable()
            try Task.checkCancellation()
            guard let url = previewImagePayload["outputImage"] as? String else { throw PhotoStyleMCPTools.failure("尚未開啟照片。") }
            return ["content": [["type": "image", "mimeType": "image/jpeg", "data": String(url.dropFirst("data:image/jpeg;base64,".count))]], "isError": false]
        default: break
        }
        guard !isMCPMutating, !isLoadingImage, !isComputing, !isSavingImage, !isRepairingImage, webView?.window?.attachedSheet == nil else {
            throw PhotoStyleMCPTools.failure("目前有照片處理或檔案對話框進行中，請稍後再試。")
        }
        commitAdjustmentPreview()
        isMCPMutating = true
        updateActionAvailability()
        defer { isMCPMutating = false; sendState(includeImages: false) }
        var result: [String: Any] = [:]
        switch name {
        case "open_image":
            let url = try Self.mcpFileURL(arguments["path"] as! String)
            let cancellation = PhotoStyleImageLoadCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    loadPickedImage(from: url, cancellation: cancellation) { continuation.resume(with: $0) }
                }
            } onCancel: {
                cancellation.cancel()
            }
        case "set_style":
            setStyle(["style": arguments["style"]!])
        case "update_adjustments":
            guard sourceImage != nil else { throw PhotoStyleMCPTools.failure("尚未開啟照片。") }
            // Validate the whole request before applying any of its values.
            let changes = (arguments["changes"] as! [String: Any]).sorted(by: { $0.key < $1.key })
            updateAdjustments(changes.map { ["key": $0.key, "value": $0.value] })
        case "import_color_calibration":
            try importColorCalibration(from: Self.mcpFileURL(arguments["path"] as! String))
        case "clear_color_calibration":
            guard sourceImage != nil else { throw PhotoStyleMCPTools.failure("請先選取照片。") }
            setColorCalibration(nil)
        case "run_ai":
            guard sourceImage != nil, aiModelStore.status.ready, !aiModelStore.isBusy else { throw PhotoStyleMCPTools.failure("請先開啟照片並安裝可用的 AI 模型。") }
            runStyleComputation(promptOverride: arguments["prompt"] as? String,
                                languageOverride: arguments["language"] as? String)
        case "export_image":
            let url = try Self.mcpFileURL(arguments["path"] as! String)
            let options = try PhotoStyleMCPTools.exportOptions(arguments: arguments)
            let size = try await exportImage(to: url, format: options.format, bitDepth: options.bitDepth,
                                            overwrite: arguments["overwrite"] as? Bool ?? false)
            result = ["path": url.path, "width": size.width, "height": size.height,
                      "format": options.format.rawValue, "bitDepth": options.bitDepth]
        case "show_page": showPage(arguments["page"] as! String)
        default: throw PhotoStyleMCPTools.failure("不支援的工具。")
        }
        if ["open_image", "set_style", "update_adjustments", "import_color_calibration", "clear_color_calibration"].contains(name) {
            try await waitForPreviewRenderCancellable()
        }
        try Task.checkCancellation()
        sendState(includeImages: name != "show_page", externalEdit: ["open_image", "set_style", "update_adjustments", "import_color_calibration", "clear_color_calibration"].contains(name))
        if let webView, isWebReady {
            // Native state, page navigation, image decode and layout precede the MCP reply.
            if ["open_image", "set_style", "update_adjustments", "import_color_calibration", "clear_color_calibration"].contains(name) { showPage("home") }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                webView.callAsyncJavaScript("await window.flushPhotoUI();", arguments: [:], in: nil, in: .page) { result in
                    continuation.resume(with: result.map { _ in () })
                }
            }
        }
        try Task.checkCancellation()
        result["state"] = mcpState
        return PhotoStyleMCPTools.result(result)
    }

    private static func mcpFileURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw PhotoStyleMCPTools.failure("請提供絕對檔案路徑。") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
