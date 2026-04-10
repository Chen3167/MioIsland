//
//  NativePluginStoreView.swift
//  ClaudeIsland
//
//  Plugin management UI in System Settings. Shows loaded native
//  plugins and allows installing .bundle files.
//

import SwiftUI
import UniformTypeIdentifiers

struct NativePluginStoreView: View {
    @ObservedObject private var manager = NativePluginManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Installed Plugins")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button {
                    installFromFinder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                        Text("Install .bundle")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }

            if manager.loadedPlugins.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.2))
                    Text("No plugins installed")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Drop a .bundle file into ~/.config/codeisland/plugins/")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(manager.loadedPlugins) { plugin in
                    pluginRow(plugin)
                }
            }

            Spacer()

            Text("~/.config/codeisland/plugins/")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
        }
        .padding(20)
    }

    private func pluginRow(_ plugin: NativePluginManager.LoadedPlugin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: plugin.icon)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Text("v\(plugin.version)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            Button {
                manager.uninstall(id: plugin.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    private func installFromFinder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.bundle]
        panel.message = "Select a MioIsland plugin .bundle"
        panel.prompt = "Install"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? manager.install(bundleURL: url)
    }
}
