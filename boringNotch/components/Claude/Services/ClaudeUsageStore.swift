//
//  ClaudeUsageStore.swift
//  boringNotch
//
//  Created by Alban on 2026-08-04.
//

import Foundation

/// Persistent, incremental cache of per-session-file token usage.
///
/// Keyed by absolute file path. Entries are never pruned when a `.jsonl` file disappears, so the
/// "all-time" total keeps counting sessions whose transcripts have since been deleted or rotated —
/// matching the "cumulative total, forever" requirement.
final class ClaudeUsageStore {
    static let shared = ClaudeUsageStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.boringnotch.claude.usageStore")
    private var cache: [String: ClaudeSessionFileState]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var pendingWrite: DispatchWorkItem?

    private init() {
        let fm = FileManager.default
        let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = (support ?? fm.temporaryDirectory)
            .appendingPathComponent("boringNotch", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("usage_cache.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([String: ClaudeSessionFileState].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func state(for path: String) -> ClaudeSessionFileState? {
        queue.sync { cache[path] }
    }

    func allStates() -> [String: ClaudeSessionFileState] {
        queue.sync { cache }
    }

    /// Merges a batch of updated file states and schedules a debounced write to disk.
    func update(_ updates: [String: ClaudeSessionFileState]) {
        guard !updates.isEmpty else { return }
        queue.sync {
            for (path, state) in updates {
                cache[path] = state
            }
        }
        schedulePersist()
    }

    private func schedulePersist() {
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Always invoked on `queue` (via the debounced work item), so touching `cache` directly here is safe.
    private func writeToDisk() {
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
