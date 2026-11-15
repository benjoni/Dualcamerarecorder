// make_license.swift – makes a DualCamRecorder licence for one Mac.
//
// Usage (from the repository root):
//   swift tools/make_license.swift --name "Jan Novak" --mac ABCD-EFGH-JKMN-PQRS --days 30
//       → "DualCamRecorder License – Jan Novak.dcrlicense" on the Desktop (send it to the tester)
//   swift tools/make_license.swift --show-public-key
//
// The tester's Mac ID is shown in the app (DualCamRecorder → License…). The licence is valid on that Mac only,
// for the given number of days from now.
//
// Signing key: ~/Library/Application Support/DualCamRecorder License Key/private.key – created on the first run,
// NEVER in the repository. Back it up (password manager): without it no new licences can be made for the
// released app. Its public half is License.publicKey in DualCamRecorder/App/License.swift.

import Foundation
import CryptoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - Key

let keyFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/DualCamRecorder License Key", isDirectory: true)
let keyFile = keyFolder.appendingPathComponent("private.key")

func signingKey() -> Curve25519.Signing.PrivateKey {
    if let text = try? String(contentsOf: keyFile, encoding: .utf8),
       let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("\(keyFile.path) is not a valid key") }
        return key
    }
    let key = Curve25519.Signing.PrivateKey()
    do {
        try FileManager.default.createDirectory(at: keyFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try key.rawRepresentation.base64EncodedString().write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    } catch {
        fail("cannot save the key: \(error.localizedDescription)")
    }
    FileHandle.standardError.write(Data("New signing key saved to \(keyFile.path) – back it up.\n".utf8))
    return key
}

// MARK: - Arguments

var name = "", mac = "", days = 0, showPublicKey = false
var outFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--name": name = args.next() ?? ""
    case "--mac": mac = args.next() ?? ""
    case "--days": days = Int(args.next() ?? "") ?? 0
    case "--out": outFolder = URL(fileURLWithPath: args.next() ?? ".", isDirectory: true)
    case "--show-public-key": showPublicKey = true
    default: fail("unknown argument \(arg)")
    }
}

let key = signingKey()
if showPublicKey {
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

// Mac ID as shown in the app: 16 characters of 0-9 A-Z without I L O U, dashes and case ignored.
let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
let machine = mac.uppercased().filter { $0 != "-" && $0 != " " }
guard machine.count == 16, machine.allSatisfy({ allowed.contains($0) }) else {
    fail("--mac must be the Mac ID from the app, e.g. ABCD-EFGH-JKMN-PQRS")
}
let trimmedName = name.trimmingCharacters(in: .whitespaces)
guard !trimmedName.isEmpty else { fail("--name is missing") }
guard (1...36_500).contains(days) else { fail("--days must be 1 … 36500") }

// MARK: - Licence

let iso = ISO8601DateFormatter()
let now = Date()
let expires = now.addingTimeInterval(TimeInterval(days) * 86_400)
let payload: [String: Any] = ["v": 1, "name": trimmedName, "machine": machine,
                              "issued": iso.string(from: now), "expires": iso.string(from: expires)]
let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
let signature = try key.signature(for: json)
let licence = "DCR1.\(base64url(json)).\(base64url(signature))\n"

let safeName = trimmedName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
let out = outFolder.appendingPathComponent("DualCamRecorder License – \(safeName).dcrlicense")
do {
    try licence.write(to: out, atomically: true, encoding: .utf8)
} catch {
    fail("cannot write \(out.path): \(error.localizedDescription)")
}
let shown = DateFormatter()
shown.dateStyle = .medium
shown.timeStyle = .short
let shownID = stride(from: 0, to: 16, by: 4).map { String(Array(machine)[$0..<$0 + 4]) }.joined(separator: "-")
print("Licence for \(trimmedName), Mac \(shownID), \(days) days – valid until \(shown.string(from: expires))")
print(out.path)
