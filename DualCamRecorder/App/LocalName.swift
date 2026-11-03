//
//  LocalName.swift
//  DualCamRecorder
//
//  Fixed address for the live view: publishes "dualcam.local" (Bonjour / mDNS) for the Mac's current IPv4
//  addresses, so the link and QR code keep working when the router hands out a new IP. Re-published on every
//  network change. Until mDNS confirms the name – and when another Mac already uses it, or macOS does not allow
//  the app on the local network – the Mac's own name (Mac-mini.local) is used instead.
//

import Foundation
import Network
import SystemConfiguration
import dnssd

final class LocalName {
    static let preferred = "dualcam.local"

    /// Called on the main thread when the name changes (nil: no network).
    var onChange: ((String?) -> Void)?
    private(set) var name: String?

    private let queue = DispatchQueue(label: "local-name")
    private var connection: DNSServiceRef?
    private var monitor: NWPathMonitor?
    private var published: [String] = []
    private var conflict = false

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in self?.republish() }
        m.start(queue: queue)
        monitor = m
        queue.async { self.republish() }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        queue.async {
            self.unpublish()
            self.published = []
            self.conflict = false
        }
        setName(nil)
    }

    // MARK: - Publishing (queue only)

    private func republish() {
        guard monitor != nil else { return }
        let addresses = LiveViewServer.localIPv4Addresses()
        if addresses == published, connection != nil || conflict { return }
        unpublish()
        published = addresses
        guard !addresses.isEmpty else { setName(nil); return }
        setName(Self.macName())
        if conflict { return }

        var ref: DNSServiceRef?
        guard DNSServiceCreateConnection(&ref) == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        connection = ref
        let context = Unmanaged.passUnretained(self).toOpaque()
        for address in addresses {
            guard var ip = IPv4Address(address)?.rawValue else { continue }
            var record: DNSRecordRef?
            let err = ip.withUnsafeMutableBytes { bytes in
                DNSServiceRegisterRecord(ref, &record, DNSServiceFlags(kDNSServiceFlagsUnique), 0,
                                         Self.preferred + ".", UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                         UInt16(bytes.count), bytes.baseAddress, 120, Self.registered, context)
            }
            if err != kDNSServiceErr_NoError { failed(); return }
        }
    }

    private static let registered: DNSServiceRegisterRecordReply = { _, _, _, error, context in
        guard let context else { return }
        let me = Unmanaged<LocalName>.fromOpaque(context).takeUnretainedValue()
        if error == kDNSServiceErr_NoError {
            me.setName(LocalName.preferred)
        } else {
            me.conflict = error == kDNSServiceErr_NameConflict
            me.failed()
        }
    }

    /// Name taken or not allowed: the Mac's own name stays.
    private func failed() {
        unpublish()
        setName(Self.macName())
    }

    private func unpublish() {
        if let connection { DNSServiceRefDeallocate(connection) }
        connection = nil
    }

    private func setName(_ new: String?) {
        DispatchQueue.main.async {
            guard self.name != new else { return }
            self.name = new
            self.onChange?(new)
        }
    }

    /// "Mac-mini.local" – System Settings › General › Sharing › Local hostname.
    static func macName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }
}
