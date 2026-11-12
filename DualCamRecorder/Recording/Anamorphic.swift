//
//  Anamorphic.swift
//  DualCamRecorder
//
//  Anamorphic lenses: the camera sends the squeezed picture over SDI. The app de-squeezes it on the Record tab
//  (PictureAdjuster) – the screen, the monitor, the phones and the recording get the de-squeezed picture in the
//  same frame size with black bars above and below.
//

import Foundation

enum Anamorphic {
    /// Choices per camera (1 = spherical lens, no de-squeeze).
    static let factors: [Double] = [1, 1.33, 1.5, 1.8, 2]

    /// "Off", "1.33×", "1.5×", "1.8×", "2×".
    static func title(_ factor: Double) -> String {
        guard factor > 1.001 else { return "Off" }
        var text = String(format: "%.2f", factor)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }
}
