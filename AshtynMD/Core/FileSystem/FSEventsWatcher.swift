import Foundation
import CoreServices

/// Recursive FSEvents monitor for a library root. Delivers batches of
/// affected paths as an AsyncStream consumed by the indexer.
final class FSEventsWatcher: @unchecked Sendable {
    let events: AsyncStream<[String]>

    private let continuation: AsyncStream<[String]>.Continuation
    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.kadeem.ashtynmd.fsevents", qos: .utility)
    private let rootPath: String

    init(root: URL) {
        rootPath = root.path
        var streamContinuation: AsyncStream<[String]>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { streamContinuation = $0 }
        continuation = streamContinuation
    }

    func start() {
        queue.sync {
            guard streamRef == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
                guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
                    return
                }
                watcher.continuation.yield(Array(paths.prefix(count)))
            }
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [rootPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                )
            ) else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            streamRef = stream
        }
    }

    func stop() {
        queue.sync {
            guard let stream = streamRef else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        continuation.finish()
    }

    deinit {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
