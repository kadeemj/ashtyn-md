import Foundation
import Observation

/// Shared, observable AI status surfaced in the editor status bar.
@MainActor
@Observable
final class AICompletionStatus {
    static let shared = AICompletionStatus()
    var isStreaming = false
    /// Nonmodal failure message; offline completion keeps working regardless.
    var lastError: String?
}

/// Orchestrates one editor's AI completions: triggering, streaming, ghost
/// text, cancellation, and acceptance. Owned by the editor coordinator.
@MainActor
final class AICompletionController {
    /// Pushes ghost-text changes to the text view.
    var onGhostTextChange: ((String?) -> Void)?

    private(set) var ghostText: String?
    private var streamTask: Task<Void, Never>?
    private var autoTriggerTask: Task<Void, Never>?
    private var settings: AISettings { .shared }
    /// Injectable for tests; defaults to the settings-configured provider.
    var providerFactory: @MainActor () -> AICompletionProvider? = { AISettings.shared.makeProvider() }

    static let automaticDelay: Duration = .milliseconds(800)

    // MARK: - Triggers

    /// Manual request (⌃⌥Space): runs immediately.
    func requestManually(_ context: @escaping @MainActor () -> AICompletionRequest?) {
        cancelStream(clearGhost: true)
        start(trigger: .manual, context: context)
    }

    /// Called on every edit. Cancels in-flight work; when automatic inline
    /// completion is enabled, arms the 800 ms inactivity trigger.
    /// `isEligible` re-checks selection/composition state at fire time.
    func noteEdit(
        isEligible: @escaping @MainActor () -> Bool,
        context: @escaping @MainActor () -> AICompletionRequest?
    ) {
        cancelStream(clearGhost: true)
        autoTriggerTask?.cancel()
        guard settings.automaticCompletionEnabled,
              let provider = settings.selectedProvider,
              settings.hasConsent(for: provider) else { return }
        autoTriggerTask = Task { [weak self] in
            try? await Task.sleep(for: AICompletionController.automaticDelay)
            guard !Task.isCancelled, let self else { return }
            guard isEligible() else { return }
            self.start(trigger: .automatic, context: context)
        }
    }

    /// Any cursor movement, tab change, or provider change cancels the
    /// stale request and drops the ghost text.
    func cancelAll() {
        autoTriggerTask?.cancel()
        cancelStream(clearGhost: true)
    }

    /// Pure cursor movement: kill the stale stream and ghost, but leave an
    /// armed automatic trigger alone (edits re-arm it themselves, and
    /// eligibility is re-checked when it fires).
    func noteCursorMovement() {
        cancelStream(clearGhost: true)
    }

    /// Tab: hand the suggestion to the caller (inserted as one undoable edit).
    func acceptGhostText() -> String? {
        guard let text = ghostText, !text.isEmpty else { return nil }
        setGhostText(nil)
        cancelStream(clearGhost: false)
        return text
    }

    func dismissGhostText() {
        cancelStream(clearGhost: true)
    }

    // MARK: - Streaming

    private func start(
        trigger: AICompletionRequest.Trigger,
        context: @escaping @MainActor () -> AICompletionRequest?
    ) {
        guard let provider = providerFactory() else {
            AICompletionStatus.shared.lastError =
                "AI completion isn’t configured. Choose a provider in Settings."
            return
        }
        guard let request = context() else { return }

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            AICompletionStatus.shared.isStreaming = true
            AICompletionStatus.shared.lastError = nil
            defer { AICompletionStatus.shared.isStreaming = false }
            do {
                var received = ""
                for try await event in provider.complete(request) {
                    guard !Task.isCancelled, let self else { return }
                    switch event {
                    case .textDelta(let delta):
                        received += delta
                        self.setGhostText(received.isEmpty ? nil : received)
                    case .completed:
                        break
                    }
                }
            } catch is CancellationError {
                // Superseded or dismissed; nothing to report.
            } catch {
                guard !Task.isCancelled else { return }
                self?.setGhostText(nil)
                AICompletionStatus.shared.lastError = error.localizedDescription
            }
        }
    }

    private func cancelStream(clearGhost: Bool) {
        streamTask?.cancel()
        streamTask = nil
        if clearGhost {
            setGhostText(nil)
        }
    }

    private func setGhostText(_ text: String?) {
        ghostText = text
        onGhostTextChange?(text)
    }
}
