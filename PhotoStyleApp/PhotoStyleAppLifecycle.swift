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
        updateActionAvailability()
        mcpServer.stop()
        // Do not use the UI's cancel guard: it intentionally disables cancellation
        // during the last preview, but quitting must still drain that task.
        let activeInference = inferenceTask
        isCancellingComputation = activeInference != nil
        activeInference?.cancel()
        await activeInference?.value
        persistCurrentPhotoEdits()
        await waitForSourcePersistence()
    }
}
