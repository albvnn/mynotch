//
//  ClaudeProjectsWatcher.swift
//  boringNotch
//
//  Created by Alban on 2026-08-04.
//

import CoreServices
import Foundation

/// Watches `~/.claude` (the parent of `projects/`) for changes using FSEvents, so new session
/// files, new project folders, and writes to existing transcripts are all picked up recursively
/// without polling. FSEvents streams can be created for a path that doesn't exist yet — this is
/// what lets us watch before Claude Code has ever run, and still start receiving events the
/// moment `~/.claude` is created.
final class ClaudeProjectsWatcher {
    private let path: String
    private let latency: TimeInterval
    private var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?

    init(path: String, latency: TimeInterval = 1.0) {
        self.path = path
        self.latency = latency
    }

    /// The callback is supplied here rather than at `init` so callers can safely capture `self`
    /// (e.g. `[weak self]`) after their own initializer has finished running.
    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, clientInfo, _, _, _, _) in
                guard let clientInfo else { return }
                let watcher = Unmanaged<ClaudeProjectsWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
                watcher.onChange?()
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(newStream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
