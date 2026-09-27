import Foundation

/// Bounds heavy image work: visible thumbnails take priority over editor/hover decoding.
/// Reservations include queued thumbnails, so an editor cannot slip between worker batches.
/// An already executing render finishes its current job; no GPU work is interrupted unsafely.
final class PhotoPreviewWorkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var thumbnails = 0
    private var editorActive = false

    final class ThumbnailReservation: @unchecked Sendable {
        private let gate: PhotoPreviewWorkGate
        private var claimed = false
        private var running = false
        private var finished = false
        fileprivate init(_ gate: PhotoPreviewWorkGate) { self.gate = gate }
        deinit { cancel() }

        /// Queued cancellation releases priority immediately. A running decode releases on return.
        func cancel() {
            gate.condition.lock()
            if !running { finishLocked() }
            gate.condition.unlock()
        }
        private func finishLocked() {
            guard !finished else { return }
            finished = true
            gate.thumbnails -= 1
            gate.condition.broadcast()
        }
        func perform<T>(_ body: () throws -> T) rethrows -> T? {
            gate.condition.lock()
            guard !claimed, !finished else { gate.condition.unlock(); return nil }
            claimed = true
            while gate.editorActive && !finished { gate.condition.wait() }
            guard !finished else { gate.condition.unlock(); return nil }
            running = true
            gate.condition.unlock()
            defer {
                gate.condition.lock()
                running = false
                finishLocked()
                gate.condition.unlock()
            }
            return try body()
        }
    }

    func reserveThumbnail() -> ThumbnailReservation {
        condition.lock()
        thumbnails += 1
        condition.unlock()
        return ThumbnailReservation(self)
    }
    /// Call on a worker only, never the main thread. The body must not wait on main-thread work.
    func withEditorWork<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock()
        while thumbnails > 0 || editorActive { condition.wait() }
        editorActive = true
        condition.unlock()
        defer {
            condition.lock()
            editorActive = false
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }
}
