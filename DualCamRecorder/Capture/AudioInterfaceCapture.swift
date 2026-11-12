//
//  AudioInterfaceCapture.swift
//  DualCamRecorder
//
//  Sound from a USB / Thunderbolt audio interface (e.g. Focusrite Scarlett) recorded into the camera files.
//  AVCaptureSession converts the interface's input to 48 kHz, 32-bit integer, interleaved – the format the
//  MovieWriter takes – and every buffer gets its time on the shared host clock, so it lines up with the
//  pictures of both cameras.
//

import Foundation
import AVFoundation
import CoreMedia
import Combine
import os

/// How the audio interface is used in a project.
enum AudioInterfaceMode: String, Codable, CaseIterable, Identifiable {
    /// Not used – only the cameras' SDI sound.
    case off
    /// Interface on its own track (played back), the cameras' SDI sound kept as a second track.
    case withSDI
    /// Interface only – no SDI sound in the files.
    case insteadOfSDI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .withSDI: return "Interface + SDI sound"
        case .insteadOfSDI: return "Interface only"
        }
    }
}

struct AudioInterfaceDevice: Identifiable, Hashable {
    let id: String          // AVCaptureDevice.uniqueID
    let name: String
    let channels: Int       // input channels of its current format
}

/// One buffer from the interface: interleaved Int32 sample frames at 48 kHz.
struct ExternalAudioChunk {
    let data: Data
    let frames: Int
    let channels: Int
    /// Host time (CLOCK_UPTIME_RAW ns) of the first sample frame.
    let hostNanos: UInt64
}

final class AudioInterfaceCapture: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Most channels written to the files (Scarlett Solo / 2i2: 2, 4i4: 4, 8i6: 6 …).
    static let maxChannels = 8

    @Published private(set) var devices: [AudioInterfaceDevice] = []
    /// Device that is running (nil = stopped).
    @Published private(set) var running: AudioInterfaceDevice?
    /// Level of each channel (dBFS), 10× per second.
    @Published private(set) var levelsDB: [Float] = []
    @Published private(set) var problem: String?

    /// Called on the capture queue for every buffer while running.
    var onAudio: ((ExternalAudioChunk) -> Void)?

    private let queue = DispatchQueue(label: "audio-interface", qos: .userInteractive)
    private var session: AVCaptureSession?
    /// Clock of the running session's buffer times (read on the capture queue).
    private let sessionClock = OSAllocatedUnfairLock<CMClock?>(uncheckedState: nil)
    private var wantedID: String?
    private var observers: [NSObjectProtocol] = []
    private let peaks = OSAllocatedUnfairLock(initialState: [Float]())
    private var meterTimer: Timer?

    override init() {
        super.init()
        refreshDevices()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.devicesChanged()
            })
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Number of channels the files get for the running device (0 when stopped).
    var channels: Int { running?.channels ?? 0 }

    // MARK: - Devices (main thread)

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                         mediaType: .audio, position: .unspecified)
        devices = discovery.devices.map { device in
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
            let count = Int(asbd?.mChannelsPerFrame ?? 2)
            return AudioInterfaceDevice(id: device.uniqueID, name: device.localizedName,
                                        channels: min(Self.maxChannels, max(1, count)))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func devicesChanged() {
        refreshDevices()
        guard let wantedID else { return }
        if let running, !devices.contains(where: { $0.id == running.id }) {
            stopSession()
            problem = "Audio interface \(running.name) was disconnected"
        } else if running == nil, devices.contains(where: { $0.id == wantedID }) {
            start(deviceID: wantedID)     // plugged in again
        }
    }

    // MARK: - Start / stop (main thread)

    /// Starts capturing from the device (stops a running one first). Asks for microphone access the first time.
    func start(deviceID: String) {
        wantedID = deviceID
        stopSession()
        problem = nil
        guard !deviceID.isEmpty else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted, self.wantedID == deviceID { self.start(deviceID: deviceID) }
                    else if !granted { self.problem = "No access to audio inputs – allow DualCamRecorder in System Settings → Privacy & Security → Microphone" }
                }
            }
            return
        default:
            problem = "No access to audio inputs – allow DualCamRecorder in System Settings → Privacy & Security → Microphone"
            return
        }
        refreshDevices()
        guard let info = devices.first(where: { $0.id == deviceID }),
              let device = AVCaptureDevice(uniqueID: deviceID) else {
            problem = "Audio interface is not connected"
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
        } catch {
            problem = "Cannot open \(info.name): \(error.localizedDescription)"
            return
        }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: info.channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            problem = "Cannot read audio from \(info.name)"
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        self.session = session
        sessionClock.withLockUnchecked { $0 = session.synchronizationClock }
        running = info
        peaks.withLock { $0 = Array(repeating: 0, count: info.channels) }
        levelsDB = Array(repeating: -120, count: info.channels)
        queue.async { session.startRunning() }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.publishLevels() }
    }

    /// Stops and forgets the device (project without an interface).
    func stop() {
        wantedID = nil
        stopSession()
        problem = nil
    }

    private func stopSession() {
        meterTimer?.invalidate()
        meterTimer = nil
        if let session {
            queue.async { session.stopRunning() }
        }
        session = nil
        running = nil
        levelsDB = []
    }

    private func publishLevels() {
        let p = peaks.withLock { p -> [Float] in
            defer { p = Array(repeating: 0, count: p.count) }
            return p
        }
        let db = p.map { $0 > 0 ? max(-120, 20 * log10($0)) : -120 }
        if db.count != levelsDB.count || zip(db, levelsDB).contains(where: { abs($0 - $1) >= 0.5 }) {
            levelsDB = db
        }
    }

    // MARK: - Capture (queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let asbd = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }),
              asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0 else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        let length = CMBlockBufferGetDataLength(block)
        guard channels > 0, length >= frames * channels * 4 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == noErr else { return }

        // Buffer time → host clock (the clock the DeckLink frames are stamped with).
        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let clock = sessionClock.withLockUnchecked({ $0 }) {
            pts = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        }
        let hostNanos = pts.isValid ? HostClock.nanos(seconds: pts.seconds) : HostClock.nowNanos

        // Peak of each channel for the meters.
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int32.self)
            peaks.withLock { p in
                if p.count != channels { p = Array(repeating: 0, count: channels) }
                for i in 0..<frames {
                    for c in 0..<channels {
                        let v = Float(abs(Int64(samples[i * channels + c]))) / Float(Int32.max)
                        if v > p[c] { p[c] = v }
                    }
                }
            }
        }
        onAudio?(ExternalAudioChunk(data: data, frames: frames, channels: channels, hostNanos: hostNanos))
    }
}
