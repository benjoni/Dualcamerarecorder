//
//  PlayerView.swift
//  DualCamRecorder
//

import SwiftUI
import AVFoundation

/// Bare AVPlayerLayer (no system controls – transport is shared between both players).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        view.hostedLayer = layer
        return view
    }

    func updateNSView(_ nsView: LayerHostView, context: Context) {
        if let layer = nsView.hostedLayer as? AVPlayerLayer, layer.player !== player {
            layer.player = player
        }
    }
}
