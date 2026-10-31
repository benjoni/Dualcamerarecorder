//
//  PreviewView.swift
//  DualCamRecorder
//

import SwiftUI
import AppKit
import AVFoundation

/// Hosts a PreviewRenderer's AVSampleBufferDisplayLayer.
struct PreviewView: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.hostedLayer = renderer.displayLayer
        renderer.isActive = true
        return view
    }

    func updateNSView(_ nsView: LayerHostView, context: Context) {
        if nsView.hostedLayer !== renderer.displayLayer {
            nsView.hostedLayer = renderer.displayLayer
        }
    }

    static func dismantleNSView(_ nsView: LayerHostView, coordinator: ()) {
        nsView.hostedLayer = nil
    }
}

/// Plain layer-backed NSView that keeps a sublayer sized to its bounds.
final class LayerHostView: NSView {
    var hostedLayer: CALayer? {
        didSet {
            // Only detach the old layer if it is still ours – the shared preview layer may already
            // have moved to a newer view (e.g. when "screens only" is toggled).
            if let oldValue, oldValue !== hostedLayer, oldValue.superlayer === layer {
                oldValue.removeFromSuperlayer()
            }
            if let hostedLayer {
                layer?.addSublayer(hostedLayer)
                needsLayout = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = bounds
        CATransaction.commit()
    }
}
