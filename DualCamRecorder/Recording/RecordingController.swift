//
//  RecordingController.swift
//  DualCamRecorder
//
//  Owns device discovery, A/B assignment, both CameraChannels, REC/STOP, take numbering and disk space.
//  All methods are meant to be called on the main thread.
//

import Foundation
import Combine
import AppKit

struct DeviceOption: Identifiable, Hashable {
    let id: String
    let title: String
}

final class RecordingController: NSObject, ObservableObject, DLDeviceBrowserDelegate {
    enum State: Equatable {
        case idle
        case recording(take: Int, started: Date)
        case stopping(take: Int)
    }

    let settings: AppSettings
    let channelA = CameraChannel(role: .a)
    let channelB = CameraChannel(role: .b)

    @Published private(set) var devices: [DLDeviceDescriptor] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var nextTake: Int = 1
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var totalBytes: Int64?
    @Published private(set) var lastTakeMessage: String?
    /// Measured start offset of the last take: first frame B − first frame A (ms).
    @Published private(set) var lastStartOffsetMs: Double?
    @Published var errorMessage: String?

    let sdkStatus: String

    private let browser = DLDeviceBrowser()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var pendingResults: [ChannelTakeResult] = []
    private var expectedResults = 0
    private var activity: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        if !DLDeviceBrowser.isSDKCompiledIn {
            sdkStatus = "Zostavené bez DeckLink SDK – dostupný je len simulovaný vstup."
        } else if !DLDeviceBrowser.isDriverInstalled {
            sdkStatus = "SDK \(DLDeviceBrowser.compiledSDKVersion ?? "?") · Desktop Video ovládač nie je nainštalovaný."
        } else {
            sdkStatus = "SDK \(DLDeviceBrowser.compiledSDKVersion ?? "?") · ovládač \(DLDeviceBrowser.driverVersion ?? "?")"
        }
        super.init()

        // Capture must not be throttled by App Nap / timer coalescing.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Live SDI capture")

        browser.delegate = self
        browser.start()

        // Forward channel changes so views observing the controller refresh.
        channelA.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        channelB.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        refreshNextTake()
        updateDiskSpace()
        applyAssignment(role: .a)
        applyAssignment(role: .b)
    }

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: - Devices

    func deviceBrowser(_ browser: DLDeviceBrowser, didUpdateDevices devices: [DLDeviceDescriptor]) {
        let old = Set(self.devices.map(\.identifier))
        self.devices = devices.filter(\.supportsCapture)
        let new = Set(self.devices.map(\.identifier))

        // First run: auto-assign device 1 → A, device 2 → B.
        if settings.deviceA.isEmpty, let first = self.devices.first {
            settings.deviceA = first.identifier
        }
        if settings.deviceB.isEmpty, self.devices.count > 1 {
            settings.deviceB = self.devices[1].identifier
        }
        // (Re)start channels whose device appeared or disappeared.
        for role in CameraRole.allCases {
            let id = assignedID(role)
            if old.contains(id) != new.contains(id) || (new.contains(id) && !channel(role).hasSource) {
                applyAssignment(role: role)
            }
        }
    }

    var deviceOptions: [DeviceOption] {
        var options = [DeviceOption(id: "", title: "— žiadne —")]
        let nameCounts = Dictionary(grouping: devices, by: \.displayName).mapValues(\.count)
        var seen: [String: Int] = [:]
        for d in devices {
            var title = d.displayName
            if (nameCounts[d.displayName] ?? 0) > 1 {
                seen[d.displayName, default: 0] += 1
                title += " (\(seen[d.displayName]!))"
            }
            options.append(DeviceOption(id: d.identifier, title: title))
        }
        options.append(DeviceOption(id: AppSettings.simulatedDeviceID, title: "Simulovaný vstup (testovací obraz)"))
        return options
    }

    func channel(_ role: CameraRole) -> CameraChannel { role == .a ? channelA : channelB }

    func assignedID(_ role: CameraRole) -> String { role == .a ? settings.deviceA : settings.deviceB }

    func assign(_ id: String, to role: CameraRole) {
        guard state == .idle else { return }
        // A device can only feed one camera slot.
        if id != AppSettings.simulatedDeviceID && !id.isEmpty {
            let other: CameraRole = role == .a ? .b : .a
            if assignedID(other) == id {
                if other == .a { settings.deviceA = "" } else { settings.deviceB = "" }
                applyAssignment(role: other)
            }
        }
        if role == .a { settings.deviceA = id } else { settings.deviceB = id }
        applyAssignment(role: role)
    }

    /// Re-creates sources (also used after audio / bit-depth settings change).
    func restartSources() {
        guard state == .idle else { return }
        applyAssignment(role: .a)
        applyAssignment(role: .b)
    }

    private func applyAssignment(role: CameraRole) {
        let ch = channel(role)
        ch.setSource(nil)
        let id = assignedID(role)
        if id.isEmpty { return }
        if id == AppSettings.simulatedDeviceID {
            ch.setSource(SimulatedSource(label: role.rawValue,
                                         phaseOffset: role == .a ? 0 : 0.4,
                                         audioChannels: settings.audioChannels,
                                         hue: role == .a ? 0.6 : 0.08))
            return
        }
        guard let descriptor = devices.first(where: { $0.identifier == id }) else { return }
        if let src = DeckLinkSource(descriptor: descriptor, audioChannels: settings.audioChannels,
                                    forceEightBit: settings.forceEightBit) {
            ch.setSource(src)
        } else {
            errorMessage = "Zariadenie \(descriptor.displayName) sa nepodarilo otvoriť."
        }
    }

    // MARK: - Recording

    var isRecording: Bool { if case .idle = state { return false } else { return true } }

    /// Take currently being written (hidden from the playback list).
    var activeTake: Int? {
        switch state {
        case .idle: return nil
        case .recording(let take, _), .stopping(let take): return take
        }
    }

    func toggleRecording() {
        switch state {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .stopping: break
        }
    }

    func startRecording() {
        guard state == .idle else { return }
        errorMessage = nil
        let folder = settings.recordFolderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Priečinok na zápis nie je dostupný: \(error.localizedDescription)"
            return
        }
        let active = CameraRole.allCases.filter { channel($0).hasSource }
        guard !active.isEmpty else {
            errorMessage = "Nie je priradená žiadna kamera."
            return
        }

        let take = TakeNaming.nextTakeNumber(in: folder)
        // Common start instant slightly in the future so both channels see it.
        let startHost = HostClock.nowNanos + 200_000_000
        let audioChannels = settings.audioChannels
        pendingResults = []
        expectedResults = 0

        var armed: [CameraChannel] = []
        for role in active {
            let ch = channel(role)
            let url = folder.appendingPathComponent(TakeNaming.fileName(take: take, role: role))
            ch.resetCounters()
            if let failure = ch.arm(url: url, startHostNanos: startHost, flavor: settings.proResFlavor,
                                    audioChannels: audioChannels,
                                    completion: { [weak self] result in self?.channelFinished(result) }) {
                armed.forEach { $0.cancelArmed() }
                errorMessage = failure
                return
            }
            armed.append(ch)
        }
        expectedResults = armed.count
        state = .recording(take: take, started: Date())
        elapsed = 0
        lastTakeMessage = nil
    }

    func stopRecording() {
        guard case .recording(let take, _) = state else { return }
        let stopHost = HostClock.nowNanos
        state = .stopping(take: take)
        for role in CameraRole.allCases where channel(role).isRecording {
            channel(role).requestStop(atHostNanos: stopHost)
        }
    }

    private func channelFinished(_ result: ChannelTakeResult) {
        pendingResults.append(result)
        guard pendingResults.count >= expectedResults else { return }

        let a = pendingResults.first { $0.role == .a }
        let b = pendingResults.first { $0.role == .b }
        if let ha = a?.firstFrameHostNanos, let hb = b?.firstFrameHostNanos {
            lastStartOffsetMs = (Double(Int64(hb) - Int64(ha))) / 1_000_000
        } else {
            lastStartOffsetMs = nil
        }
        let errors = pendingResults.compactMap { r in r.error.map { "Cam\(r.role.rawValue): \($0)" } }
        let summary = pendingResults.sorted { $0.role.rawValue < $1.role.rawValue }
            .map { "\($0.url.lastPathComponent) (\($0.framesWritten) sn.)" }
            .joined(separator: ", ")
        lastTakeMessage = "Uložené: " + summary
        if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }

        state = .idle
        pendingResults = []
        refreshNextTake()
        updateDiskSpace()
        NotificationCenter.default.post(name: .takeFinished, object: nil)
    }

    // MARK: - Folder / disk

    func chooseRecordFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Vybrať"
        panel.directoryURL = settings.recordFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordFolderPath = url.path
            refreshNextTake()
            updateDiskSpace()
        }
    }

    func refreshNextTake() {
        nextTake = TakeNaming.nextTakeNumber(in: settings.recordFolderURL)
    }

    private func tick() {
        if case .recording(_, let started) = state {
            elapsed = Date().timeIntervalSince(started)
        }
        updateDiskSpace()
    }

    private func updateDiskSpace() {
        var url = settings.recordFolderURL
        // Walk up to an existing ancestor so the indicator works before the folder is created.
        while !FileManager.default.fileExists(atPath: url.path) && url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                       .volumeAvailableCapacityKey,
                                                       .volumeTotalCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            freeBytes = important
        } else if let available = values?.volumeAvailableCapacity {
            freeBytes = Int64(available)
        } else {
            freeBytes = nil
        }
        totalBytes = values?.volumeTotalCapacity.map { Int64($0) }
    }

    /// Estimated remaining recording time for all active cameras.
    var estimatedRemaining: TimeInterval? {
        guard let freeBytes else { return nil }
        var bytesPerSecond = 0.0
        for ch in [channelA, channelB] where ch.hasSource {
            let fps = ch.format?.frameRate ?? 25
            let pixels = Double((ch.format?.width ?? 1920) * (ch.format?.height ?? 1080))
            let bitsPerFrame = settings.proResFlavor.approxBitsPerHDFrame * pixels / (1920 * 1080)
            let audioBits = Double(settings.audioChannels) * 24 * 48_000
            bytesPerSecond += (bitsPerFrame * fps + audioBits) / 8
        }
        guard bytesPerSecond > 0 else { return nil }
        return Double(freeBytes) / bytesPerSecond
    }
}

extension Notification.Name {
    static let takeFinished = Notification.Name("DualCamRecorder.takeFinished")
}
