import Foundation
import Observation

/// Only the composer observes keystrokes. Disk writes are coalesced after a pause,
/// with synchronous flushes at lifecycle boundaries and before leaving the chat.
@MainActor
@Observable
final class AIChatDraft {
    struct Value: Equatable {
        let text: String
        let requestsImage: Bool
    }

    var text: String
    var requestsImage: Bool

    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var saved: Value
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var save: ((Value) throws -> Void)?
    @ObservationIgnored private var reportError: ((Error) -> Void)?

    init(text: String, requestsImage: Bool, storedText: String? = nil,
         delay: Duration = .milliseconds(450)) {
        self.text = text
        self.requestsImage = requestsImage
        self.saved = Value(text: storedText ?? text, requestsImage: requestsImage)
        self.delay = delay
    }

    var value: Value { Value(text: text, requestsImage: requestsImage) }

    func activate(save: @escaping (Value) throws -> Void, onError: @escaping (Error) -> Void) {
        self.save = save
        self.reportError = onError
        flush()
    }

    func scheduleSave() {
        cancelPendingSave()
        guard save != nil, value != saved else { return }
        let expectedGeneration = generation
        let delay = delay
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self, !Task.isCancelled, generation == expectedGeneration else { return }
            // Do not cancel the currently executing task inside flush(): the
            // persistence revision check also checks task cancellation.
            pendingSave = nil
            flush()
        }
    }

    func cancelPendingSave() {
        generation += 1
        pendingSave?.cancel()
        pendingSave = nil
    }

    func flush() {
        cancelPendingSave()
        guard let save, value != saved else { return }
        let snapshot = value
        do {
            try save(snapshot)
            saved = snapshot
        } catch { reportError?(error) }
    }

    /// Sending or saving a reply may persist the draft in the message transaction.
    /// A queued older draft must never put the sent text back into the composer.
    func acknowledgeSaved(_ snapshot: Value) {
        cancelPendingSave()
        saved = snapshot
    }

    func deactivate() {
        flush()
        save = nil
        reportError = nil
    }
}
