//
//  ClaudeJSONLParser.swift
//  boringNotch
//
//  Created by Alban on 2026-08-04.
//

import Foundation

/// Parses individual lines of a Claude Code session `.jsonl` transcript.
///
/// Robustness note: the file being watched can be mid-write, so its last line is frequently
/// truncated. Every entry point here returns `nil` on any decoding failure instead of throwing,
/// so callers can simply skip a bad line rather than crash or poison the scan.
enum ClaudeJSONLParser {
    struct LineTokens {
        let inputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        let estimatedOutputTokens: Int
    }

    struct ParsedLine {
        let timestamp: Date?
        let tokens: LineTokens?
    }

    static func parseLine(_ rawLine: String) -> ParsedLine? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let timestamp = (json["timestamp"] as? String).flatMap(parseTimestamp)

        guard (json["type"] as? String) == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else {
            return ParsedLine(timestamp: timestamp, tokens: nil)
        }

        let tokens = LineTokens(
            inputTokens: intValue(usage["input_tokens"]),
            cacheReadTokens: intValue(usage["cache_read_input_tokens"]),
            cacheCreationTokens: intValue(usage["cache_creation_input_tokens"]),
            // Note: usage["output_tokens"] is intentionally ignored — Claude Code writes a
            // placeholder there (often 1-2), never the real count.
            estimatedOutputTokens: estimateOutputTokens(from: message["content"])
        )

        return ParsedLine(timestamp: timestamp, tokens: tokens)
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    /// ~1 token ≈ 4 characters, applied to the generated text (and tool-call payloads, which
    /// are also model output). This is a rough estimate, not a real tokenizer count.
    private static func estimateOutputTokens(from content: Any?) -> Int {
        var chars = 0

        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    chars += (block["text"] as? String)?.count ?? 0
                case "tool_use":
                    chars += (block["name"] as? String)?.count ?? 0
                    if let input = block["input"],
                       JSONSerialization.isValidJSONObject(input),
                       let inputData = try? JSONSerialization.data(withJSONObject: input),
                       let inputString = String(data: inputData, encoding: .utf8) {
                        chars += inputString.count
                    }
                default:
                    break
                }
            }
        } else if let text = content as? String {
            chars += text.count
        }

        return chars / 4
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseTimestamp(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
