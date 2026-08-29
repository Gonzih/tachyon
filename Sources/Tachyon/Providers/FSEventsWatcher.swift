import CoreServices
import Foundation

/// Recursive file watcher over a directory tree.
///
/// Not an actor: `FSEventStreamCreate` needs a stable context pointer and a
/// serial dispatch queue. Confinement contract — every mutable field below is
/// touched only from `queue`.
///
/// `kFSEventStreamCreateFlagFileEvents` is mandatory here: Codex rollout files
/// live three directory levels deep and a plain directory watch never reports
/// them.
final class FSEventsWatcher: @unchecked Sendable {
    private let path: String
    private let latency: CFTimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let queue: DispatchQueue
    private var streamRef: FSEventStreamRef?

    init(path: String, latency: CFTimeInterval = 2.0, onChange: @escaping @Sendable ([String]) -> Void) {
        self.path = path
        self.latency = latency
        self.onChange = onChange
        self.queue = DispatchQueue(label: "dev.gonzih.tachyon.fsevents.\(abs(path.hashValue))")
    }

    func start() {
        queue.async { [self] in
            guard streamRef == nil else { return }
            guard FileManager.default.fileExists(atPath: path) else {
                Log.provider.debug("FSEvents: \(self.path, privacy: .public) missing; not watching")
                return
            }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            // C function pointer: cannot capture, so `self` is recovered from `info`.
            // Unretained is safe because `deinit` tears the stream down first.
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
                watcher.onChange(Array(paths.prefix(count)))
            }

            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else {
                Log.provider.error("FSEvents: failed to create stream for \(self.path, privacy: .public)")
                return
            }

            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                Log.provider.error("FSEvents: failed to start stream for \(self.path, privacy: .public)")
                return
            }
            streamRef = stream
            Log.provider.info("FSEvents: watching \(self.path, privacy: .public)")
        }
    }

    func stop() {
        queue.sync { [self] in
            guard let stream = streamRef else { return }
            streamRef = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    deinit {
        // `queue.sync` from deinit is safe: no other work re-enters this object.
        guard let stream = streamRef else { return }
        streamRef = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
