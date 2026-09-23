import AppKit
import UniformTypeIdentifiers

extension PhotoStyleWebCoordinator {
    func openImage(at url: URL) {
        guard url.isFileURL else { return }
        if !isWebReady {
            pendingOpenURL = url
        } else if canImport {
            loadPickedImage(from: url)
        } else {
            sendToast("請等目前的處理完成後再開啟照片。")
        }
    }

    func openFilePicker() {
        guard canImport, let window = webView?.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = PhotoL10n.text("開啟照片")
        panel.prompt = PhotoL10n.text("開啟")
        panel.allowedContentTypes = [.image, .rawImage]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let initialURL = lastImageImportFileURL()
        let scoped = initialURL?.startAccessingSecurityScopedResource() ?? false
        panel.directoryURL = initialURL?.deletingLastPathComponent() ?? lastImageImportDirectoryURL()
        panel.beginSheetModal(for: window) { [weak self] response in
            defer { if scoped { initialURL?.stopAccessingSecurityScopedResource() } }
            guard response == .OK, let url = panel.url else { return }
            self?.openImage(at: url)
        }
    }

    func openModelDirectoryPicker() {
        guard !aiModelStore.isBusy, !isComputing, !isLoadingImage, !isSavingImage,
              let window = webView?.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = PhotoL10n.text("選取模型目錄")
        panel.prompt = PhotoL10n.text("選取目錄")
        panel.message = PhotoL10n.text("掃描 GGUF（主模型＋mmproj）與 MLX 視覺模型資料夾，並將新下載的模型儲存於此目錄。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = aiModelStore.directoryCatalog.directoryURL ?? aiModelStore.status.modelDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard !self.aiModelStore.isBusy, !self.isComputing, !self.isLoadingImage, !self.isSavingImage else {
                self.sendToast("請等目前的處理完成後再選取模型目錄。")
                return
            }
            self.aiModelStore.selectModelDirectory(url) { [weak self] _ in
                self?.sendState(includeImages: false)
            }
            self.sendState(includeImages: false)
        }
    }

    func openCustomModelPicker() {
        guard !aiModelStore.isBusy, !isComputing, let window = webView?.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = PhotoL10n.text("匯入 AI 模型與視覺編碼器")
        panel.prompt = PhotoL10n.text("匯入")
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            guard !self.aiModelStore.isBusy, !self.isComputing, !self.isLoadingImage, !self.isSavingImage else {
                self.sendToast("請等目前的處理完成後再匯入模型。")
                return
            }
            self.aiModelStore.importCustomModel(from: panel.urls) { [weak self] _ in
                self?.sendState(includeImages: false)
            }
            self.sendState(includeImages: false)
        }
    }

    func showPage(_ page: String) {
        webView?.evaluateJavaScript("window.handleDesktopCommand(\(Self.jsonString(page)))", completionHandler: nil)
    }
}
