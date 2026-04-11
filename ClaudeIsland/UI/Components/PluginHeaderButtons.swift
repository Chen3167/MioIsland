//
//  PluginHeaderButtons.swift
//  ClaudeIsland
//
//  Native SwiftUI buttons for loaded plugins in the instances header.
//  Each plugin gets an icon button based on its `icon` property.
//  Hover: fluorescent pink, scale up, hand cursor.
//

import SwiftUI

struct PluginHeaderButtons: View {
    let viewModel: NotchViewModel
    @ObservedObject private var manager = NativePluginManager.shared

    var body: some View {
        ForEach(manager.loadedPlugins) { plugin in
            PluginHeaderButton(plugin: plugin, viewModel: viewModel)
        }
    }
}

private struct PluginHeaderButton: View {
    let plugin: NativePluginManager.LoadedPlugin
    let viewModel: NotchViewModel

    var body: some View {
        HeaderIconButton(icon: plugin.icon) {
            viewModel.showPlugin(plugin.id)
        }
    }
}

/// Reusable header icon button with hover effects.
/// Used for both plugin buttons and the settings gear.
struct HeaderIconButton: View {
    let icon: String
    var hoverColor: Color = Color(red: 1.0, green: 0.4, blue: 0.6) // fluorescent pink default
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(isHovered ? hoverColor : .white.opacity(0.5))
                .scaleEffect(isHovered ? 1.2 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
