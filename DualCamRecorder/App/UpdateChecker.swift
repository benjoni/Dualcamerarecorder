//
//  UpdateChecker.swift
//  DualCamRecorder
//
//  Tells the user that a newer build is on the website. Reads https://dualrecorder.benjoni.com/version.json
//  (written by tools/release.sh) at launch and once a day; nothing is sent about the user or the Mac.
//  A newer build opens the Update window – never while recording (it waits for STOP). The download is done
//  in the browser; the licence and the projects stay when the app is replaced.
//

import Foundation
import AppKit

/// version.json on the website.
struct UpdateInfo: Decodable, Equatable {
    var version: String
    var build: Int
    /// The zip to download.
    var url: URL
    /// What is new (one line each).
    var notes: [String]?
    /// "2026-11-16"
    var date: String?
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        case available(UpdateInfo)
        case upToDate
        case failed(String)
    }

    /// What the Update window shows.
    @Published private(set) var state = State.idle
    /// Set when the Update window should open (the main window opens it and sets it back).
    @Published var wantsWindow = false
    /// Check at launch and once a day (App settings).
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Self.automaticKey); if automatic { checkIfDue() } }
    }
    /// The app is recording – an update found then is shown after STOP.
    var isBusy: () -> Bool = { false }

    private static let automaticKey = "checkForUpdates"
    private static let lastCheckKey = "updateLastCheck"
    private static let skippedKey = "updateSkippedBuild"
    private var timer: Timer?
    private var waiting: Timer?

    /// Debug builds can read another feed (-updateFeedURL file:///…/version.json).
    private var feed: URL {
        #if DEBUG
        if let custom = UserDefaults.standard.string(forKey: "updateFeedURL"), let url = URL(string: custom) { return url }
        #endif
        return URL(string: "https://dualrecorder.benjoni.com/version.json")!
    }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    private init() {
        automatic = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    /// Launch: check now when due, then look again every hour (a check is due once a day).
    func start() {
        checkIfDue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    func checkIfDue() {
        guard automatic else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        Task { await check(manual: false) }
    }

    /// Manual (menu / App settings): always shows the result; a skipped build is offered again.
    func check(manual: Bool) async {
        if case .checking = state { return }
        if manual {
            state = .checking
            wantsWindow = true
        }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("DualCamRecorder/\(currentVersion) (\(currentBuild))", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            let skipped = UserDefaults.standard.integer(forKey: Self.skippedKey)
            if info.build > currentBuild && (manual || info.build != skipped) {
                state = .available(info)
                show()
            } else if manual {
                state = .upToDate
            } else if case .available = state {
                // keep showing what was found
            } else {
                state = .idle
            }
        } catch {
            if manual { state = .failed(error.localizedDescription) }
        }
    }

    /// Opens the Update window – after STOP when recording.
    private func show() {
        waiting?.invalidate()
        if !isBusy() {
            wantsWindow = true
            return
        }
        waiting = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
            Task { @MainActor in
                let checker = UpdateChecker.shared
                guard !checker.isBusy() else { return }
                timer.invalidate()
                checker.wantsWindow = true
            }
        }
    }

    func download(_ info: UpdateInfo) {
        NSWorkspace.shared.open(info.url)
    }

    /// Not offered again automatically (Check for Updates… still shows it).
    func skip(_ info: UpdateInfo) {
        UserDefaults.standard.set(info.build, forKey: Self.skippedKey)
        state = .idle
    }
}
