import AppKit

/// Tracks every open DocumentSession across all windows so app-wide events
/// (deactivation, termination, reactivation) reach each document.
@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()

    private var sessions: [UUID: DocumentSession] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SessionRegistry.shared.saveAll(reason: .losingFocus)
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SessionRegistry.shared.checkAllForExternalChanges()
            }
        })
    }

    func register(_ session: DocumentSession) {
        sessions[session.id] = session
    }

    func unregister(_ session: DocumentSession) {
        sessions.removeValue(forKey: session.id)
    }

    func saveAll(reason: DocumentSession.SaveReason) {
        for session in sessions.values {
            Task { await session.save(reason: reason) }
        }
    }

    func checkAllForExternalChanges() {
        for session in sessions.values {
            session.checkForExternalChanges()
        }
    }

    /// Synchronous save of everything dirty; used from applicationShouldTerminate.
    func saveAllBlockingForTermination() {
        for session in sessions.values {
            session.saveBlockingForTermination()
        }
    }
}
