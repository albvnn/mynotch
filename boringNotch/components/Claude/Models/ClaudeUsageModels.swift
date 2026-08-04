//
//  ClaudeUsageModels.swift
//  boringNotch
//
//  Created by Alban on 2026-08-04.
//

import Foundation

/// Token usage for a Claude Code session (or a slice of one).
/// `inputTokens`, `cacheReadTokens` and `cacheCreationTokens` come straight from the JSONL
/// `message.usage` block and are reliable. `estimatedOutputTokens` is NOT: Claude Code never
/// persists the real output token count, so it is derived from generated text length (~4 chars/token).
struct ClaudeTokenUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var estimatedOutputTokens: Int = 0

    /// Every token the API reported for these turns, cache reads included. Reads are billed at a
    /// fraction of fresh-token price, and get re-reported (and thus re-summed) on every turn of a
    /// long session — so across a whole multi-thousand-turn transcript this number balloons into
    /// the billions and stops meaning anything intuitive. Kept around for transparency, not as
    /// the headline "tokens used" figure.
    var total: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens + estimatedOutputTokens
    }

    /// Fresh input + newly-written cache + estimated output — excludes cache *reads*. This is
    /// what drives context growth and cost, and is what the app shows as "tokens used".
    var billableTotal: Int {
        inputTokens + cacheCreationTokens + estimatedOutputTokens
    }

    static func + (lhs: ClaudeTokenUsage, rhs: ClaudeTokenUsage) -> ClaudeTokenUsage {
        ClaudeTokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            estimatedOutputTokens: lhs.estimatedOutputTokens + rhs.estimatedOutputTokens
        )
    }

    mutating func add(_ other: ClaudeTokenUsage) {
        self = self + other
    }
}

/// A currently-active Claude Code session, ready for display in the notch.
struct ClaudeSessionInfo: Identifiable, Equatable {
    /// Absolute path of the backing .jsonl file — stable and unique.
    let id: String
    let sessionId: String
    let projectName: String
    let projectPath: String
    let startedAt: Date
    let lastActivityAt: Date
    let usage: ClaudeTokenUsage

    var duration: TimeInterval {
        max(0, lastActivityAt.timeIntervalSince(startedAt))
    }
}

/// Persisted, per-session-file scan state so we never re-parse lines we've already counted.
struct ClaudeSessionFileState: Codable, Equatable {
    /// Byte offset up to which the file has been fully parsed (always ends on a line boundary).
    var byteOffsetProcessed: UInt64 = 0
    var linesProcessed: Int = 0
    var usage: ClaudeTokenUsage = .init()
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    /// "yyyy-MM-dd-HH" (local time) -> tokens attributed to that hour, so "today" and "rolling
    /// N-hour window" totals (e.g. the 5h Claude session limit) never require a full reparse.
    var hourlyTotals: [String: Int] = [:]
    var projectFolderName: String
}
