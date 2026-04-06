//
//  TerminalWriter.swift
//  ClaudeIsland
//
//  Sends text to a Claude Code terminal session.
//  Used by the sync module to relay messages from the phone.
//

import Foundation
import AppKit
import os.log

/// Sends text input to a Claude Code terminal session.
@MainActor
final class TerminalWriter {

    static let logger = Logger(subsystem: "com.codeisland", category: "TerminalWriter")
    static let shared = TerminalWriter()

    private let cmuxPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"

    private init() {}

    /// Send a text message to the terminal running the given session.
    func sendText(_ text: String, to session: SessionState) async -> Bool {
        let termApp = session.terminalApp?.lowercased() ?? ""

        // Try cmux first (most precise)
        if FileManager.default.isExecutableFile(atPath: cmuxPath) {
            if await sendViaCmux(text, session: session) {
                return true
            }
        }

        // Try AppleScript for known terminals
        if termApp.contains("iterm") {
            return sendViaAppleScript(text, script: """
                tell application "iTerm2"
                    tell current session of current tab of current window
                        write text "\(text.replacingOccurrences(of: "\"", with: "\\\""))"
                    end tell
                end tell
                """)
        }

        if termApp.contains("ghostty") {
            // Ghostty: use keystroke via System Events
            return sendViaAppleScript(text, script: """
                tell application "Ghostty" to activate
                delay 0.3
                tell application "System Events"
                    keystroke "\(text.replacingOccurrences(of: "\"", with: "\\\""))"
                    key code 36
                end tell
                """)
        }

        if termApp.contains("terminal") && !termApp.contains("wez") {
            return sendViaAppleScript(text, script: """
                tell application "Terminal"
                    do script "\(text.replacingOccurrences(of: "\"", with: "\\\""))" in selected tab of front window
                end tell
                """)
        }

        Self.logger.warning("No supported terminal for session \(session.sessionId.prefix(8))")
        return false
    }

    /// Send text directly via cmux using a Claude session UUID + cwd, without needing
    /// a SessionState in SessionStore. Used when phone sends a message to a session
    /// CodeIsland isn't currently tracking locally.
    func sendTextDirect(_ text: String, claudeUuid: String, cwd: String?) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: cmuxPath) else {
            Self.logger.warning("cmux not found at \(self.cmuxPath)")
            return false
        }
        return await sendViaCmuxDirect(text, claudeUuid: claudeUuid, cwd: cwd)
    }

    /// Paste one or more images into the terminal running the given Claude session,
    /// then send any accompanying text. Uses NSPasteboard + CGEvent Cmd+V via cmux focus.
    /// Returns true if at least the focusing + paste attempts succeeded.
    func sendImagesAndText(images: [Data], text: String, claudeUuid: String) async -> Bool {
        guard let (wsId, surfId) = findCmuxTargetForClaudeSession(uuid: claudeUuid) else {
            Self.logger.warning("sendImagesAndText: no claude process for uuid=\(claudeUuid.prefix(8))")
            return false
        }
        guard let surfId else {
            Self.logger.warning("sendImagesAndText: missing surface id for uuid=\(claudeUuid.prefix(8))")
            return false
        }

        // Accessibility self-check — CGEvent and System Events keystrokes both
        // silently fail without this permission.
        let axTrusted = AXIsProcessTrusted()
        Self.logger.info("Accessibility trusted=\(axTrusted)")

        // 1. Switch cmux internally to the target surface. `focus-panel` is the
        //    correct command — cmux calls surfaces "panels" in CLI-speak.
        _ = cmuxRun(["focus-panel", "--panel", surfId, "--workspace", wsId])

        // 2. Bring cmux.app to the foreground. AppleScript is more reliable than
        //    NSRunningApplication here (the latter sometimes fails to locate cmux).
        _ = runOsascript(#"tell application id "com.cmuxterm.app" to activate"#)

        // Wait up to 1s for cmux to actually become frontmost.
        var frontOk = false
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.cmuxterm.app" {
                frontOk = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        Self.logger.info("cmux frontmost=\(frontOk)")

        // Extra settle time after cmux is frontmost.
        try? await Task.sleep(nanoseconds: 200_000_000)

        for (idx, imgData) in images.enumerated() {
            writeImageToPasteboard(imgData)
            // Ensure pasteboard is settled before firing the key.
            try? await Task.sleep(nanoseconds: 120_000_000)
            // Use AppleScript keystroke as the primary path — it's more reliable than
            // raw CGEvent in many window server configurations. Fall back to CGEvent.
            if !postCmdVViaAppleScript() {
                Self.logger.info("AppleScript paste failed, falling back to CGEvent")
                postCmdV()
            }
            // Delay between multi-image pastes so Claude can ingest each.
            if idx < images.count - 1 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }

        // Settle before sending the accompanying text so it doesn't race the paste.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Text goes through cmux's own channel (bypasses the pasteboard path).
        let trailing = text.isEmpty
            ? "\r"
            : "\(text.replacingOccurrences(of: "\n", with: "\r"))\r"
        _ = cmuxRun(["send", "--workspace", wsId, "--surface", surfId, "--", trailing])

        Self.logger.info("Pasted \(images.count) image(s) + text via cmux (ws=\(wsId.prefix(8)) surf=\(surfId.prefix(8)))")
        return true
    }

    /// Place raw image bytes on the general pasteboard in the formats most terminals
    /// expect. We use the native format (jpeg/png) and also include TIFF as a lingua
    /// franca fallback.
    nonisolated private func writeImageToPasteboard(_ data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // Decode so we can emit a TIFF representation too.
        guard let image = NSImage(data: data) else {
            // Fallback: just stamp the raw bytes under a guess.
            pb.setData(data, forType: NSPasteboard.PasteboardType("public.jpeg"))
            return
        }

        // Write NSImage first — terminals that register for image types pick this up.
        pb.writeObjects([image])

        // Also write the raw bytes under both jpeg and tiff types for maximum compat.
        pb.setData(data, forType: NSPasteboard.PasteboardType("public.jpeg"))
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    /// Post a Cmd+V key event via CGEvent. Requires Accessibility permission on macOS.
    nonisolated private func postCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9 // "V"
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        cmdUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

    /// Simulate Cmd+V via AppleScript System Events. Returns true on success.
    nonisolated private func postCmdVViaAppleScript() -> Bool {
        return runOsascript(#"tell application "System Events" to keystroke "v" using {command down}"#)
    }

    @discardableResult
    nonisolated private func runOsascript(_ script: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func sendViaCmuxDirect(_ text: String, claudeUuid: String, cwd: String?) async -> Bool {
        // Strategy: find the running Claude process with `--session-id <claudeUuid>` on its
        // argv, then read its CMUX_WORKSPACE_ID / CMUX_SURFACE_ID env vars. This is 100%
        // deterministic — no string fuzz-matching against titles or cwds.
        guard let (wsId, surfId) = findCmuxTargetForClaudeSession(uuid: claudeUuid) else {
            Self.logger.warning("No running claude process with --session-id=\(claudeUuid.prefix(8)) — session is orphaned or on another machine")
            return false
        }

        let escaped = text.replacingOccurrences(of: "\n", with: "\r")
        var args = ["send"]
        args += ["--workspace", wsId]
        if let surfId { args += ["--surface", surfId] }
        args += ["--", "\(escaped)\r"]
        guard cmuxRun(args) != nil else {
            Self.logger.error("cmux send failed for workspace=\(wsId)")
            return false
        }
        Self.logger.info("Sent message via cmux (workspace=\(wsId.prefix(8)) surface=\(surfId?.prefix(8).description ?? "-"))")
        return true
    }

    /// Walk the process list, find a `claude` process invoked with `--session-id <uuid>`,
    /// then read its env via `ps -E` to extract cmux workspace/surface IDs.
    nonisolated private func findCmuxTargetForClaudeSession(uuid: String) -> (workspaceId: String, surfaceId: String?)? {
        let ps = Process()
        let out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ax", "-o", "pid=,command="]
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return nil }
        let psData = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let psOutput = String(data: psData, encoding: .utf8) else { return nil }

        // Find PID whose command contains `claude` + `--session-id <uuid>`.
        // Match substring rather than token-split because args may include JSON with spaces.
        var matchedPid: String?
        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.contains("/claude") && trimmed.contains("--session-id \(uuid)") {
                let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if let pidPart = parts.first { matchedPid = String(pidPart); break }
            }
        }
        guard let pid = matchedPid else { return nil }

        // ps -E -p <pid>: prints command + space-separated env vars on one (very long) line.
        let envPs = Process()
        let envOut = Pipe()
        envPs.executableURL = URL(fileURLWithPath: "/bin/ps")
        envPs.arguments = ["-E", "-p", pid, "-o", "command="]
        envPs.standardOutput = envOut
        envPs.standardError = FileHandle.nullDevice
        do { try envPs.run() } catch { return nil }
        let envData = envOut.fileHandleForReading.readDataToEndOfFile()
        envPs.waitUntilExit()
        guard let envLine = String(data: envData, encoding: .utf8) else { return nil }

        // Env vars appear as space-separated KEY=VALUE tokens after the command. Scan for our keys.
        var wsId: String?
        var surfId: String?
        for token in envLine.split(separator: " ") {
            if token.hasPrefix("CMUX_WORKSPACE_ID=") {
                wsId = String(token.dropFirst("CMUX_WORKSPACE_ID=".count))
            } else if token.hasPrefix("CMUX_SURFACE_ID=") {
                surfId = String(token.dropFirst("CMUX_SURFACE_ID=".count))
            }
        }
        guard let wsId else { return nil }
        return (wsId, surfId)
    }

    // MARK: - cmux

    private func sendViaCmux(_ text: String, session: SessionState) async -> Bool {
        let dirName = URL(fileURLWithPath: session.cwd).lastPathComponent
        let sid = String(session.sessionId.prefix(8))

        // Find workspace
        guard let wsOutput = cmuxRun(["list-workspaces"]) else { return false }

        var targetWsRef: String?
        for wsLine in wsOutput.components(separatedBy: "\n") where !wsLine.isEmpty {
            guard let wsRef = wsLine.components(separatedBy: " ").first(where: { $0.hasPrefix("workspace:") }) else { continue }
            guard let surfOutput = cmuxRun(["list-pane-surfaces", "--workspace", wsRef]) else { continue }
            if surfOutput.contains(sid) || surfOutput.contains(dirName) {
                targetWsRef = wsRef
                break
            }
        }

        guard let wsRef = targetWsRef else {
            Self.logger.debug("No matching cmux workspace for \(sid)")
            return false
        }

        // Send text + Enter
        let escaped = text.replacingOccurrences(of: "\n", with: "\r")
        _ = cmuxRun(["send", "--workspace", wsRef, "--", "\(escaped)\r"])
        Self.logger.info("Sent message to cmux workspace \(wsRef)")
        return true
    }

    private func cmuxRun(_ args: [String]) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: cmuxPath)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    // MARK: - AppleScript

    private func sendViaAppleScript(_ text: String, script: String) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let success = process.terminationStatus == 0
            if success {
                Self.logger.info("Sent message via AppleScript")
            }
            return success
        } catch {
            return false
        }
    }
}
