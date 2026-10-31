//
//  LiveViewServer.swift
//  DualCamRecorder
//
//  Live view for phones on the local network: a tiny HTTP server (Network.framework) that serves
//    /                 mobile web page (both cameras, REC state, slate)
//    /frame/A.jpg      latest JPEG of camera A (B likewise) – the page reloads them ~5× per second
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
    @Published private(set) var accessKey: String

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "liveview-server", qos: .utility)
    private struct Shared {
        var frames: [String: Data] = [:]
        var status = Data("{}".utf8)
        var clients: [String: Date] = [:]
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private var clientTimer: Timer?

    init() {
        if let key = UserDefaults.standard.string(forKey: "liveViewKey"), !key.isEmpty {
            accessKey = key
        } else {
            accessKey = Self.randomKey()
            UserDefaults.standard.set(accessKey, forKey: "liveViewKey")
        }
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
        clientTimer?.invalidate()
        clientTimer = nil
        isRunning = false
        clientCount = 0
        shared.withLock { $0.clients = [:]; $0.frames = [:] }
    }

    /// New key: links / QR codes given out before stop working.
    func regenerateKey() {
        accessKey = Self.randomKey()
        UserDefaults.standard.set(accessKey, forKey: "liveViewKey")
        shared.withLock { $0.clients = [:] }
    }

    /// True while at least one phone requested something in the last few seconds.
    var hasViewers: Bool {
        guard isRunning else { return false }
        let limit = Date().addingTimeInterval(-6)
        return shared.withLock { $0.clients.values.contains { $0 > limit } }
    }

    /// Addresses phones can open (one per active network interface).
    var urls: [String] {
        Self.localIPv4Addresses().map { "http://\($0):\(Self.port)/?k=\(accessKey)" }
    }

    // MARK: - Data from the app (any thread)

    func updateFrame(camera: String, jpeg: Data) {
        shared.withLock { $0.frames[camera] = jpeg }
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
            let response = self.respond(to: request, from: connection.endpoint)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func respond(to request: String, from endpoint: NWEndpoint) -> Data {
        // "GET /frame/A.jpg?k=abc&t=123 HTTP/1.1"
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return Self.http(405, "text/plain", Data("Method not allowed".utf8)) }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        let path = components?.path ?? "/"
        let key = components?.queryItems?.first(where: { $0.name == "k" })?.value

        guard key == accessKey else {
            return Self.http(403, "text/html; charset=utf-8",
                             Data("<h2 style='font-family:sans-serif'>DualCamRecorder – scan the QR code in the app to connect.</h2>".utf8))
        }
        if case .hostPort(let host, _) = endpoint {
            let client = "\(host)"
            shared.withLock { $0.clients[client] = Date() }
        }

        switch path {
        case "/", "/index.html":
            return Self.http(200, "text/html; charset=utf-8", Data(LiveViewPage.html.utf8))
        case "/status.json":
            return Self.http(200, "application/json", shared.withLock { $0.status })
        case "/frame/A.jpg", "/frame/B.jpg":
            let camera = path.contains("/A.") ? "A" : "B"
            if let jpeg = shared.withLock({ $0.frames[camera] }) {
                return Self.http(200, "image/jpeg", jpeg)
            }
            return Self.http(204, "text/plain", Data())
        default:
            return Self.http(404, "text/plain", Data("Not found".utf8))
        }
    }

    private static func http(_ code: Int, _ type: String, _ body: Data) -> Data {
        let reason = [200: "OK", 204: "No Content", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][code] ?? "OK"
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
</style>
</head><body>
<header><span id="rec">● REC</span><span id="timer">00:00:00</span><span id="project">DualCamRecorder</span></header>
<div id="offline">Connection to the Mac lost – retrying…</div>
<div id="slate"></div>
<div id="files"></div>
<main>
  <div class="cam" id="boxA"><img id="camA" alt=""><span class="label" id="nameA">A</span></div>
  <div class="cam" id="boxB"><img id="camB" alt=""><span class="label" id="nameB">B</span></div>
</main>
<script>
const k = new URLSearchParams(location.search).get('k');
function frame(cam){
  const img = document.getElementById('cam'+cam);
  const next = new Image();
  next.onload = () => { img.src = next.src; setTimeout(() => frame(cam), 200); };
  next.onerror = () => setTimeout(() => frame(cam), 1000);
  next.src = '/frame/' + cam + '.jpg?k=' + k + '&t=' + Date.now();
}
async function status(){
  try {
    const r = await fetch('/status.json?k=' + k + '&t=' + Date.now(), {cache:'no-store'});
    const s = await r.json();
    document.getElementById('offline').style.display = 'none';
    document.getElementById('rec').classList.toggle('on', !!s.recording);
    document.getElementById('timer').textContent = s.elapsed || '00:00:00';
    document.getElementById('project').textContent = s.project || 'DualCamRecorder';
    document.getElementById('slate').textContent = s.slate || '';
    document.getElementById('files').textContent = s.files || '';
    document.getElementById('nameA').textContent = s.nameA || 'A';
    document.getElementById('nameB').textContent = s.nameB || 'B';
    document.getElementById('boxB').classList.toggle('hidden', !s.twoCameras);
    document.getElementById('boxA').classList.toggle('rec', !!s.recording);
    document.getElementById('boxB').classList.toggle('rec', !!s.recording);
  } catch (e) {
    document.getElementById('offline').style.display = 'block';
  }
  setTimeout(status, 1000);
}
frame('A'); frame('B'); status();
</script>
</body></html>
"""#
}
