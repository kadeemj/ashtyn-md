import Foundation

/// Feature policy derived from a document's on-disk byte size.
///
/// The Open Anyway override deliberately maps an oversized read-only document
/// to safeguarded large-file mode rather than restoring preview or AI.
struct DocumentCapabilities: Equatable, Sendable {
    enum Tier: Equatable, Sendable {
        case full
        case large
        case readOnlyLarge
    }

    enum PreviewBehavior: Equatable, Sendable {
        case live
        case manual
        case disabled
    }

    static let fullFeatureByteLimit: Int64 = 2 * 1024 * 1024
    static let readOnlyByteLimit: Int64 = 10 * 1024 * 1024

    let byteCount: Int64
    let tier: Tier

    init(byteCount: Int64, openedAnyway: Bool = false) {
        self.byteCount = max(0, byteCount)
        if self.byteCount <= Self.fullFeatureByteLimit {
            tier = .full
        } else if self.byteCount <= Self.readOnlyByteLimit || openedAnyway {
            tier = .large
        } else {
            tier = .readOnlyLarge
        }
    }

    var isEditable: Bool {
        tier != .readOnlyLarge
    }

    var allowsAICompletion: Bool {
        tier == .full
    }

    var previewBehavior: PreviewBehavior {
        switch tier {
        case .full:
            .live
        case .large:
            .manual
        case .readOnlyLarge:
            .disabled
        }
    }

    func openingAnyway() -> DocumentCapabilities {
        DocumentCapabilities(byteCount: byteCount, openedAnyway: true)
    }
}
