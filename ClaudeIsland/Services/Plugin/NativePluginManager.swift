//
//  NativePluginManager.swift
//  ClaudeIsland
//
//  Discovers, loads, and manages native .bundle plugins from
//  ~/.config/codeisland/plugins/
//

import AppKit
import Combine
import OSLog

@MainActor
final class NativePluginManager: ObservableObject {
    static let shared = NativePluginManager()
    private static let log = Logger(subsystem: "com.codeisland.app", category: "NativePluginManager")

    @Published private(set) var loadedPlugins: [LoadedPlugin] = []

    struct LoadedPlugin: Identifiable {
        let id: String
        let name: String
        let icon: String
        let version: String
        let instance: MioPlugin
        let bundle: Bundle
    }

    private var pluginsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codeisland/plugins")
    }

    // MARK: - Loading

    func loadAll() {
        let fm = FileManager.default
        let dir = pluginsDir

        // Create plugins dir if needed
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Scan for .bundle files
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            Self.log.info("No plugins directory or empty")
            return
        }

        for url in contents where url.pathExtension == "bundle" {
            loadPlugin(at: url)
        }

        Self.log.info("Loaded \(self.loadedPlugins.count) native plugin(s)")
    }

    private func loadPlugin(at url: URL) {
        guard let bundle = Bundle(url: url) else {
            Self.log.warning("Failed to create bundle from \(url.lastPathComponent)")
            return
        }

        guard bundle.load() else {
            Self.log.warning("Failed to load bundle \(url.lastPathComponent)")
            return
        }

        guard let principalClass = bundle.principalClass as? (NSObject & MioPlugin).Type else {
            Self.log.warning("Bundle \(url.lastPathComponent) has no valid MioPlugin principal class")
            return
        }

        let instance = principalClass.init()
        guard let plugin = instance as? MioPlugin else {
            Self.log.warning("Principal class of \(url.lastPathComponent) does not conform to MioPlugin")
            return
        }

        // Check for duplicate IDs
        if loadedPlugins.contains(where: { $0.id == plugin.id }) {
            Self.log.warning("Duplicate plugin ID: \(plugin.id), skipping")
            return
        }

        plugin.activate()

        let loaded = LoadedPlugin(
            id: plugin.id,
            name: plugin.name,
            icon: plugin.icon,
            version: plugin.version,
            instance: plugin,
            bundle: bundle
        )
        loadedPlugins.append(loaded)
        Self.log.info("Loaded plugin: \(plugin.name) v\(plugin.version) (\(plugin.id))")
    }

    // MARK: - Unloading

    func unloadAll() {
        for plugin in loadedPlugins {
            plugin.instance.deactivate()
        }
        loadedPlugins.removeAll()
    }

    func unload(id: String) {
        guard let index = loadedPlugins.firstIndex(where: { $0.id == id }) else { return }
        loadedPlugins[index].instance.deactivate()
        loadedPlugins.remove(at: index)
        Self.log.info("Unloaded plugin: \(id)")
    }

    // MARK: - Install

    /// Install a .bundle file by copying it to the plugins directory.
    func install(bundleURL: URL) throws {
        let fm = FileManager.default
        let dest = pluginsDir.appendingPathComponent(bundleURL.lastPathComponent)

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: bundleURL, to: dest)

        // Load the newly installed plugin
        loadPlugin(at: dest)
    }

    /// Uninstall a plugin by removing its .bundle from disk.
    func uninstall(id: String) {
        guard let plugin = loadedPlugins.first(where: { $0.id == id }) else { return }
        unload(id: id)
        try? FileManager.default.removeItem(at: plugin.bundle.bundleURL)
        Self.log.info("Uninstalled plugin: \(id)")
    }

    // MARK: - Query

    func plugin(for id: String) -> LoadedPlugin? {
        loadedPlugins.first(where: { $0.id == id })
    }
}
