//
//  ClaudeView.swift
//  boringNotch
//
//  Created by Alban on 2026-08-04.
//

import Defaults
import SwiftUI

struct ClaudeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject private var sessionsVM = ClaudeSessionsViewModel.shared
    @Default(.claudeSessionTokenLimit) var sessionLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if sessionLimit > 0 {
                limitGauge
            }

            if !sessionsVM.projectsDirectoryExists && sessionsVM.activeSessions.isEmpty && sessionsVM.allTimeTotal.total == 0 {
                emptyState
            } else if sessionsVM.activeSessions.isEmpty {
                noActiveSessionsState
            } else {
                sessionList
            }

            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 2))
        )
        .onAppear {
            sessionsVM.refreshOnAppear()
        }
        .task {
            // Keeps session durations and the rolling limit window fresh while the panel is
            // visible, since neither changes purely from filesystem writes (which the FSEvents
            // watcher already handles). Cancelled automatically when the view disappears.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                sessionsVM.rescan()
            }
        }
    }

    // MARK: - Claude limit gauge (self-configured local estimate)

    private var limitGauge: some View {
        let fraction = min(1, Double(sessionsVM.limitWindowTotal) / Double(sessionLimit))
        let percentage = Int((fraction * 100).rounded())

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Claude limit (\(sessionsVM.limitWindowHours)h)")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                Spacer()
                Text("\(percentage)%")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(gaugeColor(for: fraction))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(gaugeColor(for: fraction))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 5)
        }
    }

    private func gaugeColor(for fraction: Double) -> Color {
        switch fraction {
        case 0.9...: return .red
        case 0.7...: return .orange
        default: return .green
        }
    }

    // MARK: - Header (compact summary)

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)

            Text(activeSessionsLabel)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Spacer()

            VStack(alignment: .trailing, spacing: 0) {
                Text(TokenFormatter.compact(sessionsVM.todayTotal))
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text("today")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
    }

    private var activeSessionsLabel: String {
        let count = sessionsVM.activeSessions.count
        return count == 1 ? "1 active session" : "\(count) active sessions"
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .gray)
                .imageScale(.large)
            Text("No Claude Code sessions yet")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noActiveSessionsState: some View {
        VStack(spacing: 4) {
            Image(systemName: "moon.zzz")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .gray)
                .imageScale(.large)
            Text("No active sessions")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session list (expanded view)

    private var sessionList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach(sessionsVM.activeSessions) { session in
                    ClaudeSessionRow(session: session)
                }
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: - Footer (all-time cumulative total)

    private var footer: some View {
        VStack(spacing: 2) {
            Divider().background(Color.white.opacity(0.1))
            HStack {
                Text("All-time total")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                Spacer()
                Text(TokenFormatter.compact(sessionsVM.allTimeTotal.billableTotal) + " tokens")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
            }
            if sessionsVM.allTimeTotal.cacheReadTokens > 0 {
                HStack {
                    Text("+ \(TokenFormatter.compact(sessionsVM.allTimeTotal.cacheReadTokens)) read from cache (~free, excluded above)")
                        .font(.system(size: 9))
                        .foregroundStyle(.gray.opacity(0.6))
                    Spacer()
                }
            }
            HStack {
                Text("~ includes estimated output tokens (not persisted by Claude Code)")
                    .font(.system(size: 9))
                    .foregroundStyle(.gray.opacity(0.8))
                Spacer()
            }
        }
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(session.projectName)
                    .font(.system(.footnote, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text(DurationFormatter.string(from: session.duration))
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }

            HStack {
                Text(session.projectPath)
                    .font(.system(size: 9))
                    .foregroundStyle(.gray.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Text("~\(TokenFormatter.compact(session.usage.billableTotal)) tokens")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
        )
    }
}

// MARK: - Formatting helpers

enum TokenFormatter {
    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }
}

enum DurationFormatter {
    static func string(from seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }
}

#Preview {
    ClaudeView()
        .environmentObject(BoringViewModel())
        .frame(width: 360, height: 180)
        .background(Color.black)
}
