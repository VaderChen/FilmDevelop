import CoreImage
import ImageIO
import AppKit
import UniformTypeIdentifiers

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
        loadingPreviewImagePayload = photoDirectoryStore.items.first {
            photoDirectoryStore.url(for: $0.id)?.standardizedFileURL == url.standardizedFileURL
        }?.thumbnail
        let hasLoadingPreview = loadingPreviewImagePayload != nil
        sendState(includeImages: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
            var loadingError: Error?
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)

            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readableURL in
                do {
                    let data = try Data(contentsOf: readableURL)
                    if !hasLoadingPreview, let quickPreview = loadingPreviewDataURL(from: data) {
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

            let preparedProcessingImage = cancellation?.isCancelled == true ? nil : loadedImage?.resizedForWebPreview(maxPixel: Self.processingPreviewMaxPixel)
            let preparedPreview = cancellation?.isCancelled == true ? nil : loadedImage?.resizedForWebPreview(maxPixel: PhotoImage.previewMaxPixel)
            let preparedPreviewPayload = preparedPreview.flatMap { imageDataURL($0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingImage = false
                self.loadingPreviewImagePayload = nil
                if cancellation?.isCancelled == true {
                    self.sendState(includeImages: true)
                    completion?(.failure(CancellationError()))
                    return
                }
                if let image = loadedImage {
                    self.sourceFileName = url.lastPathComponent
                    self.rememberImageImportFile(url, bookmarkData: loadedImageBookmark)
                    self.setSourceImage(
                        image,
                        preparedPreview: preparedPreview,
                        preparedProcessingImage: preparedProcessingImage,
                        preparedPreviewPayload: preparedPreviewPayload,
                        persistenceData: loadedImageData,
                        persistenceFileExtension: url.pathExtension,
                        sourceIdentifier: loadedImageIdentifier,
                        sourceURL: url,
                        persistsForNextLaunch: self.persistsImportedImages
                    )
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

    func decodePickedImage(data: Data, url: URL) -> PhotoImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            // Nikon NEF can be reported as public.tiff with a tiny embedded JPEG
            // at index zero. Decode camera RAW before accepting that raster image.
            let isRAWFile = UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
            if sourceContainsRAWData(source) || isRAWFile,
               let image = decodeRAWImage(data: data, url: url) {
                return image
            }
            if let image = decodeImageSource(source) {
                return image
            }
        }

        if let image = decodeRAWImage(data: data, url: url) {
            return image
        }

        if let image = PhotoImage(data: data) {
            return image
        }

        // Decode only the coordinated snapshot: rereading the URL can display different bytes
        // from the content identifier and the copy persisted for the next launch.
        let ciImage = CIImage(data: data, options: [.applyOrientationProperty: true])
        guard let ciImage else { return nil }
        return PhotoImageRenderPrecision.renderedImage(
            from: ciImage,
            context: Self.imageDecodeContext,
            highPrecision: false,
            scale: 1
        )
    }

    private func sourceContainsRAWData(_ source: CGImageSource) -> Bool {
        guard let typeIdentifier = CGImageSourceGetType(source),
              let type = UTType(typeIdentifier as String) else {
            return false
        }
        return type.conforms(to: .rawImage)
    }

    private func decodeRAWImage(data: Data, url: URL) -> PhotoImage? {
        let identifierHint = UTType(filenameExtension: url.pathExtension)?.identifier
        let rawFilter = CIRAWFilter(
            imageData: data,
            identifierHint: identifierHint
        )
        // Malformed files can return nil metadata despite the SDK's nonnull annotation.
        // KVC keeps that Objective-C nil optional instead of trapping during Swift bridging.
        guard let rawFilter,
              let rawProperties = rawFilter.value(forKey: "properties") as? NSDictionary,
              rawFilterContainsHighDepthSensorData(rawProperties),
              let output = rawFilter.outputImage,
              output.extent.minX.isFinite,
              output.extent.minY.isFinite,
              output.extent.width.isFinite,
              output.extent.height.isFinite,
              !output.extent.isEmpty else {
            return nil
        }

        let properties = rawProperties
        let profileName = properties[kCGImagePropertyProfileName] as? String
        let colorSpaceName = profileName?.localizedCaseInsensitiveContains("P3") == true
            ? CGColorSpace.extendedLinearDisplayP3
            : CGColorSpace.extendedLinearSRGB
        return PhotoImageRenderPrecision.renderedImage(
            from: output,
            context: Self.imageDecodeContext,
            highPrecision: true,
            colorSpace: CGColorSpace(name: colorSpaceName),
            // Finish RAW decoding before any preview, statistics or development
            // branch resamples it. A deferred RAW provider can replay decoding
            // and return corrupt tiles when those branches request different scales.
            scale: 1,
            deferred: false
        )
    }

    private func rawFilterContainsHighDepthSensorData(_ properties: NSDictionary) -> Bool {
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 0
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        let hasColorFilterArray = exif?[kCGImagePropertyExifCFAPattern] != nil
        let photometricInterpretation = (
            tiff?[kCGImagePropertyTIFFPhotometricInterpretation] as? NSNumber
        )?.intValue
        let hasRawPhotometricData = photometricInterpretation == 32_803
        let hasCameraMakerData = properties.allKeys.contains {
            String(describing: $0).hasPrefix("{Maker")
        }
        return depth > 8
            && (hasColorFilterArray || hasRawPhotometricData || hasCameraMakerData)
    }

    func decodeImageSource(_ source: CGImageSource) -> PhotoImage? {
        guard CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = properties?[kCGImagePropertyOrientation] as? UInt32
        let orientation = rawOrientation
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return PhotoImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }
}
