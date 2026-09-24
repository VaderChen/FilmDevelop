import AppKit

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

    func showPreviewMenu() {
        guard sourceImage != nil, canImport else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, String, Bool)] = [
            ("上一步", "undoEdit", !editUndoStack.isEmpty),
            ("下一步", "redoEdit", !editRedoStack.isEmpty),
            ("恢復預設值", "resetAdjustments", true),
            ("", "", false), ("顯示直方圖", "histogram", true),
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
        if command == "trash" { confirmTrashCurrentPhoto(); return }
        callJavaScript(function: "handlePreviewMenu", payload: ["command": command])
    }

    func confirmTrashCurrentPhoto() {
        guard let url = sourceFileURL, let window = webView?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = PhotoL10n.text("將「\(url.lastPathComponent)」移到垃圾桶？")
        alert.informativeText = PhotoL10n.text("可從 Finder 的垃圾桶還原檔案。")
        alert.addButton(withTitle: PhotoL10n.text("移到垃圾桶"))
        alert.addButton(withTitle: PhotoL10n.text("取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.canImport,
                  self.sourceFileURL == url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                let urls = self.photoDirectoryStore.items.compactMap { self.photoDirectoryStore.url(for: $0.id) }
                let index = urls.firstIndex(of: url) ?? 0
                let remaining = urls.filter { $0 != url }
                let next = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
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
