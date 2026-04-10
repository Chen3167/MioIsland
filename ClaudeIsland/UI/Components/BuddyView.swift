//
//  BuddyView.swift
//  ClaudeIsland
//
//  Wrapper that renders either the built-in PixelCharacterView
//  or a plugin PluginBuddyView based on the active buddyId.
//

import SwiftUI

struct BuddyView: View {
    let state: AnimationState

    private var buddyId: String {
        NotchCustomizationStore.shared.customization.buddyId
    }

    var body: some View {
        if buddyId == "pixel-cat",
           let def = BuddyRegistry.shared.definition(for: buddyId),
           def.isBuiltIn {
            PixelCharacterView(state: state)
        } else if let def = BuddyRegistry.shared.definition(for: buddyId) {
            PluginBuddyView(definition: def, state: state)
        } else {
            // Fallback to built-in
            PixelCharacterView(state: state)
        }
    }
}
