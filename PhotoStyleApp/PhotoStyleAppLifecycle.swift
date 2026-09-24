import AppKit

/// NSApplication must keep its run loop alive until native GPU work has drained.
/// Swift singletons are not released before ggml's C++ device destructors run.
@MainActor
final class PhotoStyleApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: PhotoStyleWebCoordinator?
    private var terminationTask: Task<Void, Never>?
    private var terminationReady = false

    /// terminateLater runs a nested event loop. Enter it outside a Swift task or
    /// main-queue callback so asynchronous saving and GPU shutdown can still run.
    static func terminateAfterUpdate() {
        RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor in
            await coordinator?.prepareForTermination()
            await PhotoStyleLLMRuntime.shared.shutdown()
            terminationReady = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension PhotoStyleWebCoordinator {
    @MainActor
    func prepareForTermination() async {
        isTerminating = true
        cancelAdjustmentPreview()
        let activeRepair = repairTask
        activeRepair?.cancel()
        await activeRepair?.value
        updateActionAvailability()
        mcpServer.stop()
        // Do not use the UI's cancel guard: it intentionally disables cancellation
        // during the last preview, but quitting must still drain that task.
        let activeInference = inferenceTask
        isCancellingComputation = activeInference != nil
        activeInference?.cancel()
        await activeInference?.value
        // 結束前等候已接受的匯出與預覽；避免終止 GPU 工作或截斷檔案寫入。
        // MCP 取消仍由原有取消處理器傳遞；使用者要求的正常匯出會完成。
        let activeExport = exportWorker
        _ = try? await activeExport?.value
        await waitForPreviewRender()
        // 滑鼠懸停底片的預覽也共用此佇列，但不計入 isRenderingPreview。
        await withCheckedContinuation { continuation in
            previewRenderQueue.async { continuation.resume() }
        }
        persistCurrentPhotoEdits()
        await waitForSourcePersistence()
    }
}
