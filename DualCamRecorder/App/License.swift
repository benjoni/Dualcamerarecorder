//
//  License.swift
//  DualCamRecorder
//
//  Licence for one Mac with an expiry date (testers now, customers later). The licence is a small text file
//  (.dcrlicense) made with tools/make_license.swift from the Mac ID shown in the app, signed with Benjoni's
//  private key (Ed25519); the app only holds the public key, so a licence cannot be made or changed here.
//  Without a valid licence the app still opens projects, plays, edits and exports – only recording is blocked.
//  Release builds always need it; Debug builds only with -requireLicense YES (tests).
//

import Foundation
import CryptoKit
import IOKit

final class License: ObservableObject {
    static let shared = License()

    /// Public half of the signing key (tools/make_license.swift --show-public-key).
    private static let publicKey = "yT4BA0kHpaTEGncTmp1b7iWgnjMgpudIvWcyM3V1ReU="
    /// Days before the end when the app starts reminding.
    static let warningDays = 7

    enum State: Equatable {
        case missing
        case invalid(String)
        case otherMac
        case expired(Date)
        /// The Mac's clock is earlier than a time the app has already seen (set back).
        case clockSetBack
        case valid(name: String, expires: Date)
    }

    @Published private(set) var state = State.missing
    /// This Mac's ID (XXXX-XXXX-XXXX-XXXX) – sent to Benjoni to get a licence.
    let machineID: String

    let file: URL
    private let lastSeenKey = "licenseLastSeen"

    /// `file`: where the licence is installed (another place only for tests).
    init(file: URL? = nil) {
        machineID = Self.machineID()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.file = file ?? support.appendingPathComponent("DualCamRecorder/License.dcrlicense")
        refresh()
    }

    /// Release: always; Debug: only with -requireLicense YES.
    var isRequired: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "requireLicense")
        #else
        return true
        #endif
    }

    var isValid: Bool { if case .valid = state { return true } else { return false } }
    var allowsRecording: Bool { !isRequired || isValid }

    /// Days left, counting the day that has begun (a 30-day licence shows 30, its last day 1); nil without a
    /// valid licence.
    var daysLeft: Int? {
        guard case .valid(_, let expires) = state else { return nil }
        return max(1, Int(ceil(expires.timeIntervalSinceNow / 86_400)))
    }

    /// Shown instead of starting a take.
    var blockedMessage: String {
        switch state {
        case .expired: return "The license has expired – recording is off. DualCamRecorder → License…"
        case .clockSetBack: return "The Mac's date was set back – recording is off. Correct the date and time."
        default: return "No valid license for this Mac – recording is off. DualCamRecorder → License…"
        }
    }

    /// Reads and checks the installed licence (launch, before each take, after importing).
    func refresh() {
        let new = Self.check(file: file, machine: Self.normalized(machineID), lastSeenKey: lastSeenKey)
        if new != state { state = new }
    }

    /// Checks a licence file and installs it when it is for this Mac (also an expired one, so the
    /// window shows why). Returns a problem to show, or nil when installed and valid.
    func install(from url: URL) -> String? {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch { return "Cannot read \(url.lastPathComponent)." }
        switch Self.verify(text) {
        case .failure(let problem):
            return problem.message
        case .success(let payload):
            guard payload.machine == Self.normalized(machineID) else {
                return "This license is for another Mac (\(Self.formatted(payload.machine)))."
            }
            // An older licence file must not replace the one installed (e.g. last month's file opened by mistake).
            if let installed = Self.installedExpiry(file: file, machine: payload.machine),
               let new = ISO8601DateFormatter().date(from: payload.expires), new < installed {
                let shown = DateFormatter()
                shown.dateStyle = .medium
                shown.timeStyle = .short
                return "This license ends earlier (\(shown.string(from: new))) than the one installed "
                    + "(\(shown.string(from: installed))) – the installed license stays."
            }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                return "Cannot save the license: \(error.localizedDescription)"
            }
            refresh()
            switch state {
            case .valid: return nil
            case .expired: return "This license has already expired."
            case .clockSetBack: return "The Mac's date was set back – correct the date and time."
            default: return "The license could not be checked."
            }
        }
    }

    // MARK: - Checking

    struct Payload: Decodable {
        var v: Int
        var name: String
        var machine: String
        var issued: String
        var expires: String
    }

    enum Problem: Error {
        case format, signature, version
        var message: String {
            switch self {
            case .format: return "This is not a DualCamRecorder license file."
            case .signature: return "The license is damaged or was changed."
            case .version: return "This license needs a newer DualCamRecorder."
            }
        }
    }

    /// "DCR1.<payload>.<signature>" (base64url) – the signature over the payload's bytes.
    static func verify(_ text: String) -> Result<Payload, Problem> {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3, parts[0] == "DCR1",
              let json = base64url(parts[1]), let signature = base64url(parts[2]) else { return .failure(.format) }
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: json) else { return .failure(.signature) }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else { return .failure(.format) }
        guard payload.v == 1 else { return .failure(.version) }
        return .success(payload)
    }

    /// End of the installed licence when it is valid for this Mac (signature and machine checked).
    private static func installedExpiry(file: URL, machine: String) -> Date? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              case .success(let payload) = verify(text), payload.machine == machine else { return nil }
        return ISO8601DateFormatter().date(from: payload.expires)
    }

    private static func check(file: URL, machine: String, lastSeenKey: String) -> State {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .missing }
        let payload: Payload
        switch verify(text) {
        case .failure(let problem): return .invalid(problem.message)
        case .success(let p): payload = p
        }
        guard payload.machine == machine else { return .otherMac }
        guard let expires = ISO8601DateFormatter().date(from: payload.expires) else { return .invalid(Problem.format.message) }
        // The clock must not go back more than a day behind the latest time seen.
        let now = Date()
        let defaults = UserDefaults.standard
        let lastSeen = defaults.double(forKey: lastSeenKey)
        if lastSeen > 0, now.timeIntervalSince1970 < lastSeen - 86_400 { return .clockSetBack }
        if now.timeIntervalSince1970 > lastSeen { defaults.set(now.timeIntervalSince1970, forKey: lastSeenKey) }
        guard now < expires else { return .expired(expires) }
        return .valid(name: payload.name, expires: expires)
    }

    private static func base64url(_ part: Substring) -> Data? {
        var s = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    // MARK: - Mac ID

    /// 16 characters (0-9, A-Z without I L O U) from a hash of the Mac's hardware UUID – stays the same when
    /// macOS is reinstalled; the UUID itself is not shown.
    private static func machineID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = (IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String) ?? "unknown"
        let hash = Array(SHA256.hash(data: Data("DualCamRecorder-machine:\(uuid)".utf8)))
        // 80 bits → 16 characters of 5 bits.
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var bits = 0, value = 0, out = ""
        for byte in hash.prefix(10) {
            value = ((value << 8) | Int(byte)) & 0xFFFF; bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(value >> bits) & 31]) }
        }
        return formatted(out)
    }

    static func normalized(_ id: String) -> String { id.uppercased().filter { $0 != "-" && $0 != " " } }

    static func formatted(_ id: String) -> String {
        let chars = Array(normalized(id))
        return stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }
            .joined(separator: "-")
    }
}
