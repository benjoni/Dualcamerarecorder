//
//  LiveViewServer.swift
//  DualCamRecorder
//
//  Live view for phones on the local network: a tiny HTTP server (Network.framework) that serves
//    /                 mobile web page (both cameras, REC state, slate)
//    /stream/A.mjpg    MJPEG stream of camera A (B likewise) – every new JPEG is pushed to the phone
//    /frame/A.jpg      latest JPEG of camera A (B likewise), single picture
//    /status.json      recording state, timer, files, slate
//  Every request must carry the access key (?k=…) that is part of the URL / QR code.
//  Frames are produced by the PreviewRenderers only while a phone has asked for them recently.
//

import Foundation
import Network
import Combine
import os

final class LiveViewServer: ObservableObject {
    static let port: UInt16 = 8090

    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    @Published private(set) var clientCount = 0
    /// Crew code: watch only.
    @Published private(set) var accessKey: String
    /// Slate code: watch + change scene / shot / take / cards on the phone.
    @Published private(set) var editKey: String
    /// "dualcam.local" (or the Mac's own name) – stays the same when the IP address changes.
    @Published private(set) var hostName: String?
    /// Size / rate / JPEG quality of the pictures sent to phones (app-wide setting).
    @Published var quality: LiveViewQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "liveViewQuality") }
    }

    /// Slate field sent from the phone – "scene", "shot", "take", "cardA", "cardB" (called on the main thread);
    /// false = not accepted (recording or not a valid value).
    var onSetSlate: ((String, String) -> Bool)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "liveview-server", qos: .utility)
    private struct Shared {
        var frames: [String: Data] = [:]
        var status = Data("{}".utf8)
        var clients: [String: Date] = [:]
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private var clientTimer: Timer?
    private let localName = LocalName()

    /// Open MJPEG connections (server queue only). A phone that is still receiving the previous
    /// picture skips the next one, so a slow Wi-Fi never piles up delay.
    private final class StreamClient {
        let connection: NWConnection
        let camera: String
        let host: String?
        var sending = false
        init(connection: NWConnection, camera: String, host: String?) {
            self.connection = connection; self.camera = camera; self.host = host
        }
    }
    private var streams: [ObjectIdentifier: StreamClient] = [:]

    init() {
        quality = LiveViewQuality(rawValue: UserDefaults.standard.string(forKey: "liveViewQuality") ?? "") ?? .standard
        if let key = UserDefaults.standard.string(forKey: "liveViewKey"), !key.isEmpty {
            accessKey = key
        } else {
            accessKey = Self.randomKey()
            UserDefaults.standard.set(accessKey, forKey: "liveViewKey")
        }
        if let key = UserDefaults.standard.string(forKey: "liveViewEditKey"), !key.isEmpty, key != accessKey {
            editKey = key
        } else {
            editKey = Self.randomKey()
            UserDefaults.standard.set(editKey, forKey: "liveViewEditKey")
        }
        localName.onChange = { [weak self] name in self?.hostName = name }
    }

    // MARK: - Control (main thread)

    func start() {
        guard listener == nil else { return }
        error = nil
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed(let e):
                        self?.error = "Server failed: \(e.localizedDescription)"
                        self?.stop()
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
            localName.start()
            clientTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateClientCount()
            }
        } catch {
            self.error = "Cannot start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        localName.stop()
        clientTimer?.invalidate()
        clientTimer = nil
        isRunning = false
        clientCount = 0
        shared.withLock { $0.clients = [:]; $0.frames = [:] }
        queue.async { [weak self] in
            self?.streams.values.forEach { $0.connection.cancel() }
            self?.streams = [:]
        }
    }

    /// New crew (watch-only) code: its links / QR codes given out before stop working.
    func regenerateKey() {
        accessKey = Self.randomKey()
        UserDefaults.standard.set(accessKey, forKey: "liveViewKey")
        shared.withLock { $0.clients = [:] }
    }

    /// New slate code: phones with the old one can no longer change the slate (or watch).
    func regenerateEditKey() {
        editKey = Self.randomKey()
        UserDefaults.standard.set(editKey, forKey: "liveViewEditKey")
        shared.withLock { $0.clients = [:] }
    }

    /// Either code lets a phone watch (read on the server queue; the keys only change on the main thread).
    private func canWatch(_ key: String?) -> Bool {
        guard let key else { return false }
        return key == accessKey || key == editKey
    }

    /// True while at least one phone requested something in the last few seconds.
    var hasViewers: Bool {
        guard isRunning else { return false }
        let limit = Date().addingTimeInterval(-6)
        return shared.withLock { $0.clients.values.contains { $0 > limit } }
    }

    /// Address by name – the one for the QR code (nil: no network). `edit` = with the slate code.
    func nameURL(edit: Bool = false) -> String? {
        hostName.map { url($0, edit: edit) }
    }

    /// Addresses by IP (one per active network interface) – for phones that cannot open .local names.
    func ipURLs(edit: Bool = false) -> [String] {
        Self.localIPv4Addresses().map { url($0, edit: edit) }
    }

    private func url(_ host: String, edit: Bool) -> String {
        "http://\(host):\(Self.port)/?k=\(edit ? editKey : accessKey)"
    }

    // MARK: - Data from the app (any thread)

    func updateFrame(camera: String, jpeg: Data) {
        shared.withLock { $0.frames[camera] = jpeg }
        queue.async { [weak self] in self?.push(jpeg, camera: camera) }
    }

    func updateStatus(_ json: Data) {
        shared.withLock { $0.status = json }
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let (response, streamCamera) = self.respond(to: request, from: connection.endpoint)
            if let camera = streamCamera {
                self.openStream(connection, camera: camera, header: response)
            } else {
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    // MARK: - MJPEG (server queue)

    private static let boundary = "dualcamframe"

    private func openStream(_ connection: NWConnection, camera: String, header: Data) {
        var host: String?
        if case .hostPort(let h, _) = connection.endpoint { host = "\(h)" }
        let client = StreamClient(connection: connection, camera: camera, host: host)
        let id = ObjectIdentifier(client)
        streams[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.streams[id] = nil }
            default: break
            }
        }
        client.sending = true
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                client.sending = false
                if error != nil { connection.cancel(); return }
                // Start with the latest picture instead of waiting for the next one.
                if let jpeg = self?.shared.withLock({ $0.frames[camera] }) { self?.send(jpeg, to: client) }
            }
        })
    }

    private func push(_ jpeg: Data, camera: String) {
        for client in streams.values where client.camera == camera && !client.sending {
            send(jpeg, to: client)
        }
    }

    private func send(_ jpeg: Data, to client: StreamClient) {
        if let host = client.host { shared.withLock { $0.clients[host] = Date() } }
        var part = Data("--\(Self.boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        part.append(jpeg)
        part.append(Data("\r\n".utf8))
        client.sending = true
        client.connection.send(content: part, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                client.sending = false
                if error != nil { client.connection.cancel() }
            }
        })
    }

    private func respond(to request: String, from endpoint: NWEndpoint) -> (Data, streamCamera: String?) {
        (respondData(to: request, from: endpoint), streamCamera(in: request))
    }

    /// Camera of a valid "/stream/A.mjpg?k=…" request.
    private func streamCamera(in request: String) -> String? {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])),
              canWatch(components.queryItems?.first(where: { $0.name == "k" })?.value) else { return nil }
        switch components.path {
        case "/stream/A.mjpg": return "A"
        case "/stream/B.mjpg": return "B"
        default: return nil
        }
    }

    private func respondData(to request: String, from endpoint: NWEndpoint) -> Data {
        // "GET /frame/A.jpg?k=abc&t=123 HTTP/1.1"
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "POST" else {
            return Self.http(405, "text/plain", Data("Method not allowed".utf8))
        }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        let path = components?.path ?? "/"
        let key = components?.queryItems?.first(where: { $0.name == "k" })?.value

        guard canWatch(key) else {
            return Self.http(403, "text/html; charset=utf-8",
                             Data("<h2 style='font-family:sans-serif'>DualCamRecorder – scan the QR code in the app to connect.</h2>".utf8))
        }
        if case .hostPort(let host, _) = endpoint {
            let client = "\(host)"
            shared.withLock { $0.clients[client] = Date() }
        }

        // POST /slate?k=…&f=scene&v=12B – one slate field (scene, shot, take, cardA, cardB) typed on the phone.
        if parts[0] == "POST" {
            // Only the slate code may change the slate; the crew code just watches.
            guard key == editKey else {
                return Self.http(403, "text/plain", Data("View only".utf8))
            }
            let fields: Set<String> = ["scene", "shot", "take", "cardA", "cardB"]
            guard path == "/slate", let field = components?.queryItems?.first(where: { $0.name == "f" })?.value,
                  fields.contains(field) else {
                return Self.http(404, "text/plain", Data("Not found".utf8))
            }
            let raw = components?.queryItems?.first(where: { $0.name == "v" })?.value ?? ""
            let value = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
            let accepted = DispatchQueue.main.sync { onSetSlate?(field, value) ?? false }
            return accepted ? Self.http(200, "text/plain", Data("OK".utf8))
                            : Self.http(409, "text/plain", Data("Not accepted".utf8))
        }

        switch path {
        case "/", "/index.html":
            // The page knows whether its code may change the slate (taps on the slate fields).
            let page = LiveViewPage.html.replacingOccurrences(of: "__CAN_EDIT__", with: key == editKey ? "true" : "false")
            return Self.http(200, "text/html; charset=utf-8", Data(page.utf8))
        case "/status.json":
            return Self.http(200, "application/json", shared.withLock { $0.status })
        case "/frame/A.jpg", "/frame/B.jpg":
            let camera = path.contains("/A.") ? "A" : "B"
            if let jpeg = shared.withLock({ $0.frames[camera] }) {
                return Self.http(200, "image/jpeg", jpeg)
            }
            return Self.http(204, "text/plain", Data())
        case "/stream/A.mjpg", "/stream/B.mjpg":
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: multipart/x-mixed-replace; boundary=\(Self.boundary)\r\n"
            head += "Cache-Control: no-store\r\n"
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8)
        default:
            return Self.http(404, "text/plain", Data("Not found".utf8))
        }
    }

    private static func http(_ code: Int, _ type: String, _ body: Data) -> Data {
        let reason = [200: "OK", 204: "No Content", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                      409: "Conflict"][code] ?? "OK"
        var head = "HTTP/1.1 \(code) \(reason)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private func updateClientCount() {
        let limit = Date().addingTimeInterval(-6)
        let count = shared.withLock { s -> Int in
            s.clients = s.clients.filter { $0.value > limit.addingTimeInterval(-60) }
            return s.clients.values.filter { $0 > limit }.count
        }
        if count != clientCount { clientCount = count }
    }

    // MARK: - Helpers

    private static func randomKey() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    /// IPv4 addresses of active Wi-Fi / Ethernet interfaces (en0, en1 …).
    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { result.append(ip) }
            }
        }
        return result
    }
}

/// Pictures for phones: size, rate and JPEG quality. Higher settings need a faster Wi-Fi.
enum LiveViewQuality: String, CaseIterable, Identifiable {
    case low, standard, high

    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: return "Low"
        case .standard: return "Standard"
        case .high: return "High"
        }
    }
    var width: Int { switch self { case .low: return 640; case .standard: return 960; case .high: return 1280 } }
    var height: Int { width * 9 / 16 }
    var jpegQuality: Double { switch self { case .low: return 0.6; case .standard: return 0.75; case .high: return 0.8 } }
    var fps: Int { switch self { case .low: return 6; case .standard: return 12; case .high: return 15 } }
    /// Slightly shorter than 1/fps so a 25p source still gives every second frame.
    var frameIntervalNanos: UInt64 { UInt64(0.9e9 / Double(fps)) }
    var summary: String { "\(width)×\(height), up to \(fps) pictures per second" }
}

/// The phone web page (self-contained HTML + JS).
enum LiveViewPage {
    static let html = #"""
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>DualCamRecorder</title>
<style>
  html,body{margin:0;background:#000;color:#eee;font-family:-apple-system,system-ui,sans-serif}
  header{display:flex;align-items:center;gap:10px;padding:10px 12px;background:#161616;position:sticky;top:0}
  #rec{display:none;color:#fff;background:#e0201b;border-radius:5px;padding:2px 8px;font-weight:700;font-size:14px}
  #rec.on{display:inline-block;animation:blink 1s steps(2,start) infinite}
  @keyframes blink{50%{opacity:.35}}
  #timer{font:600 18px ui-monospace,Menlo,monospace}
  #project{font-weight:700;font-size:15px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #slate{padding:6px 12px;font-size:14px;color:#ccc;background:#111}
  #files{padding:0 12px 6px;font:11px ui-monospace,Menlo,monospace;color:#888;background:#111}
  main{display:flex;flex-direction:column;gap:6px;padding:6px}
  @media (orientation: landscape){ main{flex-direction:row} }
  .cam{position:relative;flex:1;background:#111;border:3px solid transparent;border-radius:6px;overflow:hidden}
  .cam.rec{border-color:#ff3b30}
  .cam img{display:block;width:100%;aspect-ratio:16/9;object-fit:contain;background:#000}
  .label{position:absolute;left:8px;top:6px;background:rgba(0,0,0,.6);padding:2px 7px;border-radius:4px;font-weight:700;font-size:13px}
  .hidden{display:none}
  #offline{display:none;padding:8px 12px;background:#5a1d1d;font-size:13px}
  .app{display:flex;align-items:center;gap:6px;color:#aaa;font-size:13px;font-weight:600;white-space:nowrap}
  .logo{height:16px;width:auto;flex:none}
  footer{display:flex;justify-content:space-between;align-items:center;padding:10px 12px calc(10px + env(safe-area-inset-bottom));color:#777;font-size:12px;font-weight:600}
  footer .app{color:#777;font-size:12px}
  #slateBtn{background:#2a2a2a;color:#eee;border:1px solid #444;border-radius:6px;padding:4px 10px;font:600 13px -apple-system,system-ui,sans-serif}
  #slateBtn.on{background:#eee;color:#000}
  /* Black clapperboard */
  #board{display:none;margin:6px;background:#0a0a0a;color:#fff;border:1px solid #555;border-radius:8px;padding:12px 14px;cursor:pointer;user-select:none}
  #board.on{display:block}
  #board.full{position:fixed;inset:0;margin:0;border:none;border-radius:0;z-index:10;display:flex;flex-direction:column;justify-content:center;
    padding:max(16px,env(safe-area-inset-top)) max(20px,env(safe-area-inset-right)) max(16px,env(safe-area-inset-bottom)) max(20px,env(safe-area-inset-left))}
  .sticks{height:16px;background:repeating-linear-gradient(-60deg,#fff 0 18px,#000 18px 36px);transform:rotate(-2deg);margin:2px 0 18px}
  #board.full .sticks{height:6vmin;background:repeating-linear-gradient(-60deg,#fff 0 7vmin,#000 7vmin 14vmin);margin-bottom:5vmin}
  .brow{display:flex;justify-content:space-between;gap:12px;align-items:baseline}
  .prod{font-weight:800;font-size:16px;text-transform:uppercase;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  /* Production as big as the scene number (made smaller only when the name does not fit the width) */
  .title{font:800 44px ui-rounded,-apple-system,system-ui,sans-serif;line-height:1.05;text-transform:uppercase;white-space:nowrap;overflow:hidden}
  #bTags{display:flex;flex-direction:column;align-items:flex-end}
  /* Production at the left in the room the DAY / INT / NIGHT column at the right leaves free. */
  .head{display:flex;flex-direction:row;align-items:flex-start;gap:max(16px,5vmin)}
  .head .title{flex:1;min-width:0}
  /* Every row uses the whole width: the cells share it equally. */
  .big{display:flex;gap:22px;margin:8px 0 6px}
  .big .cell,.people .cell{flex:1;min-width:0}
  .big .cell .v{overflow:hidden;display:flex;align-items:center}   /* a smaller number stays centered on the row */
  #board .people .v{white-space:normal;overflow-wrap:anywhere}   /* long names wrap instead of being cut */
  #board .tags{flex-direction:column;flex-wrap:nowrap;align-items:flex-end;gap:0}   /* INT / DAY / MOS … under each other, right under DAY */
  .cell .t{font:700 10px -apple-system,system-ui,sans-serif;color:#999;letter-spacing:.5px}
  .cell .v{font:800 44px ui-rounded,-apple-system,system-ui,sans-serif;line-height:1.05;white-space:nowrap}
  .tags{font-weight:800;font-size:16px;display:flex;gap:10px;flex-wrap:wrap;min-height:20px;margin-top:2px}
  .tags .reh{color:#000;background:#ff9500;border-radius:4px;padding:0 6px}
  .tags .good{color:#ffd60a}
  .people{display:flex;gap:22px;margin-top:8px}
  .people .v{font-weight:700;font-size:14px}
  .note{margin-top:6px;font-size:13px;color:#bbb}
  /* Cards above DAY at the right; a tap changes the number */
  #bCards{margin-bottom:4px;display:flex;flex-direction:column;align-items:flex-end}
  #bCards .card{white-space:nowrap;line-height:.95;margin:0}   /* both cards close together */
  #bCards .card + .card{margin-top:-1px}
  /* Editable fields: a tap changes them – only on the full-screen slate */
  #board.full .edit{cursor:pointer}
  #bCards .t{font:700 10px -apple-system,system-ui,sans-serif;color:#999;letter-spacing:.5px}
  /* Smaller than DAY / INT; no edit hint – a tap still changes the number */
  #bCards .v{font-weight:700;font-size:13px}
  #board.full #bCards .t{font-size:max(10px,2vmin)}
  #board.full #bCards .v{font-size:max(13px,3.2vmin)}
  /* The line height follows the card's own size (not DAY / INT's), so both cards sit tight together */
  #bCards{font-size:13px;line-height:1}
  #board.full #bCards{font-size:max(13px,3.2vmin)}
  #bCards .card{line-height:1}
  .hint{margin-top:8px;font-size:11px;color:#666}
  #board.full .prod{font-size:4.5vmin}
  #board.full .big{gap:min(6vmin,4vw);margin:3vmin 0 2vmin}
  #board.full .cell .t{font-size:max(11px,2.6vmin)}
  /* Scene · shot · take as big as the screen allows – never wider than their third of the screen. */
  #board.full .big .cell .v{font-size:min(30vmin,13vw)}
  #board.full .tags{font-size:max(18px,5vmin);min-height:6vmin}
  #board.full .people .v{font-size:max(16px,4.5vmin)}
  #board.full .note{font-size:3.5vmin}
  #board.full .hint{font-size:2.4vmin}
  /* Clap: countdown, then the whole screen white for one camera frame + a beep */
  #claps{display:none;margin-top:3vmin;gap:3vmin;flex-wrap:wrap}
  #board.full #claps{display:flex}
  .clap{background:#e0201b;color:#fff;border:none;border-radius:10px;
    padding:2.4vmin 6vmin;font:800 max(18px,5vmin) -apple-system,system-ui,sans-serif;letter-spacing:1px}
  .clap.one{background:#3a3a3a;border:2px solid #e0201b}
  /* Camera the clap is for (cameras far apart: one clap each) */
  #camTag{display:none;position:fixed;left:5vmin;bottom:5vmin;z-index:11;color:#fff;background:#e0201b;border-radius:2vmin;
    padding:1vmin 3vmin;font:800 14vmin ui-rounded,-apple-system,system-ui,sans-serif;line-height:1}
  #count{display:none;position:fixed;right:5vmin;bottom:5vmin;z-index:11;font:800 26vmin ui-rounded,-apple-system,system-ui,sans-serif;color:#e0201b;line-height:1}
  #flash{display:none;position:fixed;inset:0;background:#fff;z-index:20}
  /* Landscape (last, so it wins over the rules above) */
  @media (orientation: landscape){
    #board.full .big .cell .v{font-size:min(19vmin,13vw)}
    #board.full .big{margin:1.5vmin 0 1vmin}
    #board.full .sticks{margin-bottom:3vmin}
    #board.full #claps{margin-top:2vmin}
  }
</style>
</head><body>
<header><span id="rec">● REC</span><span id="timer">00:00:00</span><span id="project">DualCamRecorder</span><button id="slateBtn" type="button">Slate</button><span class="app"><svg class="logo" viewBox="0 0 294 245" fill="none" stroke="currentColor" stroke-width="16"><g id="bb"><path d="M169 0V245M169 8H244A42 42 0 0 1 286 50V51A42 42 0 0 1 244 93H169M169 152H244A42 42 0 0 1 286 194V195A42 42 0 0 1 244 237H169"/></g><use href="#bb" transform="matrix(-1 0 0 1 293 0)"/></svg>DualCamRecorder</span></header>
<div id="offline">Connection to the Mac lost – retrying…</div>
<div id="slate"></div>
<div id="board">
  <div class="sticks"></div>
  <div class="head">
    <div class="title" id="bProd">PRODUCTION</div>
    <div class="tags">
      <div id="bCards">
        <div class="card" id="bCardACell"><span class="t" id="bCardAT">CARD A</span> <span class="v" id="bCardA">–</span></div>
        <div class="card" id="bCardBCell"><span class="t" id="bCardBT">CARD B</span> <span class="v" id="bCardB">–</span></div>
      </div>
      <span class="prod" id="bDay"></span><span id="bTags"></span>
    </div>
  </div>
  <div class="big">
    <div class="cell"><div class="t">SCENE</div><div class="v" id="bScene">–</div></div>
    <div class="cell"><div class="t">SHOT</div><div class="v" id="bShot">–</div></div>
    <div class="cell"><div class="t">TAKE</div><div class="v" id="bTake">1</div></div>
  </div>
  <div class="people">
    <div class="cell"><div class="t">DIRECTOR</div><div class="v" id="bDir">–</div></div>
    <div class="cell"><div class="t">DOP</div><div class="v" id="bDop">–</div></div>
    <div class="cell"><div class="t">DATE</div><div class="v" id="bDate"></div></div>
  </div>
  <div class="note" id="bNote"></div>
  <div class="hint" id="bHint">Tap the slate for full screen</div>
  <div id="claps">
    <button class="clap" id="clapAll" type="button">CLAP</button>
    <button class="clap one" id="clapA" type="button">CLAP A</button>
    <button class="clap one" id="clapB" type="button">CLAP B</button>
  </div>
</div>
<div id="camTag"></div>
<div id="count"></div>
<div id="flash"></div>
<div id="files"></div>
<main>
  <div class="cam" id="boxA"><img id="camA" alt=""><span class="label" id="nameA">A</span></div>
  <div class="cam" id="boxB"><img id="camB" alt=""><span class="label" id="nameB">B</span></div>
</main>
<footer><span class="app"><svg class="logo" viewBox="0 0 294 245" fill="none" stroke="currentColor" stroke-width="16"><g id="bb2"><path d="M169 0V245M169 8H244A42 42 0 0 1 286 50V51A42 42 0 0 1 244 93H169M169 152H244A42 42 0 0 1 286 194V195A42 42 0 0 1 244 237H169"/></g><use href="#bb2" transform="matrix(-1 0 0 1 293 0)"/></svg>Made by BENJONI</span><span>DualCamRecorder</span></footer>
<script>
const k = new URLSearchParams(location.search).get('k');
// MJPEG: the Mac pushes every new picture over one open connection.
function stream(cam){
  const img = document.getElementById('cam'+cam);
  img.onerror = () => setTimeout(() => stream(cam), 1000);
  img.src = '/stream/' + cam + '.mjpg?k=' + k + '&t=' + Date.now();
}
function restartStreams(){ stream('A'); stream('B'); }
document.addEventListener('visibilitychange', () => { if (!document.hidden) restartStreams(); });
let offline = false;
async function status(){
  try {
    const r = await fetch('/status.json?k=' + k + '&t=' + Date.now(), {cache:'no-store'});
    const s = await r.json();
    if (offline) { offline = false; restartStreams(); }
    document.getElementById('offline').style.display = 'none';
    document.getElementById('rec').classList.toggle('on', !!s.recording);
    document.getElementById('rec').textContent = s.rehearsal ? '● REHEARSAL' : '● REC';
    document.getElementById('rec').style.background = s.rehearsal ? '#ff9500' : '#e0201b';
    document.getElementById('timer').textContent = s.elapsed || '00:00:00';
    document.getElementById('project').textContent = s.project || 'DualCamRecorder';
    document.getElementById('slate').textContent = s.slate || '';
    document.getElementById('files').textContent = s.files || '';
    fillBoard(s.board);
    if (s.frameMs) frameMs = s.frameMs;
    recording = !!s.recording;
    camNames = {A: s.nameA || 'A', B: s.nameB || 'B'};
    document.getElementById('clapA').textContent = 'CLAP ' + camNames.A;
    document.getElementById('clapB').textContent = 'CLAP ' + camNames.B;
    document.getElementById('clapB').style.display = s.twoCameras ? '' : 'none';
    document.getElementById('bCardAT').textContent = 'CARD ' + camNames.A;
    document.getElementById('bCardBT').textContent = 'CARD ' + camNames.B;
    document.getElementById('bCardBCell').style.display = s.twoCameras ? '' : 'none';
    document.getElementById('nameA').textContent = s.nameA || 'A';
    document.getElementById('nameB').textContent = s.nameB || 'B';
    document.getElementById('boxA').classList.toggle('hidden', s.showA === false);
    document.getElementById('boxB').classList.toggle('hidden', !s.twoCameras);
    document.getElementById('boxA').classList.toggle('rec', !!s.recording);
    document.getElementById('boxB').classList.toggle('rec', !!s.recording);
  } catch (e) {
    offline = true;
    document.getElementById('offline').style.display = 'block';
  }
  setTimeout(status, 1000);
}
// Black slate: the Slate button shows / hides it (remembered on this phone), a tap on it toggles full screen.
const board = document.getElementById('board');
const slateBtn = document.getElementById('slateBtn');
function setBoard(on){
  board.classList.toggle('on', on);
  slateBtn.classList.toggle('on', on);
  if (!on) board.classList.remove('full');
  fitTitle();
  try { localStorage.setItem('dcrSlate', on ? '1' : '0'); } catch (e) {}
}
slateBtn.onclick = () => setBoard(!board.classList.contains('on'));
board.onclick = () => {
  const full = !board.classList.contains('full');
  board.classList.toggle('full', full);
  fitTitle();
  document.getElementById('bHint').textContent = full ? 'Tap to close full screen' : 'Tap the slate for full screen';
};
try { setBoard(localStorage.getItem('dcrSlate') === '1'); } catch (e) {}

// Clap: hold the phone in front of the cameras, tap CLAP – 3 · 2 · 1 with short pips, then the screen is white
// for one camera frame together with a beep (sync point for picture and sound).
let frameMs = 40, clapping = false, audio = null;
function beep(atSeconds, freq, seconds){
  const o = audio.createOscillator(), g = audio.createGain();
  o.frequency.value = freq; o.type = 'sine';
  g.gain.setValueAtTime(0.9, atSeconds); g.gain.setValueAtTime(0, atSeconds + seconds);
  o.connect(g); g.connect(audio.destination);
  o.start(atSeconds); o.stop(atSeconds + seconds + 0.01);
}
// CLAP: both cameras at once. CLAP A / CLAP B: cameras far apart – one clap in front of each; the camera's
// name stays big on the screen during the countdown and the flash, so the editor sees which one it was.
let camNames = {A: 'A', B: 'B'}, cards = {A: '', B: ''}, recording = false;
// On the full-screen slate a tap on scene / shot / take / a card changes it (the script); not while recording.
// On the small slate a tap only opens full screen. A new scene or shot starts again at take 1 (as in the app).
let board_ = {};
async function editField(field, title, ev){
  if (!board.classList.contains('full')) return;   // the tap opens full screen instead
  ev.stopPropagation();
  if (recording) { alert('The slate cannot be changed while recording.'); return; }
  const current = field === 'cardA' ? cards.A : field === 'cardB' ? cards.B : String(board_[field] ?? '');
  const v = prompt(title, current);
  if (v === null) return;
  try {
    const r = await fetch('/slate?k=' + k + '&f=' + field + '&v=' + encodeURIComponent(v.trim()), {method:'POST', cache:'no-store'});
    if (r.ok) {
      // Shown at once; the next status (within a second) brings the app's values (e.g. take 1 after a new scene).
      const ids = {scene: 'bScene', shot: 'bShot', take: 'bTake', cardA: 'bCardA', cardB: 'bCardB'};
      document.getElementById(ids[field]).textContent = v.trim() || '–';
      if (field === 'cardA') cards.A = v.trim();
      if (field === 'cardB') cards.B = v.trim();
      fitTitle();
    }
    else if (recording) alert('The slate cannot be changed while recording.');
    else alert(field === 'take' ? 'Take must be a number 1–999.' : 'Could not change it.');
  } catch (e) { alert('No connection to the Mac.'); }
}
const editable = [['bScene', 'scene', () => 'Scene'], ['bShot', 'shot', () => 'Shot'], ['bTake', 'take', () => 'Take'],
                  ['bCardACell', 'cardA', () => 'Card number – camera ' + camNames.A],
                  ['bCardBCell', 'cardB', () => 'Card number – camera ' + camNames.B]];
// Only phones opened with the slate code can change it (crew code: view only).
const canEdit = __CAN_EDIT__;
if (canEdit) editable.forEach(([id, field, title]) => {
  const el = document.getElementById(id);
  el.classList.add('edit');
  el.onclick = (ev) => editField(field, title(), ev);
});
document.getElementById('clapAll').onclick = (ev) => { ev.stopPropagation(); clap(''); };
document.getElementById('clapA').onclick = (ev) => { ev.stopPropagation(); clap('A'); };
document.getElementById('clapB').onclick = (ev) => { ev.stopPropagation(); clap('B'); };
function clap(cam){
  if (clapping) return;
  clapping = true;
  const camTag = document.getElementById('camTag');
  camTag.textContent = cam ? 'CAM ' + camNames[cam] + (cards[cam] ? ' · ' + cards[cam] : '') : '';
  camTag.style.display = cam ? 'block' : 'none';
  const claps = document.getElementById('claps');
  claps.style.visibility = 'hidden';   // the camera's name / countdown take the place of the buttons
  try { audio = audio || new (window.AudioContext || window.webkitAudioContext)(); audio.resume(); } catch (e) { audio = null; }
  const count = document.getElementById('count'), flash = document.getElementById('flash');
  const start = performance.now();
  // Audio is scheduled on its own clock; the device's output latency is taken off so the beep leaves the
  // speaker when the screen turns white.
  if (audio) {
    const t0 = audio.currentTime, lat = audio.outputLatency || audio.baseLatency || 0;
    for (let i = 0; i < 3; i++) beep(t0 + i, 880, 0.08);
    beep(Math.max(t0, t0 + 3 - lat), 1000, frameMs / 1000);
  }
  [3, 2, 1].forEach((n, i) => setTimeout(() => { count.textContent = n; count.style.display = 'block'; }, i * 1000));
  setTimeout(() => {
    count.style.display = 'none';
    requestAnimationFrame(() => {
      flash.style.display = 'block';
      const on = performance.now();
      let done = false;
      const end = () => { if (!done) { done = true; flash.style.display = 'none'; clapping = false;
        setTimeout(() => { if (!clapping) { camTag.style.display = 'none'; claps.style.visibility = ''; } }, 1500); } };
      const off = () => { if (done) return; if (performance.now() - on >= frameMs) end(); else requestAnimationFrame(off); };
      requestAnimationFrame(off);
      setTimeout(end, frameMs + 5);   // also when the screen is not redrawn in time
    });
  }, 3000 - (performance.now() - start));
}
function fillBoard(b){
  if (!b) return;
  board_ = b;
  const set = (id, v) => { document.getElementById(id).textContent = v; };
  set('bProd', (b.production || 'PRODUCTION').toUpperCase());
  set('bDay', b.day ? 'DAY ' + b.day : '');
  set('bScene', b.scene || '–');
  set('bShot', b.shot || '–');
  set('bTake', String(b.take || 1));
  set('bDir', b.director || '–');
  set('bDop', b.dop || '–');
  set('bDate', b.date || '');
  set('bNote', b.note || '');
  cards = {A: b.cardA || '', B: b.cardB || ''};
  set('bCardA', cards.A || '–');
  set('bCardB', cards.B || '–');
  // (the card row always shows: a tap on a card changes it)
  const tags = document.getElementById('bTags');
  tags.textContent = '';
  const add = (text, cls) => { const s = document.createElement('span'); s.textContent = text; if (cls) s.className = cls; tags.appendChild(s); };
  if (b.location) add(b.location);
  if (b.time) add(b.time);
  if (b.mos) add('MOS');
  if (b.good) add('★ GOOD', 'good');
  if (b.rehearsal) add('REHEARSAL', 'reh');
  fitTitle();
}
// Every field keeps its normal size and gets smaller only as far as needed to fit its own room
// (e.g. scene "12B+13" in its third of the width), never below a readable size.
function shrinkToFit(el, size, min){
  el.style.fontSize = size + 'px';
  while (el.scrollWidth > el.clientWidth + 1 && size > min) { size -= 1; el.style.fontSize = size + 'px'; }
}
function fitTitle(){
  const nums = ['bScene', 'bShot', 'bTake'].map(id => document.getElementById(id));
  nums.forEach(n => { n.style.fontSize = ''; n.style.height = ''; });
  const numSize = parseFloat(getComputedStyle(nums[0]).fontSize) || 44;
  nums.forEach(n => { n.style.height = Math.ceil(numSize * 1.05) + 'px'; shrinkToFit(n, numSize, 14); });
  // Production: at most 3/4 of the scene number's size, in the room left of DAY / INT / NIGHT.
  shrinkToFit(document.getElementById('bProd'), Math.round(numSize * 0.75), 12);
}
window.addEventListener('resize', fitTitle);
restartStreams(); status();
</script>
</body></html>
"""#
}
