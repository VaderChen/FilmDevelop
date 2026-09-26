import AppKit
import ImageIO

extension PhotoStyleWebCoordinator {
    func rememberPhotoDirectory(forceBookmark: Bool = false) {
        guard let url = photoDirectoryStore.directoryURL else { return }
        let defaults = UserDefaults.standard
        if forceBookmark || defaults.string(forKey: Self.lastPhotoDirectoryPathDefaultsKey) != url.path {
            defaults.set(url.path, forKey: Self.lastPhotoDirectoryPathDefaultsKey)
            defaults.removeObject(forKey: Self.lastPhotoDirectoryBookmarkDefaultsKey)
            if let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(bookmark, forKey: Self.lastPhotoDirectoryBookmarkDefaultsKey)
            }
        }
    }

    @discardableResult
    func restoreLastPhotoDirectoryIfNeeded() -> Bool {
        guard !hasAttemptedLastPhotoDirectoryRestore else { return false }
        hasAttemptedLastPhotoDirectoryRestore = true
        guard photoDirectoryStore.directoryURL == nil else { return false }
        let defaults = UserDefaults.standard
        var directory: URL?
        if let bookmark = defaults.data(forKey: Self.lastPhotoDirectoryBookmarkDefaultsKey) {
            var stale = false
            directory = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale, let directory,
               let renewed = try? directory.bookmarkData(options: [.withSecurityScope],
                                                         includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(renewed, forKey: Self.lastPhotoDirectoryBookmarkDefaultsKey)
            }
        }
        if directory == nil, let path = defaults.string(forKey: Self.lastPhotoDirectoryPathDefaultsKey), !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        }
        // Existing installs already remember the last imported photo's directory.
        directory = directory ?? lastImageImportDirectoryURL() ?? lastImageImportFileURL()?.deletingLastPathComponent()
        guard let directory else { return false }
        photoDirectoryStore.selectDirectory(directory,
            preferredPhotoURL: sourceFileURL ?? lastImageImportFileURL())
        return true
    }

    func photoDirectoryPayload() -> [String: Any] {
        var payload = photoDirectoryStore.payload(selectedURL: sourceFileURL)
        if let items = payload["items"] as? [[String: Any]] {
            payload["items"] = items.map { item -> [String: Any] in
                var item = item
                if let id = item["id"] as? String, let url = photoDirectoryStore.url(for: id) {
                    item["edited"] = photoEditStore.hasEdits(at: url)
                }
                return item
            }
        }
        return payload
    }

    func sendPhotoDirectoryState() {
        guard isWebReady, webView != nil else { return }
        callJavaScript(function: "handlePhotoDirectoryState",
                       payload: photoDirectoryPayload())
    }

    func requestPhotoThumbnails(_ payload: [String: Any]) {
        guard let ids = payload["ids"] as? [String], ids.count <= 48 else { return }
        photoDirectoryStore.requestThumbnails(ids: ids)
    }

    func openPhotoDirectoryPicker() {
        guard canImport, let window = webView?.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = PhotoL10n.text("選取照片目錄")
        panel.prompt = PhotoL10n.text("選取目錄")
        panel.message = PhotoL10n.text("在預覽下方瀏覽此目錄的照片與 RAW 檔案。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = photoDirectoryStore.directoryURL ?? lastImageImportDirectoryURL()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard self.canImport else {
                self.sendToast("請等目前的處理完成後再選取照片目錄。")
                return
            }
            self.selectNewPhotoDirectory(url)
            // A fresh panel selection also renews access when its path is unchanged.
            self.rememberPhotoDirectory(forceBookmark: true)
        }
    }

    /// Explicit folder selection opens its first photo; launch restoration keeps the remembered photo.
    func selectNewPhotoDirectory(_ url: URL) {
        let generation = photoGeneration
        photoDirectoryStore.selectDirectory(url) { [weak self] firstPhoto in
            guard let self, let firstPhoto, self.canImport,
                  self.photoGeneration == generation else { return }
            guard self.sourceFileURL?.standardizedFileURL.resolvingSymlinksInPath()
                != firstPhoto.standardizedFileURL.resolvingSymlinksInPath() else { return }
            self.loadPickedImage(from: firstPhoto)
        }
    }

    func selectDirectoryPhoto(_ payload: [String: Any]) {
        guard canImport, let id = payload["id"] as? String,
              let url = photoDirectoryStore.url(for: id) else { return }
        // Clicking the current photo is browsing, not a request to erase its edits.
        guard sourceFileURL?.standardizedFileURL.resolvingSymlinksInPath()
            != url.standardizedFileURL.resolvingSymlinksInPath() else { return }
        loadPickedImage(from: url)
    }

    func showPreviewMenu(_ payload: [String: Any] = [:]) {
        if let id = payload["id"] as? String {
            guard canImport, photoDirectoryStore.url(for: id) != nil else { return }
            let menu = NSMenu()
            let exif = NSMenuItem(title: PhotoL10n.text("顯示 EXIF"), action: #selector(performThumbnailEXIF(_:)), keyEquivalent: "")
            exif.target = self
            exif.representedObject = id
            menu.addItem(exif)
            menu.addItem(.separator())
            let item = NSMenuItem(title: PhotoL10n.text("刪除檔案"),
                                  action: #selector(performThumbnailDelete(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        guard sourceImage != nil, canImport else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, String, Bool)] = [
            ("上一步", "undoEdit", !editUndoStack.isEmpty),
            ("下一步", "redoEdit", !editRedoStack.isEmpty),
            ("恢復預設值", "resetAdjustments", true),
            ("", "", false), ("顯示直方圖", "histogram", true),
            ("顯示 EXIF", "exif", sourceFileURL != nil),
            ("", "", false), ("[裁切] 原始比例", "source", true),
            ("[裁切] 自由調整", "free", true),
            ("", "", false), ("匯出檔案", "saveImage", canExport && !isDetectingSubjectMask),
            ("", "", false), ("顯示在 Finder", "reveal", sourceFileURL != nil),
            ("刪除檔案", "trash", sourceFileURL != nil)
        ]
        for (title, command, enabled) in entries {
            if title.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: PhotoL10n.text(title), action: #selector(performPreviewMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func performPreviewMenu(_ item: NSMenuItem) {
        guard let command = item.representedObject as? String, canImport else { return }
        if command == "reveal", let url = sourceFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        if command == "exif", let url = sourceFileURL { showPhotoEXIF(at: url); return }
        if command == "trash" { confirmTrashCurrentPhoto(); return }
        callJavaScript(function: "handlePreviewMenu", payload: ["command": command])
    }

    @objc func performThumbnailDelete(_ item: NSMenuItem) {
        guard canImport, let id = item.representedObject as? String,
              let url = photoDirectoryStore.url(for: id) else { return }
        confirmTrashCurrentPhoto(targetURL: url)
    }

    func confirmTrashCurrentPhoto(targetURL: URL? = nil) {
        guard let url = targetURL ?? sourceFileURL, let window = webView?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = PhotoL10n.text("將「\(url.lastPathComponent)」移到垃圾桶？")
        alert.informativeText = PhotoL10n.text("可從 Finder 的垃圾桶還原檔案。")
        alert.addButton(withTitle: PhotoL10n.text("移到垃圾桶"))
        alert.addButton(withTitle: PhotoL10n.text("取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.canImport else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                let urls = self.photoDirectoryStore.items.compactMap { self.photoDirectoryStore.url(for: $0.id) }
                let index = urls.firstIndex(of: url) ?? 0
                let remaining = urls.filter { $0 != url }
                let next = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
                let deletingCurrent = self.sourceFileURL == url
                if !deletingCurrent {
                    if let directory = self.photoDirectoryStore.directoryURL {
                        self.photoDirectoryStore.selectDirectory(directory, preferredPhotoURL: self.sourceFileURL)
                    }
                    self.sendState(includeImages: false)
                    return
                }
                self.cancelCurrentSubjectMaskDetection()
                self.clearPreviewRender()
                self.sourceImage = nil
                self.previewImage = nil
                self.sourceSubjectMask = nil
                self.sourceFileURL = nil
                self.sourceFileName = ""
                self.currentPhotoEditKey = nil
                self.currentSourceIdentifier = nil
                self.resetEditHistory()
                self.clearLastImageImportFile()
                self.clearDeletedSourcePersistence()
                if let directory = self.photoDirectoryStore.directoryURL {
                    self.photoDirectoryStore.selectDirectory(directory, preferredPhotoURL: next)
                }
                if let next { self.loadPickedImage(from: next) }
                else { self.sendState(includeImages: true) }
            } catch { self.sendToast("無法刪除檔案：\(error.localizedDescription)") }
        }
    }

}


extension PhotoStyleWebCoordinator {
    @objc func performThumbnailEXIF(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let url = photoDirectoryStore.url(for: id) else { return }
        showPhotoEXIF(at: url)
    }

    func showPhotoEXIF(at url: URL) {
        // Metadata stays bound to the clicked file, independent of photo selection.
        Task { @MainActor [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { PhotoEXIFMetadata.read(url) }.value
            guard let self, !self.isTerminating else { return }
            let order = ["相機與鏡頭", "拍攝設定", "日期與時間", "影像資訊", "GPS", "其他資訊"]
            let groups: [[String: Any]] = order.compactMap { category in
                let entries = (rows ?? []).filter { $0.category == category }
                guard !entries.isEmpty else { return nil }
                return ["title": category, "rows": entries.map { ["label": $0.label, "value": $0.value] }]
            }
            self.callJavaScript(function: "handlePhotoEXIF", payload: [
                "filename": url.lastPathComponent, "groups": groups,
                "message": rows == nil ? "無法讀取此檔案的影像資訊。" : "此檔案沒有可顯示的 EXIF 資訊。"
            ])
        }
    }

}

/// Metadata only: do not decode image pixels or modify the original file.
enum PhotoEXIFMetadata {
    struct Row: Sendable {
        let category: String
        let label: String
        let value: String
    }
    static func formatNumber(_ number: NSNumber) -> String {
        let value = number.doubleValue
        guard value.isFinite else { return "—" }
        if value.rounded() == value { return number.stringValue }
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func category(for key: String, group: String) -> String {
        if group == "GPS" { return "GPS" }
        if key.contains("Date") || key.contains("OffsetTime") || key.contains("SubsecTime") { return "日期與時間" }
        if ["Make", "Model", "Software"].contains(key) || key.contains("Lens") || key.contains("Serial") || key.contains("Owner") { return "相機與鏡頭" }
        if ["Compression", "Orientation", "PhotometricInterpretation", "ColorSpace", "ComponentsConfiguration", "CFAPattern", "PixelXDimension", "PixelYDimension", "XResolution", "YResolution", "ResolutionUnit", "ExifVersion", "FlashPixVersion", "CompressedBitsPerPixel"].contains(key) { return "影像資訊" }
        if group == "EXIF" { return "拍攝設定" }
        return "其他資訊"
    }
    static func read(_ url: URL) -> [Row]? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        var rows: [Row] = []
        if let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber {
            rows.append(Row(category: "影像資訊", label: "影像尺寸", value: "\(width) × \(height) px"))
        }
        let labels = ["Make": "相機廠牌", "Model": "相機型號", "LensModel": "鏡頭型號",
                      "DateTimeOriginal": "拍攝時間", "ExposureTime": "曝光時間", "FNumber": "光圈",
                      "ISOSpeedRatings": "ISO", "FocalLength": "焦距", "ExposureBiasValue": "曝光補償",
                      "DateTime": "修改時間", "DateTimeDigitized": "數位化時間", "Software": "軟體版本",
                      "BodySerialNumber": "機身序號", "LensSerialNumber": "鏡頭序號", "LensMake": "鏡頭廠牌",
                      "Orientation": "影像方向", "Compression": "壓縮格式", "ColorSpace": "色彩空間",
                      "Flash": "閃光燈", "MeteringMode": "測光模式", "ExposureProgram": "曝光模式",
                      "WhiteBalance": "白平衡", "ShutterSpeedValue": "快門值（APEX）", "ApertureValue": "光圈值（APEX）",
                      "BrightnessValue": "亮度值", "FocalLenIn35mmFilm": "35mm 等效焦距"]
        let groups = [(kCGImagePropertyTIFFDictionary, "TIFF"), (kCGImagePropertyExifDictionary, "EXIF"),
                      (kCGImagePropertyExifAuxDictionary, "EXIF Aux"), (kCGImagePropertyGPSDictionary, "GPS")]
        for (group, name) in groups {
            guard let fields = properties[group as String] as? [String: Any] else { continue }
            for key in fields.keys.sorted() {
                guard let value = fields[key], !(value is Data), !(value is [String: Any]) else { continue }
                let formatted: String
                if let n = value as? NSNumber, key == "ExposureTime", n.doubleValue > 0 {
                    formatted = n.doubleValue < 1 ? String(format: "1/%.0f s", 1/n.doubleValue) : "\(formatNumber(n)) s"
                } else if let n = value as? NSNumber, key == "FNumber" { formatted = "f/\(formatNumber(n))" }
                else if let n = value as? NSNumber, key == "FocalLength" { formatted = "\(formatNumber(n)) mm" }
                else if let values = value as? [NSNumber] { formatted = values.prefix(32).map { formatNumber($0) }.joined(separator: ", ") }
                else if let text = value as? String { formatted = String(text.prefix(4096)) }
                else if let n = value as? NSNumber { formatted = formatNumber(n) }
                else { continue }
                rows.append(Row(category: category(for: key, group: name), label: labels[key] ?? key, value: formatted))
            }
        }
        return rows
    }
}
