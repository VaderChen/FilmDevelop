import AppKit
import PhotoStyleShared

extension PhotoStyleWebCoordinator {
    var repairRevision: String { repairPatches.map { $0.id.uuidString }.joined(separator: ":") }

    @MainActor func applyRepairBrush(_ payload: [String: Any]) {
        guard let source = sourceImage, !isRepairingImage, !isLoadingImage, !isComputing, !isSavingImage,
              !isMCPMutating, !isRenderingPreview, !isDetectingSubjectMask, !isTerminating,
              payload["photoGeneration"] as? String == photoGeneration.uuidString,
              payload["repairRevision"] as? String == repairRevision else {
            callJavaScript(function: "handleRepairResult", payload: ["success": false])
            return
        }
        guard repairPatches.count < 32, repairPatches.reduce(0, { $0 + $1.imageData.count + $1.maskData.count }) < 32 * 1024 * 1024 else {
            sendToast(PhotoRepairError.tooManyRepairs.localizedDescription)
            callJavaScript(function: "handleRepairResult", payload: ["success": false]); return
        }
        guard let raw = payload["strokes"], JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw), data.count <= 2 * 1024 * 1024,
              let strokes = try? JSONDecoder().decode([PhotoRepairStroke].self, from: data) else {
            sendToast(PhotoRepairError.invalidMask.localizedDescription)
            callJavaScript(function: "handleRepairResult", payload: ["success": false]); return
        }
        let generation = photoGeneration, patches = repairPatches
        let operation = UUID(); repairOperationID = operation
        cancelAdjustmentPreview()
        repairModelProgress = nil; isCancellingRepair = false
        isRepairingImage = true; repairStep = "正在準備本機修復工具…"
        sendState(includeImages: false)
        repairTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let patch = try await PhotoRepairService.shared.repair(source: source, patches: patches, strokes: strokes, downloadProgress: { [weak self] value in
                    DispatchQueue.main.async {
                        guard let self, self.repairOperationID == operation, self.isRepairingImage, !self.isTerminating, !self.isCancellingRepair else { return }
                        self.repairModelProgress = value; self.sendState(includeImages: false)
                    }
                }) { [weak self] step in
                    DispatchQueue.main.async {
                        guard let self, self.repairOperationID == operation, self.isRepairingImage, !self.isTerminating, !self.isCancellingRepair else { return }
                        self.repairStep = step; self.sendState(includeImages: false)
                    }
                }
                try Task.checkCancellation()
                guard self.photoGeneration == generation, self.repairOperationID == operation, !self.isTerminating else { throw CancellationError() }
                self.repairPatches.append(patch)
                self.sourceSubjectMask = nil; self.subjectMaskAttemptedGeneration = nil
                self.photoPreviewCache.removeAllObjects()
                self.recordEditHistory(); self.persistCurrentPhotoEdits()
                self.isRepairingImage = false; self.repairTask = nil
                self.applySelectedStyle()
                self.callJavaScript(function: "handleRepairResult", payload: ["success": true])
            } catch {
                self.isRepairingImage = false; self.repairTask = nil
                if !(error is CancellationError) && !Task.isCancelled { self.sendToast(error.localizedDescription) }
                self.callJavaScript(function: "handleRepairResult", payload: ["success": false])
            }
            self.repairModelProgress = nil; self.isCancellingRepair = false
            self.repairStep = ""; self.sendState(includeImages: true)
        }
    }

    func cancelRepairBrush() {
        guard isRepairingImage, !isCancellingRepair else { return }
        isCancellingRepair = true
        repairTask?.cancel()
        repairStep = "正在取消修復…"
        sendState(includeImages: false)
    }
}
