import AppKit
import CoreImage
import CryptoKit

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
    func persistCurrentPhotoEdits() {
        guard !isRestoringPhotoEdits, sourceImage != nil, let key = currentPhotoEditKey else { return }
        photoEditStore.save(.init(style: selectedStyle, adjustments: adjustmentStore.adjustments, customFilmID: selectedCustomFilmID,
                                  customFilmBaseAdjustment: customFilmBaseAdjustment),
                            mask: sourceSubjectMask, for: key)
    }

    func previewCacheKey(for request: PhotoStyleRenderRequest) -> String? {
        guard let key = currentPhotoEditKey else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(request.adjustment) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(key):\(request.style.rawValue):\(request.image.size):\(request.image.requiresRAWDisplayMapping):\(digest)"
    }
}


extension PhotoStyleWebCoordinator {
    var currentEditSnapshot: EditSnapshot {
        EditSnapshot(style: selectedStyle, adjustments: adjustmentStore.adjustments, customFilmID: selectedCustomFilmID,
                     customFilmBaseAdjustment: customFilmBaseAdjustment)
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
              !isTerminating, !isDetectingSubjectMask else { return }
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
