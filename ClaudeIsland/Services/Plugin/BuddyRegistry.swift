//
//  BuddyRegistry.swift
//  ClaudeIsland
//
//  Runtime registry for buddy characters. Built-in pixel cat
//  uses procedural rendering; plugin buddies use bitmap frames.
//

import Combine
import Foundation

struct BuddyDefinition: Identifiable, Equatable {
    let id: String
    let name: String
    let grid: GridSpec
    let palette: [String]               // hex colors, max 8
    let frames: [String: [FrameData]]   // animationState key -> frames
    let isBuiltIn: Bool

    static func == (lhs: BuddyDefinition, rhs: BuddyDefinition) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isBuiltIn == rhs.isBuiltIn
    }

    static let builtInCat = BuddyDefinition(
        id: "pixel-cat",
        name: "Pixel Cat",
        grid: GridSpec(width: 13, height: 11, cellSize: 4),
        palette: [],
        frames: [:],    // built-in uses procedural rendering
        isBuiltIn: true
    )
}

struct FrameData: Equatable {
    let duration: Int       // ms
    let pixels: Data        // decoded 4-bit indexed bitmap
}

@MainActor
final class BuddyRegistry: ObservableObject {
    static let shared = BuddyRegistry()

    @Published private(set) var buddies: [BuddyDefinition] = []

    init() {
        buddies = [BuddyDefinition.builtInCat]
    }

    func register(_ buddy: BuddyDefinition) {
        buddies.removeAll { $0.id == buddy.id }
        buddies.append(buddy)
    }

    func unregister(_ id: String) {
        buddies.removeAll { $0.id == id && !$0.isBuiltIn }
    }

    func definition(for id: String) -> BuddyDefinition? {
        buddies.first(where: { $0.id == id })
    }
}
