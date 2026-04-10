//
//  MioPlugin.swift
//  ClaudeIsland
//
//  Native plugin protocol. Plugins are compiled .bundle files
//  that implement this protocol. Full access to app internals —
//  no sandbox, no restrictions. All plugins are reviewed before
//  distribution.
//

import AppKit

/// Protocol that all native MioIsland plugins must implement.
/// The principal class of the .bundle must conform to this protocol.
@objc protocol MioPlugin: AnyObject {
    /// Unique plugin identifier (kebab-case)
    var id: String { get }
    /// Display name
    var name: String { get }
    /// SF Symbol name for the plugin icon
    var icon: String { get }
    /// Plugin version (semver)
    var version: String { get }

    /// Called when the plugin is loaded. Use this to set up state,
    /// register observers, etc.
    func activate()

    /// Called when the plugin is unloaded or the app quits.
    func deactivate()

    /// Return the plugin's main NSView. This view will be displayed
    /// in the notch panel when the user selects this plugin.
    /// Use NSHostingView to wrap SwiftUI views.
    func makeView() -> NSView
}
