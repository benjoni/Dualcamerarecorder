//
//  HostClock.swift
//  DualCamRecorder
//

import Foundation
import CoreMedia

/// Shared host clock (CLOCK_UPTIME_RAW in nanoseconds) – the same clock the DeckLink bridge
/// converts hardware timestamps to, so frames from different devices are comparable.
enum HostClock {
    static var nowNanos: UInt64 { DLHostTimeNanos() }

    static func nanos(_ time: CMTime) -> Int64 {
        guard time.isValid, time.timescale > 0 else { return 0 }
        return Int64((Double(time.value) / Double(time.timescale) * 1_000_000_000).rounded())
    }

    static func nanos(seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}
