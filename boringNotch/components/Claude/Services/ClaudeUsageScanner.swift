//
//  ClaudeUsageScanner.swift
//  boringNotch
//
//  Created by Alban on 2026-08-04.
//

import Defaults
import Foundation

/// Walks `~/.claude/projects/<encoded-project>/<session>.jsonl`, incrementally parsing only the
/// bytes appended since the last scan, and produces the data the UI needs: the list of currently
/// active sessions and the all-time / today token totals.
actor ClaudeUsageScanner {
    struct ScanResult {
        let sessions: [ClaudeSessionInfo]
        let allTimeTotal: ClaudeTokenUsage
        let todayTotal: Int
        /// Tokens consumed in the rolling window ending now — mirrors the cadence Claude Code
        /// itself resets its Pro/Max session limit on. There is no local, network-free way to
        /// read the *actual* account quota, so this is paired with a user-configured limit as
        /// a local estimate (see `claudeSessionTokenLimit` in Settings).
        let limitWindowTotal: Int
        let projectsDirectoryExists: Bool
    }

    /// Matches the cadence of Claude's own Pro/Max "5-hour session" usage limit.
    static let limitWindowHours = 5

    private let projectsRoot: URL
    private let store: ClaudeUsageStore

    init(projectsRoot: URL, store: ClaudeUsageStore = .shared) {
        self.projectsRoot = projectsRoot
        self.store = store
    }

    func scan() -> ScanResult {
        let fm = FileManager.default
        let threshold = Defaults[.claudeActiveSessionThresholdSeconds]

        guard fm.fileExists(atPath: projectsRoot.path),
              let projectDirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            // Claude Code may never have run, or the directory may be transiently unreadable.
            // The cumulative total from prior scans is still meaningful, so keep reporting it.
            let states = store.allStates()
            return ScanResult(
                sessions: [],
                allTimeTotal: Self.sumAllTime(states),
                todayTotal: Self.sumToday(states),
                limitWindowTotal: Self.sumWindow(states, hours: Self.limitWindowHours),
                projectsDirectoryExists: fm.fileExists(atPath: projectsRoot.path)
            )
        }

        var sessions: [ClaudeSessionInfo] = []
        var updates: [String: ClaudeSessionFileState] = [:]

        for projectDir in projectDirs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let attributes = try? fm.attributesOfItem(atPath: file.path),
                      let modificationDate = attributes[.modificationDate] as? Date,
                      let fileSize = (attributes[.size] as? NSNumber)?.uint64Value
                else { continue }

                let key = file.path
                let previousState = store.state(for: key)
                var state = previousState ?? ClaudeSessionFileState(projectFolderName: projectDir.lastPathComponent)

                if fileSize < state.byteOffsetProcessed {
                    // File shrank or was rotated/rewritten — the cached offset no longer applies.
                    state = ClaudeSessionFileState(projectFolderName: projectDir.lastPathComponent)
                }

                if fileSize > state.byteOffsetProcessed, let handle = try? FileHandle(forReadingFrom: file) {
                    defer { try? handle.close() }
                    try? handle.seek(toOffset: state.byteOffsetProcessed)
                    let newData = handle.readDataToEndOfFile()
                    if !newData.isEmpty {
                        applyNewData(newData, into: &state)
                    }
                }

                if state != previousState {
                    updates[key] = state
                }

                let isActive = Date().timeIntervalSince(modificationDate) <= threshold
                if isActive, let first = state.firstTimestamp, let last = state.lastTimestamp {
                    sessions.append(
                        ClaudeSessionInfo(
                            id: key,
                            sessionId: file.deletingPathExtension().lastPathComponent,
                            projectName: Self.projectDisplayName(from: projectDir.lastPathComponent),
                            projectPath: Self.decodeProjectPath(projectDir.lastPathComponent),
                            startedAt: first,
                            lastActivityAt: last,
                            usage: state.usage
                        )
                    )
                }
            }
        }

        if !updates.isEmpty {
            store.update(updates)
        }

        let states = store.allStates()
        return ScanResult(
            sessions: sessions.sorted { $0.lastActivityAt > $1.lastActivityAt },
            allTimeTotal: Self.sumAllTime(states),
            todayTotal: Self.sumToday(states),
            limitWindowTotal: Self.sumWindow(states, hours: Self.limitWindowHours),
            projectsDirectoryExists: true
        )
    }

    /// Parses only fully newline-terminated lines from `data`, appends their contribution to
    /// `state`, and advances `byteOffsetProcessed` by exactly the bytes consumed — leaving any
    /// trailing partial line (an in-progress write) untouched for the next scan.
    private func applyNewData(_ data: Data, into state: inout ClaudeSessionFileState) {
        guard let lastNewline = lastNewlineIndex(in: data) else { return }
        let consumed = data[data.startIndex...lastNewline]
        guard let text = String(data: consumed, encoding: .utf8) else { return }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let parsed = ClaudeJSONLParser.parseLine(String(line)) else { continue }
            state.linesProcessed += 1

            if let timestamp = parsed.timestamp {
                if state.firstTimestamp == nil { state.firstTimestamp = timestamp }
                if state.lastTimestamp == nil || timestamp > state.lastTimestamp! {
                    state.lastTimestamp = timestamp
                }
            }

            if let tokens = parsed.tokens {
                let usage = ClaudeTokenUsage(
                    inputTokens: tokens.inputTokens,
                    cacheReadTokens: tokens.cacheReadTokens,
                    cacheCreationTokens: tokens.cacheCreationTokens,
                    estimatedOutputTokens: tokens.estimatedOutputTokens
                )
                state.usage.add(usage)

                let hourKey = Self.hourKeyFormatter.string(from: parsed.timestamp ?? Date())
                state.hourlyTotals[hourKey, default: 0] += usage.billableTotal
            }
        }

        state.byteOffsetProcessed += UInt64(consumed.count)
    }

    private func lastNewlineIndex(in data: Data) -> Data.Index? {
        var index = data.endIndex
        while index > data.startIndex {
            index = data.index(before: index)
            if data[index] == 0x0A { return index }
        }
        return nil
    }

    private static func sumAllTime(_ states: [String: ClaudeSessionFileState]) -> ClaudeTokenUsage {
        states.values.reduce(into: ClaudeTokenUsage()) { partial, state in partial.add(state.usage) }
    }

    private static func sumToday(_ states: [String: ClaudeSessionFileState]) -> Int {
        let todayPrefix = dayPrefixFormatter.string(from: Date())
        return states.values.reduce(0) { total, state in
            total + state.hourlyTotals.reduce(0) { $1.key.hasPrefix(todayPrefix) ? $0 + $1.value : $0 }
        }
    }

    /// Sums the hourly buckets covering [now - hours, now]. Bucket boundaries are wall-clock
    /// hours, so this can over-count by up to ~59 minutes at the edges — an acceptable trade-off
    /// for a local estimate that never has to reparse transcripts.
    private static func sumWindow(_ states: [String: ClaudeSessionFileState], hours: Int) -> Int {
        let now = Date()
        let bucketKeys = Set((0..<hours).map { offset in
            hourKeyFormatter.string(from: now.addingTimeInterval(-Double(offset) * 3600))
        })
        return states.values.reduce(0) { total, state in
            total + bucketKeys.reduce(0) { $0 + (state.hourlyTotals[$1] ?? 0) }
        }
    }

    private static let hourKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let dayPrefixFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Claude Code encodes the working directory by replacing "/" with "-", which is lossy for
    /// directory names that themselves contain dashes. Good enough for display purposes.
    static func projectDisplayName(from folderName: String) -> String {
        let cleaned = folderName.hasPrefix("-") ? String(folderName.dropFirst()) : folderName
        let components = cleaned.split(separator: "-")
        return components.last.map(String.init) ?? folderName
    }

    static func decodeProjectPath(_ folderName: String) -> String {
        let cleaned = folderName.hasPrefix("-") ? String(folderName.dropFirst()) : folderName
        return "/" + cleaned.replacingOccurrences(of: "-", with: "/")
    }
}
