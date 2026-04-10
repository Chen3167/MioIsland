//
//  PluginBuddyView.swift
//  ClaudeIsland
//
//  Canvas-based renderer for plugin buddy characters using
//  indexed bitmap frame data. Supports up to 8-color palette
//  with per-state multi-frame animation.
//

import SwiftUI

struct PluginBuddyView: View {
    let definition: BuddyDefinition
    let state: AnimationState
    @State private var frameIndex = 0
    @State private var lastAdvance = Date()

    private var stateKey: String {
        switch state {
        case .idle:     return "idle"
        case .working:  return "working"
        case .needsYou: return "needsYou"
        case .thinking: return "thinking"
        case .error:    return "error"
        case .done:     return "done"
        }
    }

    private var currentFrames: [FrameData] {
        definition.frames[stateKey] ?? definition.frames["idle"] ?? []
    }

    private var canvasWidth: CGFloat {
        CGFloat(definition.grid.width * definition.grid.cellSize)
    }

    private var canvasHeight: CGFloat {
        CGFloat(definition.grid.height * definition.grid.cellSize)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            Canvas { context, _ in
                let frames = currentFrames
                guard !frames.isEmpty else { return }
                let frame = frames[frameIndex % frames.count]
                drawFrame(context: &context, frame: frame)
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .onChange(of: timeline.date) { _, now in
                advanceFrameIfNeeded(now: now)
            }
        }
        .onChange(of: stateKey) { _, _ in
            frameIndex = 0
        }
    }

    private func drawFrame(context: inout GraphicsContext, frame: FrameData) {
        let cellSize = CGFloat(definition.grid.cellSize)
        let width = definition.grid.width
        let colors = definition.palette.compactMap { Color(hex: $0) }

        for y in 0..<definition.grid.height {
            for x in 0..<width {
                let pixelIndex = y * width + x
                let byteIndex = pixelIndex / 2
                guard byteIndex < frame.pixels.count else { continue }
                let byte = frame.pixels[byteIndex]
                // High nibble for even pixels, low nibble for odd
                let colorIndex: UInt8 = (pixelIndex % 2 == 0)
                    ? (byte >> 4) & 0x0F
                    : byte & 0x0F
                // 0 = transparent, 1-8 = palette index
                guard colorIndex > 0, Int(colorIndex) - 1 < colors.count else { continue }
                let color = colors[Int(colorIndex) - 1]
                let rect = CGRect(
                    x: CGFloat(x) * cellSize,
                    y: CGFloat(y) * cellSize,
                    width: cellSize,
                    height: cellSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    private func advanceFrameIfNeeded(now: Date) {
        let frames = currentFrames
        guard !frames.isEmpty else { return }
        let current = frames[frameIndex % frames.count]
        let elapsed = now.timeIntervalSince(lastAdvance) * 1000 // ms
        if elapsed >= Double(current.duration) {
            frameIndex = (frameIndex + 1) % frames.count
            lastAdvance = now
        }
    }
}
