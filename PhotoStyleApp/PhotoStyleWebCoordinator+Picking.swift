import CoreImage
import ImageIO
import AppKit
import UniformTypeIdentifiers
import PhotoStyleShared

final class PhotoStyleImageLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

extension PhotoStyleWebCoordinator {
    func loadPickedImage(from url: URL, cancellation: PhotoStyleImageLoadCancellation? = nil, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard !isLoadingImage, !isComputing, !isSavingImage else {
            completion?(.failure(PhotoStyleMCPTools.failure("目前正在處理照片。")))
            return
        }
        // An explicit open owns the initial image, even while WKWebView is loading.
        // Otherwise didFinish can launch restoration and replace this new photo.
        hasAttemptedLastSourceImageRestore = true
        commitAdjustmentPreview()
        isLoadingImage = true
        // Directory thumbnails can be padded camera EXIF previews. Do not expand
        // their baked-in black borders into the editing canvas while RAW loads.
        loadingPreviewImagePayload = nil
        sendState(includeImages: true)

        let workGate = photoDirectoryStore.previewWorkGate
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            workGate.withEditorWork {
                let startedAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if startedAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                var loadedImage: PhotoImage?
                var loadedImageData: Data?
                var loadedImageBookmark: Data?
                var loadedImageIdentifier: String?
                var preparedThumbnailPayload: String?
                var loadingError: Error?
                var coordinatorError: NSError?
                let coordinator = NSFileCoordinator(filePresenter: nil)

                coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readableURL in
                    do {
                        let data = try Data(contentsOf: readableURL)
                        if let quickPreview = loadingPreviewDataURL(from: data) {
                            preparedThumbnailPayload = quickPreview
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.isLoadingImage, cancellation?.isCancelled != true else { return }
                                self.loadingPreviewImagePayload = quickPreview
                                self.sendState(includeImages: true)
                            }
                        }
                        loadedImage = self?.decodePickedImage(data: data, url: readableURL)
                        if loadedImage != nil {
                            loadedImageData = data
                            loadedImageIdentifier = Self.sourceImageIdentifier(for: data)
                            loadedImageBookmark = try? url.bookmarkData(
                                options: [.withSecurityScope],
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            )
                        }
                    } catch {
                        loadingError = error
                    }
                }

                let preparedProcessingImage = cancellation?.isCancelled == true ? nil : loadedImage?.processingPreview(maxPixel: Self.processingPreviewMaxPixel)
                let preparedPreview = cancellation?.isCancelled == true ? nil : loadedImage?.editingWebPreview()
                let preparedPreviewPayload = preparedPreview.flatMap { imageDataURL($0.originalRendering) }
                Task { @MainActor in
                    guard let self else { return }
                    self.isLoadingImage = false
                    self.loadingPreviewImagePayload = nil
                    if cancellation?.isCancelled == true {
                        self.sendState(includeImages: true)
                        completion?(.failure(CancellationError()))
                        return
                    }
                    if let image = loadedImage {
                        let accepted = await self.setSourceImage(
                            image,
                            preparedPreview: preparedPreview,
                            preparedProcessingImage: preparedProcessingImage,
                            preparedPreviewPayload: preparedPreviewPayload,
                            preparedThumbnailPayload: preparedThumbnailPayload,
                            persistenceData: loadedImageData,
                            persistenceFileExtension: url.pathExtension,
                            sourceIdentifier: loadedImageIdentifier,
                            sourceURL: url,
                            persistsForNextLaunch: self.persistsImportedImages,
                            filename: url.lastPathComponent, cancellation: cancellation
                        )
                        guard accepted else { completion?(.failure(CancellationError())); return }
                        self.rememberImageImportFile(url, bookmarkData: loadedImageBookmark)
                        completion?(.success(()))
                    } else if let loadingError {
                        self.sendState(includeImages: true)
                        self.sendToast("無法讀取圖片：\(loadingError.localizedDescription)")
                        completion?(.failure(loadingError))
                    } else if let coordinatorError {
                        self.sendState(includeImages: true)
                        self.sendToast("無法讀取圖片：\(coordinatorError.localizedDescription)")
                        completion?(.failure(coordinatorError))
                    } else {
                        self.sendState(includeImages: true)
                        self.sendToast("選取的檔案不是可支援的圖片格式。")
                        completion?(.failure(PhotoStyleMCPTools.failure("選取的檔案不是可支援的圖片格式。")))
                    }
                }
            }
        }
    }

    func rememberImageImportFile(_ fileURL: URL, bookmarkData: Data?) {
        let defaults = UserDefaults.standard
        defaults.set(fileURL.path, forKey: Self.lastImageImportFilePathDefaultsKey)
        if let bookmarkData {
            defaults.set(bookmarkData, forKey: Self.lastImageImportFileBookmarkDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.lastImageImportFileBookmarkDefaultsKey)
        }
        rememberImageImportDirectory(fileURL.deletingLastPathComponent())
    }

    func clearLastImageImportFile() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.lastImageImportFilePathDefaultsKey)
        defaults.removeObject(forKey: Self.lastImageImportFileBookmarkDefaultsKey)
    }

    func rememberImageImportDirectory(_ directoryURL: URL) {
        UserDefaults.standard.set(directoryURL.path, forKey: Self.lastImageImportDirectoryPathDefaultsKey)
    }

    func lastImageImportDirectoryURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastImageImportDirectoryPathDefaultsKey),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func decodePickedImage(data: Data, url: URL, backend: PhotoRAWBackend? = nil, lensCorrection: Bool? = nil) -> PhotoImage? {
        PhotoBackendRouter.decode(data: data, url: url, backend: backend ?? rawDecoderBackend,
                                  lensCorrection: lensCorrection ?? lensCorrectionEnabled)
    }
    func decodeImageSource(_ source: CGImageSource) -> PhotoImage? { PhotoImageDecoder.decodeImageSource(source) }
    static func rawBitmapIsCollapsed(_ image: PhotoImage) -> Bool { PhotoImageDecoder.rawBitmapIsCollapsed(image) }
    static func rawPreviewHasVisibleContent(_ image: PhotoImage) -> Bool { PhotoImageDecoder.rawPreviewHasVisibleContent(image) }
}
