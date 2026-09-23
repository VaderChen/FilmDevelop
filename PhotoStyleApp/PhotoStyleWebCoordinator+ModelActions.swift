import Foundation

extension PhotoStyleWebCoordinator {
    func updateSavingStep(_ step: String) {
        savingStep = step
        sendState(includeImages: false)
    }

    func finishSavingImage(message: String) {
        isSavingImage = false
        savingStep = ""
        sendState(includeImages: false)
        sendToast(message)
    }

    func downloadPreset(_ payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let preset = AIModelStore.presets.first(where: { $0.id == id }) else {
            return
        }
        aiModelStore.download(preset)
    }

    func deletePreset(_ payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let preset = AIModelStore.presets.first(where: { $0.id == id }) else {
            return
        }
        aiModelStore.delete(preset)
    }
}
