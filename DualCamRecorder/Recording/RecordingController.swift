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
    /// IN / OUT marks of the take being recorded (seconds from the start of the take).
    @Published private(set) var marks = TakeMarks()
    /// Slate snapshot of the take being recorded (scene/shot/take frozen at REC).
    @Published private(set) var recordingSlate: SlateInfo?

    let sdkStatus: String

    private let browser = DLDeviceBrowser()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var pendingResults: [ChannelTakeResult] = []
    private var expectedResults = 0
    private var activity: NSObjectProtocol?
    private var recordStartHost: UInt64 = 0
    private var recordFolder: URL?

    init(settings: AppSettings) {
        self.settings = settings
        if !DLDeviceBrowser.isSDKCompiledIn {
            sdkStatus = "Built without the DeckLink SDK – only simulated input is available."
        } else if !DLDeviceBrowser.isDriverInstalled {
            sdkStatus = "SDK \(DLDeviceBrowser.compiledSDKVersion ?? "?") · Desktop Video driver is not installed."
        } else {
            sdkStatus = "SDK \(DLDeviceBrowser.compiledSDKVersion ?? "?") · driver \(DLDeviceBrowser.driverVersion ?? "?")"
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
        var options = [DeviceOption(id: "", title: "— none —")]
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
        options.append(DeviceOption(id: AppSettings.simulatedDeviceID, title: "Simulated input (test pattern)"))
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

    /// One or two cameras for the open project (camera B is stopped in one-camera mode).
    func setCameraCount(_ count: Int) {
        guard state == .idle else { return }
        settings.cameraCount = count == 1 ? 1 : 2
        applyAssignment(role: .b)
    }

    private func applyAssignment(role: CameraRole) {
        let ch = channel(role)
        ch.setSource(nil)
        if role == .b && !settings.twoCameras { return }
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
            errorMessage = "Could not open device \(descriptor.displayName)."
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
            errorMessage = "Record folder is not available: \(error.localizedDescription)"
            return
        }
        let active = CameraRole.allCases.filter { channel($0).hasSource }
        guard !active.isEmpty else {
            errorMessage = "No camera is assigned."
            return
        }

        let names = settings.cameraNames
        let take = TakeNaming.nextTakeNumber(in: folder, names: names)
        // Common start instant slightly in the future so both channels see it.
        let startHost = HostClock.nowNanos + 200_000_000
        let audioChannels = settings.audioChannels
        pendingResults = []
        expectedResults = 0
        var slate = settings.slate
        slate.recordedAt = Date()

        var armed: [CameraChannel] = []
        for role in active {
            let ch = channel(role)
            let url = folder.appendingPathComponent(TakeNaming.fileName(take: take, role: role, slate: slate, names: names))
            ch.resetCounters()
            if let failure = ch.arm(url: url, startHostNanos: startHost, flavor: settings.proResFlavor,
                                    audioChannels: audioChannels,
                                    metadata: slate.metadataItems(camera: role, takeNumber: take, names: names),
                                    completion: { [weak self] result in self?.channelFinished(result) }) {
                armed.forEach { $0.cancelArmed() }
                errorMessage = failure
                return
            }
            armed.append(ch)
        }
        expectedResults = armed.count
        recordStartHost = startHost
        recordFolder = folder
        marks = TakeMarks()
        recordingSlate = slate
        state = .recording(take: take, started: Date())
        elapsed = 0
        lastTakeMessage = nil
    }

    // MARK: - IN / OUT during recording

    /// Seconds since the common start instant of the running take.
    private var recordPosition: Double {
        Double(Int64(HostClock.nowNanos) - Int64(recordStartHost)) / 1_000_000_000
    }

    func markIn() {
        guard case .recording = state else { return }
        marks.setIn(recordPosition)
    }

    func markOut() {
        guard case .recording = state else { return }
        if !marks.setOut(recordPosition) {
            errorMessage = "OUT cannot be before IN."
        }
    }

    func clearMarks() {
        guard case .recording = state else { return }
        marks = TakeMarks()
    }

    // MARK: - Slate

    /// Fields that identify the take are frozen while recording; note / good stay editable.
    var slateLocked: Bool { isRecording }

    /// Changing scene or shot starts counting takes from 1 again.
    func setSlateScene(_ value: String) {
        guard !slateLocked, value != settings.slate.scene else { return }
        settings.slate.scene = value
        settings.slate.take = 1
    }

    func setSlateShot(_ value: String) {
        guard !slateLocked, value != settings.slate.shot else { return }
        settings.slate.shot = value
        settings.slate.take = 1
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
            .map { "\($0.url.lastPathComponent) (\($0.framesWritten) frames)" }
            .joined(separator: ", ")
        lastTakeMessage = "Saved: " + summary

        // Save IN/OUT. The file timeline starts at the first written frame, which is within
        // ½ frame of the common start instant – correct for that small difference.
        if !marks.isEmpty, let folder = recordFolder, let take = activeTake {
            var m = marks
            let firsts = pendingResults.compactMap(\.firstFrameHostNanos)
            if let first = firsts.min() {
                let shift = Double(Int64(first) - Int64(recordStartHost)) / 1_000_000_000
                if let i = m.inPoint { m.inPoint = max(0, i - shift) }
                if let o = m.outPoint { m.outPoint = max(0, o - shift) }
            }
            do {
                try TakeMarksStore.save(m, folder: folder, take: take)
            } catch {
                errorMessage = "Could not save IN/OUT: \(error.localizedDescription)"
            }
        }
        // Save the slate (note / "good" may have been edited during the take) and advance the take number.
        if var slate = recordingSlate, let folder = recordFolder, let take = activeTake,
           pendingResults.contains(where: { $0.error == nil }) {
            slate.note = settings.slate.note
            slate.good = settings.slate.good
            // Camera clip numbers: a camera that did not record this take is stored as 0.
            let recordedA = pendingResults.contains { $0.role == .a && $0.error == nil }
            let recordedB = pendingResults.contains { $0.role == .b && $0.error == nil }
            let clipA = slate.cameraClipA
            let clipB = slate.cameraClipB
            if !recordedA { slate.cameraClipA = "" }
            if !recordedB { slate.cameraClipB = "" }
            do {
                try TakeSlateStore.save(slate, folder: folder, take: take)
            } catch {
                errorMessage = "Could not save the slate: \(error.localizedDescription)"
            }
            var next = settings.slate
            next.take = slate.take + 1
            next.note = ""
            next.good = false
            next.recordedAt = nil
            // The cameras start a new internal clip with every take.
            if recordedA { next.cameraClipA = CameraClipID.next(clipA) }
            if recordedB { next.cameraClipB = CameraClipID.next(clipB) }
            settings.slate = next

            // Script-friendly log of all clips in the project folder.
            let names = settings.cameraNames
            DispatchQueue.global(qos: .utility).async { ClipLog.rebuild(folder: folder, names: names) }
        }
        recordingSlate = nil
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
        panel.prompt = "Choose"
        panel.directoryURL = settings.recordFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordFolderPath = url.path
            refreshNextTake()
            updateDiskSpace()
        }
    }

    /// Camera name used at the start of the file names (A007_… / B007_…).
    func setCameraName(_ name: String, for role: CameraRole) {
        guard !isRecording else { return }
        if role == .a { settings.cameraNameA = name } else { settings.cameraNameB = name }
        refreshNextTake()
        NotificationCenter.default.post(name: .takeFinished, object: nil)   // library re-scan
    }

    func refreshNextTake() {
        nextTake = TakeNaming.nextTakeNumber(in: settings.recordFolderURL, names: settings.cameraNames)
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
