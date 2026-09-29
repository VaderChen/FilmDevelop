import AppKit
import CoreImage
import CryptoKit

enum PhotoRecipeOperation: String {
    case duplicate = "複製照片"
    case copy = "複製調整參數"
    case apply = "套用調整參數"
    case reset = "恢復預設值"
}

final class PhotoEditPreview: NSObject {
    let output: PhotoImage
    let payload: [String: String]
    let mask: CIImage?
    init(output: PhotoImage, payload: [String: String], mask: CIImage?) {
        self.output = output; self.payload = payload; self.mask = mask
    }
    var cost: Int {
        let pixels = output.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        let maskBytes = mask.map { Int($0.extent.width * $0.extent.height) * 16 } ?? 0
        return pixels + maskBytes + payload.values.reduce(0) { $0 + $1.utf8.count }
    }
}

extension PhotoStyleWebCoordinator {
    func addThumbnailRecipeMenus(to menu: NSMenu, ids: [String]) {
        addPhotoRecipeMenus(to: menu, urls: ids.compactMap { photoDirectoryStore.url(for: $0) },
                            singlePhoto: ids.count == 1)
    }

    func addPhotoRecipeMenus(to menu: NSMenu, urls: [URL], singlePhoto: Bool) {
        // 使用明確的可用狀態，避免 AppKit 因存在 action 而自動啟用停用項目。
        menu.autoenablesItems = false
        let operations: [PhotoRecipeOperation] = singlePhoto ? [.copy, .apply, .duplicate] : [.apply]
        for operation in operations {
            if operation == .duplicate { menu.addItem(.separator()) }
            let item = NSMenuItem(title: PhotoL10n.text(operation.rawValue),
                                 action: #selector(performThumbnailRecipe(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = canImport && !isDetectingSubjectMask && photoRecipeTask == nil
                && !urls.isEmpty && (operation != .apply || copiedPhotoRecipe != nil)
            item.representedObject = ["operation": operation.rawValue, "urls": urls] as [String: Any]
            menu.addItem(item)
        }
        if !singlePhoto { menu.addItem(.separator()) }
    }

    @objc func performThumbnailRecipe(_ item: NSMenuItem) {
        guard canImport, !isDetectingSubjectMask, photoRecipeTask == nil,
              let payload = item.representedObject as? [String: Any],
              let name = payload["operation"] as? String, let operation = PhotoRecipeOperation(rawValue: name),
              let urls = payload["urls"] as? [URL], !urls.isEmpty else { return }
        photoRecipeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.performPhotoRecipeOperation(operation, urls: urls)
            self.photoRecipeTask = nil
        }
    }

    var currentPhotoRecipe: PhotoEditRecord {
        PhotoEditRecord(style: selectedStyle, adjustments: adjustmentStore.adjustments,
                        customFilmID: selectedCustomFilmID, customFilmBaseAdjustment: customFilmBaseAdjustment,
                        repairPatches: repairPatches, manualAdjustments: manualAdjustments)
    }

    /// 以點選的檔案取得配方，不依賴目前編輯器是否已切換到該照片。
    func photoRecipe(at url: URL) async throws -> (identifier: String, record: PhotoEditRecord) {
        let identifier = try await Task.detached(priority: .userInitiated) {
            Self.sourceImageIdentifier(for: try Data(contentsOf: url, options: .mappedIfSafe))
        }.value
        if url.standardizedFileURL == sourceFileURL?.standardizedFileURL,
           identifier == currentSourceIdentifier { return (identifier, currentPhotoRecipe) }
        let loaded = await photoEditStore.load(identifier: identifier, url: url, maskSize: .zero)
        let record = photoEditStore.shouldRestoreEdits(loaded.record, at: url) ? loaded.record : nil
        return (identifier, record ?? PhotoEditRecord(style: .original, adjustments: [:]))
    }

    @MainActor
    @discardableResult
    func performPhotoRecipeOperation(_ operation: PhotoRecipeOperation, urls: [URL]) async -> [URL] {
        guard canImport, !isDetectingSubjectMask, !urls.isEmpty else { return [] }
        let recipe = copiedPhotoRecipe
        guard operation != .apply || recipe != nil else { return [] }
        commitAdjustmentPreview()
        isSavingImage = true
        let progress = PhotoBatchExportProgress(total: urls.count, title: operation.rawValue)
        // 複製參數只顯示完成提示；仍保留作業鎖定，避免讀取期間切換照片。
        batchExportProgress = operation == .copy ? nil : progress
        let batchID = progress.id
        let startedAt = ProcessInfo.processInfo.systemUptime
        sendState(includeImages: false)
        await waitForPreviewRender()
        persistCurrentPhotoEdits()
        var completed: [URL] = []
        var failures: [String] = []
        var currentChanged = false
        let directory = photoDirectoryStore.directoryURL
        let directoryAccess = directory?.startAccessingSecurityScopedResource() ?? false
        defer {
            if directoryAccess { directory?.stopAccessingSecurityScopedResource() }
            batchExportProgress = nil
            isSavingImage = false
            savingStep = ""
            if currentChanged, !isTerminating { applySelectedStyle() }
            sendPhotoDirectoryState()
            sendState(includeImages: currentChanged, externalEdit: currentChanged)
        }
        for (index, url) in urls.enumerated() {
            if isTerminating || Task.isCancelled { break }
            batchExportProgress?.index = index
            batchExportProgress?.filename = url.lastPathComponent
            batchExportProgress?.stage = operation.rawValue
            batchExportProgress?.fraction = 0
            sendState(includeImages: false)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var createdCopy: URL?
            do {
                let source = try await photoRecipe(at: url)
                if isTerminating || Task.isCancelled { break }
                updateBatchExportProgress(id: batchID, index: index, stage: operation.rawValue, fraction: 0.4)
                switch operation {
                case .copy:
                    var snapshot = source.record
                    snapshot.repairPatches = nil
                    copiedPhotoRecipe = snapshot
                    completed.append(url)
                case .duplicate:
                    let destination = try await Task.detached(priority: .userInitiated) {
                        let folder = url.deletingLastPathComponent()
                        let base = url.deletingPathExtension().lastPathComponent + " copy"
                        let ext = url.pathExtension
                        var number = 1
                        while true {
                            let stem = number == 1 ? base : "\(base) (\(number))"
                            let target = folder.appendingPathComponent(stem).appendingPathExtension(ext)
                            do { try FileManager.default.copyItem(at: url, to: target); return target }
                            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                                number += 1
                            }
                        }
                    }.value
                    createdCopy = destination
                    guard let key = PhotoEditStore.key(identifier: source.identifier, url: destination) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try await photoEditStore.saveConfirmed(source.record, for: key)
                    photoEditStore.markEdited(at: destination)
                    completed.append(destination)
                case .apply, .reset:
                    var applied = operation == .reset
                        ? PhotoEditRecord(style: .original, adjustments: [:],
                                          manualAdjustments: PhotoManualAdjustments(hasCompleteHistory: true))
                        : recipe!
                    if operation == .apply { applied.repairPatches = source.record.repairPatches }
                    guard let key = PhotoEditStore.key(identifier: source.identifier, url: url) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try await photoEditStore.saveConfirmed(applied, for: key)
                    if operation == .reset { photoEditStore.clearEdited(at: url) }
                    else { photoEditStore.markEdited(at: url) }
                    if key == currentPhotoEditKey {
                        restoreAppliedRecipe(applied)
                        if operation == .reset {
                            resetEditHistory()
                            photoEditStore.clearEdited(at: url)
                        }
                        currentChanged = true
                    }
                    completed.append(url)
                }
            } catch {
                var message = "\(url.lastPathComponent)：\(error.localizedDescription)"
                if let createdCopy {
                    do { try FileManager.default.removeItem(at: createdCopy) }
                    catch { message += "\n\(createdCopy.lastPathComponent)：\(error.localizedDescription)" }
                }
                failures.append(message)
            }
            batchExportProgress?.succeeded = completed.count
            batchExportProgress?.failed = failures.count
            updateBatchExportProgress(id: batchID, index: index, stage: operation.rawValue, fraction: 1)
        }
        await photoEditStore.flush()
        // 只補足對話框的最短顯示時間，不逐張延遲，也不拖慢較長的批次作業。
        if (operation == .apply || operation == .reset), !isTerminating, !Task.isCancelled {
            let remaining = 0.65 - (ProcessInfo.processInfo.systemUptime - startedAt)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        if operation == .duplicate, let destination = completed.last, !isTerminating {
            photoDirectoryStore.selectDirectory(destination.deletingLastPathComponent(), preferredPhotoURL: destination)
            batchExportProgress = nil
            isSavingImage = false
            let opened: Bool = await withCheckedContinuation { continuation in
                loadPickedImage(from: destination) { result in
                    if case .success = result { continuation.resume(returning: true) }
                    else { continuation.resume(returning: false) }
                }
            }
            if opened, !isTerminating {
                callJavaScript(function: "handleFocusDirectoryPhoto", payload: [
                    "path": destination.deletingLastPathComponent().path, "name": destination.lastPathComponent
                ])
            }
        }
        if !isTerminating {
            sendToast(PhotoL10n.text(operation.rawValue) + "：" + PhotoL10n.text("成功：\(completed.count) 張／失敗：\(failures.count) 張")
                      + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n")))
        }
        return completed
    }

    func restoreAppliedRecipe(_ record: PhotoEditRecord) {
        guard let style = PhotoStyle(rawValue: record.selectedStyle) else { return }
        clearPreviewRender()
        photoPreviewCache.removeAllObjects()
        sourceSubjectMask = nil
        subjectMaskAttemptedGeneration = nil
        isRestoringPhotoEdits = true
        selectedStyle = style
        let custom = customFilmStore.film(id: record.customFilmID)
        selectedCustomFilmID = custom?.baseStyle == style.rawValue ? custom?.id : nil
        customFilmBaseAdjustment = selectedCustomFilmID == nil ? nil : record.customFilmBaseAdjustment
        manualAdjustments = record.manualAdjustments ?? PhotoManualAdjustments()
        repairPatches = record.repairPatches ?? []
        adjustmentStore.restorePhotoAdjustments(record.adjustments)
        UserDefaults.standard.set(style.rawValue, forKey: Self.selectedStyleDefaultsKey)
        isRestoringPhotoEdits = false
        recordEditHistory()
    }

    func persistCurrentPhotoEdits() {
        guard !isRestoringPhotoEdits, sourceImage != nil, let key = currentPhotoEditKey else { return }
        photoEditStore.save(currentPhotoRecipe, mask: sourceSubjectMask, for: key)
    }

    func previewCacheKey(for request: PhotoStyleRenderRequest) -> String? {
        guard let key = currentPhotoEditKey else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(request.adjustment) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(request.adjustment.filmEffects.modernFilmExposureEnabled):\(request.adjustment.filmEffects.highlightProtectionEnabled):\(repairRevision):\(key):\(request.style.rawValue):\(request.image.size):\(request.image.requiresRAWDisplayMapping):\(digest)"
    }
}


extension PhotoStyleWebCoordinator {
    var currentEditSnapshot: EditSnapshot {
        EditSnapshot(manualAdjustments: manualAdjustments, style: selectedStyle, adjustments: adjustmentStore.adjustments, customFilmID: selectedCustomFilmID,
                     customFilmBaseAdjustment: customFilmBaseAdjustment, repairPatches: repairPatches)
    }

    func resetEditHistory() {
        editUndoStack.removeAll()
        editRedoStack.removeAll()
        lastEditInteractionID = nil
        lastEditSnapshot = currentEditSnapshot
    }

    func recordEditHistory() {
        guard sourceImage != nil, !isRestoringPhotoEdits, !isRestoringEditHistory else { return }
        let current = currentEditSnapshot
        guard let previous = lastEditSnapshot else { lastEditSnapshot = current; return }
        guard current != previous else { return }
        if let url = sourceFileURL, photoEditStore.markEdited(at: url) { sendPhotoDirectoryState() }
        // A slider gesture is one edit, regardless of how many preview frames it sends.
        let interaction = adjustmentPreviewInteractionID ?? editHistoryBatchID
        if interaction == nil || interaction != lastEditInteractionID {
            editUndoStack.append(previous)
            if editUndoStack.count > 100 { editUndoStack.removeFirst() }
        }
        editRedoStack.removeAll()
        lastEditInteractionID = interaction
        lastEditSnapshot = current
    }

    func restoreEditHistory(redo: Bool) {
        guard sourceImage != nil, !isLoadingImage, !isComputing, !isSavingImage,
              !isTerminating, !isDetectingSubjectMask, !isRepairingImage else { return }
        let target: EditSnapshot
        if redo {
            guard let next = editRedoStack.popLast() else { return }
            target = next
            editUndoStack.append(currentEditSnapshot)
        } else {
            guard let previous = editUndoStack.popLast() else { return }
            target = previous
            editRedoStack.append(currentEditSnapshot)
        }
        cancelAdjustmentPreview()
        isRestoringEditHistory = true
        if repairPatches != target.repairPatches {
            sourceSubjectMask = nil; subjectMaskAttemptedGeneration = nil
            photoPreviewCache.removeAllObjects()
        }
        manualAdjustments = target.manualAdjustments
        repairPatches = target.repairPatches
        selectedStyle = target.style
        selectedCustomFilmID = target.customFilmID
        customFilmBaseAdjustment = target.customFilmBaseAdjustment
        UserDefaults.standard.set(target.style.rawValue, forKey: Self.selectedStyleDefaultsKey)
        adjustmentStore.restorePhotoAdjustments(Dictionary(uniqueKeysWithValues:
            target.adjustments.map { ($0.key.rawValue, $0.value) }))
        isRestoringEditHistory = false
        lastEditSnapshot = currentEditSnapshot
        lastEditInteractionID = nil
        applySelectedStyle()
        sendState(includeImages: true, externalEdit: true)
    }
}
