//
//  ClaudeSessionsViewModel.swift
//  boringNotch
//
//  Created by Alban on 2026-08-04.
//

import Defaults
import Foundation

@MainActor
final class ClaudeSessionsViewModel: ObservableObject {
    static let shared = ClaudeSessionsViewModel()

    @Published private(set) var activeSessions: [ClaudeSessionInfo] = []
    @Published private(set) var allTimeTotal: ClaudeTokenUsage = .init()
    @Published private(set) var todayTotal: Int = 0
    @Published private(set) var limitWindowTotal: Int = 0
    @Published private(set) var projectsDirectoryExists: Bool = false

    let limitWindowHours = ClaudeUsageScanner.limitWindowHours

    private let projectsRoot: URL
    private let watcher: ClaudeProjectsWatcher
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    private init() {
        let claudeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        projectsRoot = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        watcher = ClaudeProjectsWatcher(path: claudeRoot.path)

        watcher.start { [weak self] in
            Task { @MainActor in
                self?.scheduleDebouncedRescan()
            }
        }
        rescan()
    }

    /// Called when the Claude panel appears, as a cheap safety net on top of the FSEvents watcher.
    func refreshOnAppear() {
        rescan()
    }

    private func scheduleDebouncedRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.rescan()
        }
    }

    func rescan() {
        scanTask?.cancel()
        let root = projectsRoot
        scanTask = Task { [weak self] in
            let scanner = ClaudeUsageScanner(projectsRoot: root)
            let result = await scanner.scan()
            guard !Task.isCancelled else { return }
            self?.apply(result)
        }
    }

    private func apply(_ result: ClaudeUsageScanner.ScanResult) {
        activeSessions = result.sessions
        allTimeTotal = result.allTimeTotal
        todayTotal = result.todayTotal
        limitWindowTotal = result.limitWindowTotal
        projectsDirectoryExists = result.projectsDirectoryExists
    }
}
