import Combine
import Foundation

/// Menu commands that have to reach a view rather than the model — presenting
/// a sheet, for instance.
///
/// Kept as a relay rather than state on `AppModel` so presentation stays owned
/// by the view. That matters for the eventual per-window split: two windows
/// must not fight over which one shows a sheet.
@MainActor
final class LibraryCommandRequests {
    static let shared = LibraryCommandRequests()

    enum Request: Sendable {
        case moveToFolder
    }

    private let subject = PassthroughSubject<Request, Never>()

    var requests: AnyPublisher<Request, Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ request: Request) {
        subject.send(request)
    }
}
