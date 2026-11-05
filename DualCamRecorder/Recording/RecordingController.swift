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

/// Big red warning: the disk being recorded to went away during a take.
struct DiskAlert: Equatable {
    var volumeName: String
    var take: Int
    var stoppedAfter: TimeInterval
    var at = Date()
    /// What was saved where – filled in when the cameras have finished.
    var details: [String] = []
}

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
    /// Devices with a video output (for a monitor).
    @Published private(set) var outputDevices: [DLDeviceDescriptor] = []
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
    /// The recording disk was disconnected – the take was stopped (shown until OK).
    @Published private(set) var diskAlert: DiskAlert?
    /// The disk cannot keep up: shown while recording and after STOP until the next REC.
    @Published private(set) var writeWarning: String?

    let sdkStatus: String

    private let browser = DLDeviceBrowser()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var pendingResults: [ChannelTakeResult] = []
    private var expectedResults = 0
    private var activity: NSObjectProtocol?
    private var recordStartHost: UInt64 = 0
    private var recordFolder: URL?
    /// Volume of the running take's folder and its name.
    private var recordVolume: (url: URL, name: String)?
    private var diskLost = false
    private var droppedAtLastTick: [CameraRole: Int] = [:]
    private var unmountObservers: [NSObjectProtocol] = []

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

        // Camera's own REC from the SDI signal: how it is read (project settings) and the camera trigger.
        settings.$recDetectionA.removeDuplicates().sink { [weak self] d in self?.channelA.setRecDetection(d) }.store(in: &cancellables)
        settings.$recDetectionB.removeDuplicates().sink { [weak self] d in self?.channelB.setRecDetection(d) }.store(in: &cancellables)
        channelA.onCameraRecChange = { [weak self] _ in self?.cameraRecChanged() }
        channelB.onCameraRecChange = { [weak self] _ in self?.cameraRecChanged() }

        // An external disk ejected or pulled out while recording stops the take at once.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification] {
            unmountObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                self?.volumeWentAway(url)
            })
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        refreshNextTake()
        updateDiskSpace()
        applyAssignment(role: .a)
        applyAssignment(role: .b)
    }

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        unmountObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: - Devices

    func deviceBrowser(_ browser: DLDeviceBrowser, didUpdateDevices devices: [DLDeviceDescriptor]) {
        let old = Set(self.devices.map(\.identifier))
        self.devices = devices.filter(\.supportsCapture)
        self.outputDevices = devices.filter(\.supportsPlayback)
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

    /// Temporarily switch one camera of a two-camera project off/on (the other one fills the screen and
    /// records alone). At least one camera stays on; not while recording.
    func setCamera(_ role: CameraRole, on: Bool) {
        guard state == .idle, settings.twoCameras else { return }
        let other: CameraRole = role == .a ? .b : .a
        if !on && !settings.isCameraOn(other) { return }
        if role == .a { settings.cameraAOn = on } else { settings.cameraBOn = on }
    }

    func toggleCamera(_ role: CameraRole) {
        setCamera(role, on: !settings.isCameraOn(role))
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
            ch.setSource(SimulatedSource(label: settings.cameraNames.name(role),
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
    /// The running take is a rehearsal (only the app records).
    var isRehearsal: Bool { isRecording && recordingSlate?.rehearsal == true }

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

    /// Rehearsal: both inputs are recorded only by the app; the take is marked "Rehearsal", gets no take number
    /// of its own and the cameras' clip numbers stay (the cameras do not record).
    func startRehearsal() { startRecording(rehearsal: true) }

    func startRecording(rehearsal: Bool = false) {
        guard state == .idle else { return }
        errorMessage = nil
        let folder = settings.recordFolderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Record folder is not available: \(error.localizedDescription)"
            return
        }
        let active = CameraRole.allCases.filter { channel($0).hasSource && settings.isCameraOn($0) }
        guard !active.isEmpty else {
            errorMessage = "No camera is assigned."
            return
        }

        let names = settings.cameraNames
        settings.rememberCameraNames(names)
        let take = TakeNaming.nextTakeNumber(in: folder, names: names)
        // Common start instant slightly in the future so both channels see it.
        let startHost = HostClock.nowNanos + 200_000_000
        let audioChannels = settings.audioChannels
        pendingResults = []
        expectedResults = 0
        // Units of a camera settings field still being typed in (they are completed when the field is left).
        settings.slate.setupA = settings.slate.setupA.completed
        settings.slate.setupB = settings.slate.setupB.completed
        var slate = settings.slate
        slate.recordedAt = Date()
        slate.rehearsal = rehearsal
        if rehearsal {
            slate.cameraClipA = ""
            slate.cameraClipB = ""
        }

        var armed: [CameraChannel] = []
        for role in active {
            let ch = channel(role)
            let url = folder.appendingPathComponent(TakeNaming.fileName(take: take, role: role, slate: slate, names: names))
            ch.resetCounters()
            if let failure = ch.arm(url: url, startHostNanos: startHost, flavor: settings.proResFlavor,
                                    hevcMbps: settings.hevcMbps,
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
        recordVolume = Self.volume(of: folder)
        diskLost = false
        writeWarning = nil
        droppedAtLastTick = [:]
        marks = TakeMarks()
        recordingSlate = slate
        state = .recording(take: take, started: Date())
        elapsed = 0
        lastTakeMessage = rehearsal ? "Rehearsal – only the app records" : nil
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

    /// Removes the last IN / OUT range.
    func clearMarks() {
        guard case .recording = state else { return }
        marks.removeLast()
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

    // MARK: - Camera trigger

    /// The camera may start a take only while a project is open (not on the project list).
    var cameraTriggerAllowed = false

    /// Cameras whose REC starts / stops the app (Project settings → Record with the camera).
    var triggerRoles: [CameraRole] {
        switch settings.cameraTrigger {
        case .off: return []
        case .a: return settings.isCameraOn(.a) ? [.a] : []
        case .b: return settings.isCameraOn(.b) ? [.b] : []
        case .any: return settings.activeRoles
        }
    }

    /// A camera started or stopped: REC when one of the trigger cameras records, STOP when all of them stopped.
    private func cameraRecChanged() {
        guard !isRehearsal else { return }   // the cameras do not record during a rehearsal
        let states = triggerRoles.map { channel($0).signal.cameraRec }
        guard !states.isEmpty else { return }
        if states.contains(.recording) {
            if state == .idle, cameraTriggerAllowed {
                startRecording()
                if isRecording { lastTakeMessage = "Started by the camera" }
            }
        } else if states.contains(.stopped), case .recording = state {
            // No trigger camera records any more – one without signal / REC information (unknown) does not
            // keep the take running.
            stopRecording()
        }
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
        // Disk pulled out: slate and IN/OUT go to a rescue folder on this Mac.
        let saveFolder = diskLost ? Self.rescueFolder(for: recordFolder) : recordFolder
        if diskLost, let saveFolder {
            try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        }
        // A camera recorded when its file has frames (a failed file keeps what reached the disk).
        let recorded: (CameraRole) -> Bool = { role in
            self.pendingResults.contains { $0.role == role && ($0.error == nil || $0.framesWritten > 0) }
        }
        let summary = pendingResults.sorted { $0.role.rawValue < $1.role.rawValue }
            .map { "\($0.url.lastPathComponent) (\($0.framesWritten) frames)" }
            .joined(separator: ", ")
        lastTakeMessage = (recordingSlate?.rehearsal == true ? "Rehearsal saved: " : "Saved: ") + summary

        // Save IN/OUT. The file timeline starts at the first written frame, which is within
        // ½ frame of the common start instant – correct for that small difference.
        if !marks.isEmpty, let folder = saveFolder, let take = activeTake {
            var m = marks
            let firsts = pendingResults.compactMap(\.firstFrameHostNanos)
            if let first = firsts.min() {
                let shift = Double(Int64(first) - Int64(recordStartHost)) / 1_000_000_000
                m = m.shifted(by: -shift)
            }
            do {
                try TakeMarksStore.save(m, folder: folder, take: take)
            } catch {
                errorMessage = "Could not save IN/OUT: \(error.localizedDescription)"
            }
        }
        // Save the slate (note / "good" may have been edited during the take) and advance the take number.
        if var slate = recordingSlate, let folder = saveFolder, let take = activeTake,
           recorded(.a) || recorded(.b) {
            slate.note = settings.slate.note
            slate.good = settings.slate.good
            // Camera clip numbers: a camera that did not record this take is stored as 0.
            let recordedA = recorded(.a)
            let recordedB = recorded(.b)
            let clipA = slate.cameraClipA
            let clipB = slate.cameraClipB
            if !recordedA { slate.cameraClipA = "" }
            if !recordedB { slate.cameraClipB = "" }
            if !recordedA { slate.cardA = "" }   // the card stays in settings.slate for the next take
            if !recordedB { slate.cardB = "" }
            if !recordedA { slate.setupA = CameraSetup() }
            if !recordedB { slate.setupB = CameraSetup() }
            // Camera timecode of each file (TC IN – TC OUT).
            slate.timecodeA = recordedA ? pendingResults.first { $0.role == .a }?.timecode : nil
            slate.timecodeB = recordedB ? pendingResults.first { $0.role == .b }?.timecode : nil
            do {
                try TakeSlateStore.save(slate, folder: folder, take: take)
            } catch {
                errorMessage = "Could not save the slate: \(error.localizedDescription)"
            }
            var next = settings.slate
            next.note = ""
            next.good = false
            next.recordedAt = nil
            next.rehearsal = false
            // A rehearsal is not a take: the take number and the cameras' clip numbers stay.
            if !slate.rehearsal {
                next.take = slate.take + 1
                // The cameras start a new internal clip with every take.
                if recordedA { next.cameraClipA = CameraClipID.next(clipA) }
                if recordedB { next.cameraClipB = CameraClipID.next(clipB) }
            }
            settings.slate = next

            // Script-friendly log of all clips in the project folder.
            let names = settings.cameraNames
            if !diskLost {
                DispatchQueue.global(qos: .utility).async { ClipLog.rebuild(folder: folder, names: names) }
            }
        }
        recordingSlate = nil
        if diskLost {
            var details = pendingResults.sorted { $0.role.rawValue < $1.role.rawValue }.map { r in
                r.framesWritten > 0
                    ? "\(r.url.lastPathComponent): \(r.framesWritten) frames were sent to the disk – what reached it plays up to about 2 s before the disconnection."
                    : "\(r.url.lastPathComponent): nothing was written."
            }
            if let saveFolder {
                details.append("Slate and IN/OUT of the take are saved on this Mac in \(saveFolder.path) – copy them into the project folder with the clips.")
            }
            details.append("Reconnect the disk (or choose another folder) before the next take.")
            diskAlert?.details = details
            lastTakeMessage = "Take stopped – recording disk disconnected"
        } else if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
        }
        if writeWarning != nil {
            let lost = pendingResults.sorted { $0.role.rawValue < $1.role.rawValue }
                .map { "Cam\($0.role.rawValue) lost \(channel($0.role).stats.writerDropped) frames" }
            writeWarning = "Last take: disk too slow – " + lost.joined(separator: ", ")
        }
        diskLost = false

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
            // Fallback for a disk that disappears without an unmount notice.
            if let folder = recordFolder, !FileManager.default.fileExists(atPath: folder.path) {
                recordingDiskDisconnected()
            } else {
                checkWriteSpeed()
            }
        }
        updateDiskSpace()
    }

    // MARK: - Recording disk

    private static func volume(of folder: URL) -> (url: URL, name: String)? {
        guard let values = try? folder.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey]),
              let url = values.volume else { return nil }
        return (url.standardizedFileURL, values.volumeName ?? url.lastPathComponent)
    }

    /// `~/Movies/DualCamRecorder Rescue/<project folder>` – for the slate of a take whose disk went away.
    private static func rescueFolder(for folder: URL?) -> URL? {
        guard let folder else { return nil }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return movies.appendingPathComponent("DualCamRecorder Rescue", isDirectory: true)
            .appendingPathComponent(folder.lastPathComponent, isDirectory: true)
    }

    private func volumeWentAway(_ url: URL) {
        guard isRecording, let volume = recordVolume,
              url.standardizedFileURL.path == volume.url.path, volume.url.path != "/" else { return }
        recordingDiskDisconnected()
    }

    /// Stops the take at once and shows the big red warning.
    func recordingDiskDisconnected() {
        guard isRecording, !diskLost, let take = activeTake else { return }
        diskLost = true
        diskAlert = DiskAlert(volumeName: recordVolume?.name ?? settings.recordFolderURL.lastPathComponent,
                              take: take, stoppedAfter: elapsed)
        if case .recording = state { stopRecording() }
        NSSound(named: "Basso")?.play()
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissDiskAlert() {
        diskAlert = nil
        updateDiskSpace()
    }

    /// Frames waiting for the writer or dropped by it while recording = the disk is too slow.
    private func checkWriteSpeed() {
        var problems: [String] = []
        for role in CameraRole.allCases where channel(role).isRecording {
            let stats = channel(role).stats
            let newDrops = stats.writerDropped - (droppedAtLastTick[role] ?? 0)
            droppedAtLastTick[role] = stats.writerDropped
            if newDrops > 0 {
                problems.append("Cam\(role.rawValue) lost \(stats.writerDropped) frames")
            } else if stats.writeBacklog >= 5 {
                problems.append("Cam\(role.rawValue) is falling behind")
            }
        }
        guard !problems.isEmpty else { return }
        writeWarning = "Disk too slow – " + problems.joined(separator: ", ")
    }

    func dismissWriteWarning() {
        guard !isRecording else { return }
        writeWarning = nil
    }

    /// Free space of the recording disk, read off the main thread (the call can take tens of ms, which made the
    /// live pictures stutter when it ran on the main thread twice a second).
    private func updateDiskSpace() {
        guard !diskSpaceQueryRunning else { return }
        diskSpaceQueryRunning = true
        let folder = settings.recordFolderURL
        Self.diskQueue.async {
            var url = folder
            // Walk up to an existing ancestor so the indicator works before the folder is created.
            while !FileManager.default.fileExists(atPath: url.path) && url.pathComponents.count > 1 {
                url.deleteLastPathComponent()
            }
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                           .volumeAvailableCapacityKey,
                                                           .volumeTotalCapacityKey])
            let free: Int64?
            if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
                free = important
            } else if let available = values?.volumeAvailableCapacity {
                free = Int64(available)
            } else {
                free = nil
            }
            let total = values?.volumeTotalCapacity.map { Int64($0) }
            DispatchQueue.main.async {
                self.diskSpaceQueryRunning = false
                if self.freeBytes != free { self.freeBytes = free }
                if self.totalBytes != total { self.totalBytes = total }
            }
        }
    }

    private var diskSpaceQueryRunning = false
    private static let diskQueue = DispatchQueue(label: "disk-space", qos: .utility)

    /// Estimated remaining recording time for all active cameras.
    var estimatedRemaining: TimeInterval? {
        guard let freeBytes else { return nil }
        var bytesPerSecond = 0.0
        for ch in [channelA, channelB] where ch.hasSource {
            let fps = ch.format?.frameRate ?? 25
            let pixels = Double((ch.format?.width ?? 1920) * (ch.format?.height ?? 1080))
            let videoBits = settings.proResFlavor.approxBitsPerSecondHD(fps: fps, hevcMbps: settings.hevcMbps)
                * pixels / (1920 * 1080)
            let audioBits = Double(settings.audioChannels) * 24 * 48_000
            bytesPerSecond += (videoBits + audioBits) / 8
        }
        guard bytesPerSecond > 0 else { return nil }
        return Double(freeBytes) / bytesPerSecond
    }
}

extension Notification.Name {
    static let takeFinished = Notification.Name("DualCamRecorder.takeFinished")
}
