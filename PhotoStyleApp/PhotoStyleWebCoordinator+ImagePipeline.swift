import CryptoKit
import AppKit

extension PhotoStyleWebCoordinator {
    private static let lastSourceImagePersistenceQueue = DispatchQueue(
        label: "person.vader.PhotoStyleApp.lastSourceImage",
        qos: .utility
    )
    private static let lastSourceImageBaseFilename = "last-opened-image"
    // This identifier follows the saved adjustments, independently of an asynchronous cache write.
    private static let sourceAdjustmentIdentifierDefaultsKey = "sourceAdjustmentIdentifier.v1"
    private static let sourceAdjustmentPhotoKeyDefaultsKey = "sourceAdjustmentPhotoKey.v1"
    private static let sourceRenderingMetadataDefaultsKey = "sourceRenderingMetadata.v1"

    private struct PersistedSourceImage {
        let data: Data
        let fileExtension: String
    }

    private struct RestoredSourceImage {
        let image: PhotoImage
        let data: Data
        let fileExtension: String
        let sourceIdentifier: String
        let needsPersistence: Bool
    }

    func setSourceImage(
        _ image: PhotoImage,
        preparedPreview: PhotoImage? = nil,
        preparedProcessingImage: PhotoImage? = nil,
        preparedPreviewPayload: String? = nil,
        persistenceData: Data? = nil,
        persistenceFileExtension: String? = nil,
        sourceIdentifier: String? = nil,
        sourceURL: URL? = nil,
        persistsForNextLaunch: Bool = true
    ) {
        // Commit the outgoing recipe before changing the image's identity.
        persistCurrentPhotoEdits()
        isRestoringPhotoEdits = true
        cancelCurrentSubjectMaskDetection()
        let hadSourceImage = sourceImage != nil
        let previousPreviewSize = previewImage?.size
        sourceImage = image
        processingImage = preparedProcessingImage
        sourceFileURL = sourceURL
        previewImage = preparedPreview ?? image.resizedForWebPreview(maxPixel: PhotoImage.previewMaxPixel)
        previewImagePayload = [:]
        loadingPreviewImagePayload = preparedPreviewPayload
        outputImage = nil
        let defaults = UserDefaults.standard
        let previousSourceIdentifier = hadSourceImage ? currentSourceIdentifier : (
            currentSourceIdentifier
                ?? defaults.string(forKey: Self.sourceAdjustmentIdentifierDefaultsKey)
                ?? defaults.string(forKey: Self.lastSourceImageIdentifierDefaultsKey)
        )
        let nextPhotoKey = PhotoEditStore.key(identifier: sourceIdentifier, url: sourceURL)
        let previousPhotoKey = hadSourceImage ? currentPhotoEditKey : defaults.string(forKey: Self.sourceAdjustmentPhotoKeyDefaultsKey)
        let isSameSourceImage = sourceIdentifier != nil && sourceIdentifier == previousSourceIdentifier
            && (previousPhotoKey == nil || previousPhotoKey == nextPhotoKey)
        if !isSameSourceImage || previousPreviewSize != previewImage?.size {
            sourceSubjectMask = nil
        }
        repairPatches = []
        // A known photo's recipe wins over the global last-look defaults.
        if let nextPhotoKey, let record = photoEditStore.record(for: nextPhotoKey),
           let restoredStyle = PhotoStyle(rawValue: record.selectedStyle) {
            if let sourceURL, !photoEditStore.hasRecordedEditState(at: sourceURL), record.adjustments.contains(where: { raw, adjustment in
                guard let style = PhotoStyle(rawValue: raw) else { return false }
                let defaults = StyleAdjustment.default(for: style)
                var legacyDefaults = defaults
                legacyDefaults.filmEffects.scannerProfile = .off
                // Earlier versions saved even untouched photos with scanning off.
                return adjustment != defaults && adjustment != legacyDefaults
            }) { photoEditStore.markEdited(at: sourceURL) }
            let custom = customFilmStore.film(id: record.customFilmID)
            selectedCustomFilmID = custom?.baseStyle == restoredStyle.rawValue ? custom?.id : nil
            customFilmBaseAdjustment = selectedCustomFilmID == nil ? nil : record.customFilmBaseAdjustment
            repairPatches = record.repairPatches ?? []
            selectedStyle = restoredStyle
            adjustmentStore.restorePhotoAdjustments(record.adjustments)
        } else if !isSameSourceImage {
            adjustmentStore.startNewPhoto()
            customFilmBaseAdjustment = nil
            if let film = customFilmStore.film(id: selectedCustomFilmID), let base = PhotoStyle(rawValue: film.baseStyle) {
                customFilmBaseAdjustment = adjustmentStore.adjustment(for: base)
                selectedStyle = base
                adjustmentStore.setAdjustment(film.adjustment, for: base)
            }
        }
        if let nextPhotoKey, let size = previewImage?.size {
            sourceSubjectMask = photoEditStore.mask(for: nextPhotoKey, size: size) ?? sourceSubjectMask
        }
        currentPhotoEditKey = nextPhotoKey
        currentSourceIdentifier = sourceIdentifier
        // An empty identifier records an unknown source and prevents legacy cache metadata reuse.
        defaults.set(sourceIdentifier ?? "", forKey: Self.sourceAdjustmentIdentifierDefaultsKey)
        defaults.set(nextPhotoKey ?? "", forKey: Self.sourceAdjustmentPhotoKeyDefaultsKey)
        defaults.set(selectedStyle.rawValue, forKey: Self.selectedStyleDefaultsKey)
        isRestoringPhotoEdits = false
        resetEditHistory()
        if persistsForNextLaunch {
            persistLastSourceImage(
                image,
                preferredData: persistenceData,
                preferredFileExtension: persistenceFileExtension
            )
        }
        // Opening, restoring and browsing photos only render existing adjustments.
        // AI analysis and subject detection require an explicit editing command.
        applySelectedStyle()
        sendState(includeImages: true, externalEdit: true)
    }

    func restoreLastSourceImageIfNeeded() -> Bool {
        guard !hasAttemptedLastSourceImageRestore, !isLoadingImage, !isComputing, !isSavingImage else { return false }
        hasAttemptedLastSourceImageRestore = true
        guard sourceImage == nil else { return false }

        let privateImageURL = try? lastSourceImageURL(createDirectory: false)
        let importedImageURL = lastImageImportFileURL()
        guard privateImageURL != nil || importedImageURL != nil else {
            return false
        }

        isLoadingImage = true
        sendState(includeImages: false)
        Self.lastSourceImagePersistenceQueue.async { [weak self] in
            guard let self else { return }
            let restoredImage = self.restorePrivateSourceImage(from: privateImageURL)
                ?? importedImageURL.flatMap { self.restoreImportedSourceImage(from: $0) }

            let preparedProcessingImage = restoredImage?.image.resizedForWebPreview(maxPixel: Self.processingPreviewMaxPixel)
            let preparedPreview = restoredImage?.image.resizedForWebPreview(maxPixel: PhotoImage.previewMaxPixel)
            let preparedPreviewPayload = preparedPreview.flatMap { imageDataURL($0) }
            DispatchQueue.main.async {
                self.isLoadingImage = false
                if let restoredImage {
                    self.sourceFileName = importedImageURL?.lastPathComponent ?? ""
                    self.setSourceImage(
                        restoredImage.image,
                        preparedPreview: preparedPreview,
                        preparedProcessingImage: preparedProcessingImage,
                        preparedPreviewPayload: preparedPreviewPayload,
                        persistenceData: restoredImage.needsPersistence ? restoredImage.data : nil,
                        persistenceFileExtension: restoredImage.fileExtension,
                        sourceIdentifier: restoredImage.sourceIdentifier,
                        sourceURL: importedImageURL,
                        persistsForNextLaunch: restoredImage.needsPersistence
                    )
                } else {
                    if let privateImageURL, self.isManagedSourceImageURL(privateImageURL) {
                        try? FileManager.default.removeItem(at: privateImageURL)
                    }
                    UserDefaults.standard.removeObject(forKey: Self.lastSourceImagePathDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: Self.lastSourceImageIdentifierDefaultsKey)
                    UserDefaults.standard.removeObject(forKey: Self.sourceAdjustmentIdentifierDefaultsKey)
                    self.adjustmentStore.resetImageScopedCorrections()
                    self.sendState(includeImages: false)
                }
            }
        }
        return true
    }

    private func restorePrivateSourceImage(from imageURL: URL?) -> RestoredSourceImage? {
        guard let imageURL, isManagedSourceImageURL(imageURL),
              let data = try? Data(contentsOf: imageURL) else {
            return nil
        }
        let fileExtension = restorationFileExtension(for: imageURL)
        let decodingURL = imageURL.deletingPathExtension().appendingPathExtension(fileExtension)
        guard var image = decodePickedImage(data: data, url: decodingURL) else {
            return nil
        }
        let identifier = Self.sourceImageIdentifier(for: data)
        if let metadata = UserDefaults.standard.dictionary(forKey: Self.sourceRenderingMetadataDefaultsKey),
           metadata["identifier"] as? String == identifier,
           let requiresMapping = metadata["requiresRAWDisplayMapping"] as? Bool,
           let cgImage = image.cgImage {
            // Older caches recorded false when ImageIO returned a RAW thumbnail.
            // A freshly decoded sensor image must keep its required display mapping.
            image = PhotoImage(cgImage: cgImage,
                               requiresRAWDisplayMapping: image.requiresRAWDisplayMapping || requiresMapping)
        }
        return RestoredSourceImage(
            image: image,
            data: data,
            fileExtension: fileExtension,
            sourceIdentifier: identifier,
            needsPersistence: imageURL.pathExtension != fileExtension
        )
    }

    func lastImageImportFileURL() -> URL? {
        let defaults = UserDefaults.standard
        if let bookmarkData = defaults.data(forKey: Self.lastImageImportFileBookmarkDefaultsKey) {
            var bookmarkIsStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            ) {
                return url
            }
        }

        guard let path = defaults.string(forKey: Self.lastImageImportFilePathDefaultsKey),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private func restoreImportedSourceImage(from imageURL: URL) -> RestoredSourceImage? {
        let startedAccessing = imageURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                imageURL.stopAccessingSecurityScopedResource()
            }
        }

        var loadedData: Data?
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: imageURL, options: [], error: &coordinatorError) { readableURL in
            loadedData = try? Data(contentsOf: readableURL)
        }
        guard coordinatorError == nil,
              let loadedData,
              let image = decodePickedImage(data: loadedData, url: imageURL) else {
            return nil
        }
        return RestoredSourceImage(
            image: image,
            data: loadedData,
            fileExtension: Self.normalizedFileExtension(imageURL.pathExtension) ?? "data",
            sourceIdentifier: Self.sourceImageIdentifier(for: loadedData),
            needsPersistence: true
        )
    }

    private func persistLastSourceImage(
        _ image: PhotoImage,
        preferredData: Data?,
        preferredFileExtension: String?
    ) {
        Self.lastSourceImagePersistenceQueue.async { [weak self] in
            guard let self else { return }
            let persistedImage: PersistedSourceImage?
            if let preferredData {
                persistedImage = PersistedSourceImage(
                    data: preferredData,
                    fileExtension: Self.normalizedFileExtension(preferredFileExtension) ?? "data"
                )
            } else {
                persistedImage = Self.persistenceData(for: image)
            }
            guard let persistedImage else {
                DispatchQueue.main.async {
                    self.sendToast("無法記住這張照片。")
                }
                return
            }

            do {
                let imageURL = try self.lastSourceImageURL(
                    fileExtension: persistedImage.fileExtension,
                    createDirectory: true
                )
                try persistedImage.data.write(to: imageURL, options: .atomic)
                UserDefaults.standard.set([
                    "identifier": Self.sourceImageIdentifier(for: persistedImage.data),
                    "requiresRAWDisplayMapping": image.requiresRAWDisplayMapping
                ], forKey: Self.sourceRenderingMetadataDefaultsKey)
                UserDefaults.standard.set(imageURL.path, forKey: Self.lastSourceImagePathDefaultsKey)
                UserDefaults.standard.set(
                    Self.sourceImageIdentifier(for: persistedImage.data),
                    forKey: Self.lastSourceImageIdentifierDefaultsKey
                )
                self.removeStaleLastSourceImages(excluding: imageURL)
            } catch {
                DispatchQueue.main.async {
                    self.sendToast("無法記住這張照片：\(error.localizedDescription)")
                }
            }
        }
    }

    @MainActor
    func clearDeletedSourcePersistence() {
        Self.lastSourceImagePersistenceQueue.async { [self] in
            if let url = try? lastSourceImageURL(createDirectory: false) {
                try? FileManager.default.removeItem(at: url)
            }
            UserDefaults.standard.removeObject(forKey: Self.lastSourceImagePathDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.lastSourceImageIdentifierDefaultsKey)
        }
    }

    @MainActor
    func waitForSourcePersistence() async {
        await withCheckedContinuation { continuation in
            Self.lastSourceImagePersistenceQueue.async { continuation.resume() }
        }
        await photoEditStore.flush()
    }

    private func sourceImageDirectory(create: Bool) throws -> URL {
        let directory: URL
        if let sourcePersistenceDirectory {
            directory = sourcePersistenceDirectory.standardizedFileURL
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: create
            )
            directory = support.appendingPathComponent("PhotoStyleApp", isDirectory: true)
        }
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var mutableDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableDirectory.setResourceValues(values)
        }
        return directory
    }

    private func isManagedSourceImageURL(_ url: URL) -> Bool {
        guard let directory = try? sourceImageDirectory(create: false),
              url.isFileURL,
              url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                == directory.resolvingSymlinksInPath().standardizedFileURL,
              url.deletingPathExtension().lastPathComponent == Self.lastSourceImageBaseFilename,
              Self.normalizedFileExtension(url.pathExtension) != nil,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return true
    }

    private func lastSourceImageURL(
        fileExtension: String? = nil,
        createDirectory: Bool
    ) throws -> URL {
        let directory = try sourceImageDirectory(create: createDirectory)
        if createDirectory {
            guard let fileExtension = Self.normalizedFileExtension(fileExtension) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return directory.appendingPathComponent(Self.lastSourceImageBaseFilename)
                .appendingPathExtension(fileExtension)
        }

        if let path = UserDefaults.standard.string(forKey: Self.lastSourceImagePathDefaultsKey),
           !path.isEmpty {
            let imageURL = URL(fileURLWithPath: path)
            // A recorded but missing cache should fall back to the imported file, not another old cache.
            guard isManagedSourceImageURL(imageURL) else { throw CocoaError(.fileNoSuchFile) }
            return imageURL
        }
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { isManagedSourceImageURL($0) }.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
        guard let imageURL = candidates.first else { throw CocoaError(.fileNoSuchFile) }
        return imageURL
    }

    private func restorationFileExtension(for imageURL: URL) -> String {
        let current = Self.normalizedFileExtension(imageURL.pathExtension) ?? "data"
        guard current == "data",
              let importedPath = UserDefaults.standard.string(forKey: Self.lastImageImportFilePathDefaultsKey),
              let originalExtension = Self.normalizedFileExtension(URL(fileURLWithPath: importedPath).pathExtension) else {
            return current
        }
        return originalExtension
    }

    private static func persistenceData(for image: PhotoImage) -> PersistedSourceImage? {
        // Imported files keep their original bytes above. A generated working image
        // must retain its floating range and precision across an app restart.
        image.floatingPointTIFFData().map { PersistedSourceImage(data: $0, fileExtension: "tiff") }
    }

    private static func normalizedFileExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        guard !normalized.isEmpty,
              normalized.count <= 12,
              normalized.utf8.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
              }) else {
            return nil
        }
        return normalized
    }

    static func sourceImageIdentifier(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func removeStaleLastSourceImages(excluding currentURL: URL) {
        let directoryURL = currentURL.deletingLastPathComponent()
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
                != currentURL.resolvingSymlinksInPath().standardizedFileURL.path
                && isManagedSourceImageURL($0)
        }
        candidates.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func renderingAdjustment(_ adjustment: StyleAdjustment) -> StyleAdjustment {
        guard !hdrFeatureEnabled else { return adjustment }
        var output = adjustment
        output.hdrAmount = 0
        return output
    }

    func applySelectedStyle(detectSubjectMask: Bool = false, interactive: Bool = false, cropPreview: Bool = false) {
        let needsMask = detectSubjectMask || adjustmentPreviewNeedsMask
            || (adjustmentStore.adjustment(for: selectedStyle).requiresSubjectMask
                && subjectMaskAttemptedGeneration != photoGeneration)
        if interactive {
            adjustmentPreviewNeedsMask = needsMask
        } else {
            cancelAdjustmentPreview()
        }
        // Complete a crop from the source pixels, not the low-resolution drag proxy.
        guard let image = cropPreview ? sourceImage : (interactive ? (previewImage ?? editingImage) : editingImage) else {
            clearPreviewRender()
            return
        }
        var adjustment = adjustmentStore.adjustment(for: selectedStyle)
        if adjustment.resolveHDRToneCurveFromAIAnalysisIfNeeded() {
            adjustmentStore.setAdjustment(adjustment, for: selectedStyle)
        }
        persistCurrentPhotoEdits()
        enqueuePreviewRender(.init(
            style: selectedStyle,
            adjustment: renderingAdjustment(adjustment),
            image: image,
            subjectMask: sourceSubjectMask,
            shouldDetectSubjectMask: !interactive && needsMask && sourceSubjectMask == nil && renderer.canDetectSubjectMask,
            repairPatches: repairPatches
        ))
    }

    func startSubjectMaskDetection(for image: PhotoImage) {
        let detectionID = UUID()
        subjectMaskDetectionID = detectionID
        isDetectingSubjectMask = true
        sendState(includeImages: true)

        let workItem = DispatchWorkItem { [weak self, image] in
            let mask = self?.renderer.detectSubjectMask(for: image)
            DispatchQueue.main.async {
                guard let self,
                      self.subjectMaskDetectionID == detectionID,
                      self.isDetectingSubjectMask else {
                    return
                }

                self.subjectMaskWorkItem = nil
                self.sourceSubjectMask = mask
                self.subjectMaskAttemptedGeneration = self.photoGeneration
                self.isDetectingSubjectMask = false
                self.applySelectedStyle()
                self.sendState(includeImages: true)
            }
        }

        subjectMaskWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    func cancelSubjectMaskDetection() {
        guard isDetectingSubjectMask else { return }
        cancelCurrentSubjectMaskDetection()
        sourceSubjectMask = nil
        subjectMaskAttemptedGeneration = photoGeneration
        applySelectedStyle()
        sendState(includeImages: true)
    }

    func cancelCurrentSubjectMaskDetection() {
        subjectMaskWorkItem?.cancel()
        subjectMaskWorkItem = nil
        subjectMaskDetectionID = UUID()
        isDetectingSubjectMask = false
    }
}
