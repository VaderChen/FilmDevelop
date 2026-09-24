import AppKit
import UniformTypeIdentifiers

extension PhotoStyleWebCoordinator {
    func requestImageExport() {
        guard canExport else { return }
        if isWebReady, webView != nil {
            showPage("exportImage")
        } else {
            saveOutputImage()
        }
    }

    func saveOutputImageWhenReady() {
        guard let image = sourceImage?.cgImage else { return }
        let style = selectedStyle
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Committing a queued slider/crop edit may have just started a preview.
            // Do not lose the export command merely because that preview is busy.
            await self.waitForPreviewRender()
            guard self.sourceImage?.cgImage === image, self.selectedStyle == style else { return }
            self.saveOutputImage()
        }
    }

    func saveOutputImage() {
        guard canExport, sourceImage != nil, let window = webView?.window,
              window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.title = PhotoL10n.text("匯出照片")
        panel.prompt = PhotoL10n.text("匯出")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let baseName = sourceFileName.isEmpty ? "PhotoStyle" : (sourceFileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(baseName)-\(selectedStyle.rawValue).png"
        let format = PhotoExportFormatAccessory(panel: panel)
        panel.accessoryView = format.view
        panel.beginSheetModal(for: window) { [weak self, format] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    _ = try await self.exportImage(to: url, format: format.selectedFormat,
                                                   bitDepth: format.selectedBitDepth, overwrite: true)
                }
                catch { self.sendToast("匯出失敗：\(error.localizedDescription)") }
            }
        }
    }

    @MainActor
    @discardableResult
    func exportImage(to url: URL, usesPNG: Bool, overwrite: Bool) async throws -> CGSize {
        let format: PhotoExportFormat = usesPNG ? .png : .jpeg
        return try await exportImage(to: url, format: format, bitDepth: format.defaultBitDepth, overwrite: overwrite)
    }

    @MainActor
    @discardableResult
    func exportImage(to url: URL, format: PhotoExportFormat, bitDepth: Int, overwrite: Bool) async throws -> CGSize {
        try Task.checkCancellation()
        guard format.supportedBitDepths.contains(bitDepth) else {
            throw PhotoStyleMCPTools.failure("\(format.displayName) 不支援 \(bitDepth) bit 匯出；可用色深為 \(format.supportedBitDepths.map(String.init).joined(separator: "、")) bit。")
        }
        guard let sourceImage, !isLoadingImage, !isComputing, !isSavingImage, !isRepairingImage else {
            throw PhotoStyleMCPTools.failure("目前沒有可匯出的照片，或影像仍在處理中。")
        }
        if !overwrite && FileManager.default.fileExists(atPath: url.path) {
            throw PhotoStyleMCPTools.failure("輸出檔案已存在；若要覆寫，請指定 overwrite: true。")
        }
        let style = selectedStyle
        let patches = repairPatches
        let adjustment = renderingAdjustment(adjustmentStore.adjustment(for: style))
        let shouldUseSubjectMask = sourceSubjectMask != nil || adjustment.requiresSubjectMask
        let animationID = UUID().uuidString
        let needsDisplayPreview = webView != nil && isWebReady
        let startedAt = ProcessInfo.processInfo.systemUptime
        let outputSize = PhotoStyleProcessor.renderedOutputSize(for: sourceImage.size, adjustment: adjustment)
        let sourcePixels = sourceImage.size.width * sourceImage.size.height
        let outputPixels = outputSize.width * outputSize.height
        // Similar processing/format combinations learn their own per-pixel duration.
        let profile = [style.rawValue, format.rawValue, String(bitDepth), String(shouldUseSubjectMask),
                       String(adjustment.backgroundBlur > 0), String(adjustment.denoise > 0),
                       String(adjustment.hdrAmount > 0), String(adjustment.filmEffects.scannerProfile.rawValue)].joined(separator: ":")
        let workUnits = max(0.25, (sourcePixels + outputPixels * CGFloat(bitDepth) / 8) / 1_000_000)
        let reportStage: @Sendable (String) -> Void = { [weak self] stage in
            DispatchQueue.main.async { [weak self] in
                self?.callJavaScript(function: "handleExportDevelopment", payload: [
                    "phase": "progress", "id": animationID, "stage": stage
                ])
            }
        }
        isSavingImage = true
        callJavaScript(function: "handleExportDevelopment", payload: [
            "phase": "begin", "id": animationID, "timing": ["profile": profile, "workUnits": workUnits]
        ])
        updateSavingStep("以原始解析度輸出")
        do {
            let worker = Task.detached(priority: .userInitiated) { [renderer] () throws -> (size: CGSize, preview: String?) in
                try Task.checkCancellation()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let mask = shouldUseSubjectMask && renderer.canDetectSubjectMask
                    ? renderer.detectSubjectMask(for: PhotoStyleProcessor.repairedSource(sourceImage, patches: patches)) : nil
                try Task.checkCancellation()
                reportStage("render")
                let output = renderer.render(.init(
                    style: style, adjustment: adjustment, image: sourceImage,
                    subjectMask: mask, shouldDetectSubjectMask: false, repairPatches: patches
                ))
                try Task.checkCancellation()
                reportStage("encode")
                guard let data = output.encodedData(format: format, bitDepth: bitDepth, quality: 0.95) else {
                    throw PhotoStyleWebSaveError.imageEncodingFailed
                }
                try Task.checkCancellation()
                reportStage("write")
                try data.write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
                // Only a small display copy crosses the Web bridge; the file retains full resolution.
                let preview = needsDisplayPreview ? imageDataURL(output, maxPixel: 1600) : nil
                return (output.size, preview)
            }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            lastExportedPath = url.path
            callJavaScript(function: "handleExportDevelopment", payload: [
                "phase": "complete", "id": animationID, "image": result.preview as Any? ?? NSNull(),
                "durationMs": (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            ])
            finishSavingImage(message: "已匯出：\(url.lastPathComponent)")
            return result.size
        } catch {
            callJavaScript(function: "handleExportDevelopment", payload: ["phase": "cancel", "id": animationID])
            isSavingImage = false
            savingStep = ""
            sendState(includeImages: false)
            throw error
        }
    }
}

@MainActor
final class PhotoExportFormatAccessory: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 108))
    private let formatPicker = NSPopUpButton(frame: NSRect(x: 86, y: 69, width: 280, height: 26))
    private let depthPicker = NSPopUpButton(frame: NSRect(x: 86, y: 35, width: 280, height: 26))
    private let detailLabel = NSTextField(labelWithString: "")
    private weak var panel: NSSavePanel?
    private let defaults: UserDefaults
    private static let formatKey = "photoExportFormat.v1"
    private static let depthsKey = "photoExportBitDepths.v1"
    private static let png8DefaultKey = "photoExportPNG8Default.v1"
    private var rememberedDepths: [String: Int]
    private(set) var selectedFormat: PhotoExportFormat
    private(set) var selectedBitDepth: Int

    init(panel: NSSavePanel, defaults: UserDefaults = .standard) {
        self.panel = panel
        self.defaults = defaults
        let format = defaults.string(forKey: Self.formatKey).flatMap(PhotoExportFormat.init(rawValue:)) ?? .png
        var depths = defaults.dictionary(forKey: Self.depthsKey) as? [String: Int] ?? [:]
        // Adopt the new PNG default once, including preferences saved by older versions.
        if !defaults.bool(forKey: Self.png8DefaultKey) {
            depths[PhotoExportFormat.png.rawValue] = 8
            defaults.set(depths, forKey: Self.depthsKey)
            defaults.set(true, forKey: Self.png8DefaultKey)
        }
        let savedDepth = depths[format.rawValue] ?? format.defaultBitDepth
        selectedFormat = format
        selectedBitDepth = format.supportedBitDepths.contains(savedDepth) ? savedDepth : format.defaultBitDepth
        rememberedDepths = depths
        super.init()
        for (title, y) in [("檔案格式", 74.0), ("色深", 40.0)] {
            let label = NSTextField(labelWithString: PhotoL10n.text(title))
            label.font = .systemFont(ofSize: 13)
            label.frame = NSRect(x: 8, y: y, width: 74, height: 18)
            view.addSubview(label)
        }
        for picker in [formatPicker, depthPicker] {
            picker.font = .systemFont(ofSize: 13)
            picker.bezelStyle = .rounded
            picker.target = self
            view.addSubview(picker)
        }
        formatPicker.addItems(withTitles: PhotoExportFormat.allCases.map { PhotoL10n.text($0.displayName) })
        formatPicker.selectItem(at: PhotoExportFormat.allCases.firstIndex(of: selectedFormat)!)
        formatPicker.action = #selector(changeFormat)
        formatPicker.identifier = NSUserInterfaceItemIdentifier("exportFormat")
        formatPicker.setAccessibilityLabel(PhotoL10n.text("匯出檔案格式"))
        depthPicker.action = #selector(changeBitDepth)
        depthPicker.identifier = NSUserInterfaceItemIdentifier("exportBitDepth")
        depthPicker.setAccessibilityLabel(PhotoL10n.text("匯出色深"))
        detailLabel.frame = NSRect(x: 8, y: 7, width: 358, height: 18)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        view.addSubview(detailLabel)
        updateControls()
    }

    @objc private func changeFormat() {
        let index = formatPicker.indexOfSelectedItem
        guard PhotoExportFormat.allCases.indices.contains(index) else { return }
        selectFormat(PhotoExportFormat.allCases[index])
    }

    @objc private func changeBitDepth() {
        guard let depth = depthPicker.selectedItem?.tag else { return }
        selectBitDepth(depth)
    }

    func selectFormat(_ format: PhotoExportFormat) {
        rememberedDepths[selectedFormat.rawValue] = selectedBitDepth
        let preferred = rememberedDepths[format.rawValue] ?? selectedBitDepth
        selectedFormat = format
        selectedBitDepth = format.supportedBitDepths.contains(preferred) ? preferred : format.defaultBitDepth
        persistSelection()
        updateControls()
    }

    func selectBitDepth(_ bitDepth: Int) {
        guard selectedFormat.supportedBitDepths.contains(bitDepth) else { return }
        selectedBitDepth = bitDepth
        persistSelection()
        updateControls()
    }

    private func persistSelection() {
        rememberedDepths[selectedFormat.rawValue] = selectedBitDepth
        defaults.set(selectedFormat.rawValue, forKey: Self.formatKey)
        defaults.set(rememberedDepths, forKey: Self.depthsKey)
    }

    private func updateControls() {
        formatPicker.selectItem(at: PhotoExportFormat.allCases.firstIndex(of: selectedFormat)!)
        depthPicker.removeAllItems()
        for depth in selectedFormat.supportedBitDepths {
            depthPicker.addItem(withTitle: PhotoL10n.text(depth == 16 ? "16 bit／色彩通道" : "8 bit／色彩通道"))
            depthPicker.lastItem?.tag = depth
        }
        depthPicker.selectItem(withTag: selectedBitDepth)
        depthPicker.isEnabled = selectedFormat.supportedBitDepths.count > 1
        detailLabel.stringValue = PhotoL10n.text(selectedFormat.supportedBitDepths.count == 1
            ? "\(selectedFormat.displayName) 僅支援 8 bit；16 bit 請選 PNG 或 TIFF。"
            : "16 bit 保留細緻色階；8 bit 適合一般分享。")
        guard let panel else { return }
        panel.allowedContentTypes = [selectedFormat.contentType]
        let currentExtension = (panel.nameFieldStringValue as NSString).pathExtension.lowercased()
        if !selectedFormat.fileExtensions.contains(currentExtension) {
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension
                + "." + selectedFormat.fileExtensions[0]
        }
    }
}
