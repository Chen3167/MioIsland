//
//  SyncManager.swift
//  ClaudeIsland
//
//  Top-level coordinator for CodeLight Server sync.
//  Manages connection lifecycle, message relay, and RPC execution.
//

import Combine
import Foundation
import os.log

/// Coordinates all CodeLight Server sync functionality.
/// Initialize once at app startup, connects/disconnects based on configuration.
@MainActor
final class SyncManager: ObservableObject {

    static let shared = SyncManager()
    static let logger = Logger(subsystem: "com.codeisland", category: "SyncManager")

    @Published private(set) var isEnabled = false
    @Published private(set) var connectionState: ServerConnectionState = .disconnected

    private var connection: ServerConnection?
    private var relay: MessageRelay?
    private var rpcExecutor: RPCExecutor?

    /// Text the phone injected into a Claude session via cmux. Used so MessageRelay
    /// can skip re-uploading the same text when it re-appears in the JSONL (dedup).
    /// Keyed by Claude session UUID; entries expire after 60s.
    private var recentlyInjected: [String: [(text: String, at: Date)]] = [:]

    func recordPhoneInjection(claudeUuid: String, text: String) {
        pruneInjections()
        recentlyInjected[claudeUuid, default: []].append((text, Date()))
    }

    /// Returns true and removes the entry if `text` was recently injected from phone.
    func consumePhoneInjection(claudeUuid: String, text: String) -> Bool {
        pruneInjections()
        guard var list = recentlyInjected[claudeUuid] else { return false }
        if let idx = list.firstIndex(where: { $0.text == text }) {
            list.remove(at: idx)
            recentlyInjected[claudeUuid] = list.isEmpty ? nil : list
            return true
        }
        return false
    }

    private func pruneInjections() {
        let cutoff = Date().addingTimeInterval(-60)
        for (k, v) in recentlyInjected {
            let kept = v.filter { $0.at > cutoff }
            recentlyInjected[k] = kept.isEmpty ? nil : kept
        }
    }

    /// The server URL to connect to. Stored in UserDefaults.
    var serverUrl: String? {
        get { UserDefaults.standard.string(forKey: "codelight-server-url") }
        set {
            UserDefaults.standard.set(newValue, forKey: "codelight-server-url")
            if let url = newValue, !url.isEmpty {
                Task { await connectToServer(url: url) }
            } else {
                disconnectFromServer()
            }
        }
    }

    private init() {
        // Default server URL if not configured
        if serverUrl == nil {
            UserDefaults.standard.set("https://island.wdao.chat", forKey: "codelight-server-url")
        }
        // Auto-connect on startup if configured
        if let url = serverUrl, !url.isEmpty {
            Task { await connectToServer(url: url) }
        }
    }

    // MARK: - Connection Lifecycle

    func connectToServer(url: String) async {
        disconnectFromServer()

        let conn = ServerConnection(serverUrl: url)
        self.connection = conn

        do {
            try await conn.authenticate()
            conn.connect()

            // Handle messages from phone → type into terminal
            conn.onUserMessage = { [weak self] serverSessionId, messageText, claudeUuid, cwd in
                Task { @MainActor in
                    await self?.handlePhoneMessage(serverSessionId: serverSessionId, text: messageText, claudeUuid: claudeUuid, cwd: cwd)
                }
            }

            // Wait for socket to actually connect before starting relay
            let relay = MessageRelay(connection: conn)
            self.relay = relay
            let rpc = RPCExecutor()
            self.rpcExecutor = rpc

            // Delay relay start to give socket time to connect
            Task { @MainActor in
                // Wait up to 5 seconds for socket connection
                for _ in 0..<50 {
                    if conn.isConnected { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }

                if conn.isConnected {
                    relay.startRelaying()
                    Self.logger.info("Relay started after socket connected")
                } else {
                    Self.logger.warning("Socket did not connect in time, starting relay anyway")
                    relay.startRelaying()
                }
            }

            isEnabled = true
            connectionState = .connected
            Self.logger.info("Sync enabled with \(url)")
        } catch {
            connectionState = .error(error.localizedDescription)
            Self.logger.error("Sync connection failed: \(error)")
        }
    }

    /// Handle a user message received from the phone — type it into the matching terminal.
    /// Tries the locally tracked SessionState first; falls back to direct cmux lookup
    /// using the Claude UUID/path the server provides (so dormant sessions still work).
    private func handlePhoneMessage(serverSessionId: String, text: String, claudeUuid: String?, cwd: String?) async {
        let sessions = await SessionStore.shared.currentSessions()
        let localId = self.relay?.localSessionId(forServerId: serverSessionId)
        let preview = String(text.prefix(200))
        Self.logger.info("handlePhoneMessage: serverId=\(serverSessionId, privacy: .public) localId=\(localId ?? "nil", privacy: .public) tag=\(claudeUuid ?? "nil", privacy: .public) cwd=\(cwd ?? "nil", privacy: .public) raw=\(preview, privacy: .public)")

        // Parse the message content — it may be plain text OR a JSON envelope with images.
        let (parsedText, imageBlobIds) = parseMessagePayload(text)
        Self.logger.info("parsed: text=\(parsedText.prefix(80), privacy: .public) blobCount=\(imageBlobIds.count)")

        // Resolve which Claude UUID we're actually targeting for dedup & image routing.
        let targetUuid: String?
        if let localId, sessions.contains(where: { $0.sessionId == localId }) {
            targetUuid = localId
        } else if let claudeUuid {
            targetUuid = claudeUuid
        } else {
            targetUuid = nil
        }

        // Image path: download blobs and paste via NSPasteboard + Cmd+V
        if !imageBlobIds.isEmpty {
            guard let targetUuid, let connection = self.connection else {
                Self.logger.warning("Phone image message dropped: no target uuid")
                return
            }
            var images: [Data] = []
            for blobId in imageBlobIds {
                do {
                    let (data, _) = try await connection.downloadBlob(blobId: blobId)
                    images.append(data)
                    // Ack so the server can delete the blob immediately
                    connection.sendBlobConsumed(blobId: blobId)
                } catch {
                    Self.logger.error("Failed to download blob \(blobId): \(error.localizedDescription)")
                }
            }
            if images.isEmpty {
                Self.logger.warning("No images could be downloaded — falling back to text-only")
            } else {
                let ok = await TerminalWriter.shared.sendImagesAndText(images: images, text: parsedText, claudeUuid: targetUuid)
                if ok { recordPhoneInjection(claudeUuid: targetUuid, text: parsedText) }
                Self.logger.info("Phone message with \(images.count) image(s) → terminal: \(ok ? "success" : "failed")")
                return
            }
        }

        // Text-only path
        // Path 1: locally tracked session
        if let localId, let session = sessions.first(where: { $0.sessionId == localId }) {
            let sent = await TerminalWriter.shared.sendText(parsedText, to: session)
            if sent { recordPhoneInjection(claudeUuid: session.sessionId, text: parsedText) }
            Self.logger.info("Phone message → terminal (tracked): \(sent ? "success" : "failed")")
            return
        }

        // Path 2: not tracked locally — use server-provided UUID + cwd to find cmux workspace directly
        if let uuid = claudeUuid {
            let sent = await TerminalWriter.shared.sendTextDirect(parsedText, claudeUuid: uuid, cwd: cwd)
            if sent { recordPhoneInjection(claudeUuid: uuid, text: parsedText) }
            Self.logger.info("Phone message → terminal (direct uuid): \(sent ? "success" : "failed")")
            return
        }

        Self.logger.warning("Phone message dropped: no local session and no uuid for serverId=\(serverSessionId, privacy: .public)")
    }

    /// Extract `text` and `images[].blobId` from a message content string. If the content
    /// isn't a JSON object, treat it as plain text with no images.
    private func parseMessagePayload(_ content: String) -> (text: String, blobIds: [String]) {
        guard let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (content, [])
        }
        let text = dict["text"] as? String ?? ""
        var blobIds: [String] = []
        if let images = dict["images"] as? [[String: Any]] {
            blobIds = images.compactMap { $0["blobId"] as? String }
        }
        return (text, blobIds)
    }

    func disconnectFromServer() {
        relay?.stopRelaying()
        connection?.disconnect()
        connection = nil
        relay = nil
        rpcExecutor = nil
        isEnabled = false
        connectionState = .disconnected
    }

    /// Called when a QR code is scanned with server details
    func handlePairingQR(serverUrl: String, tempPublicKey: String, deviceName: String) async {
        UserDefaults.standard.set(serverUrl, forKey: "codelight-server-url")
        await connectToServer(url: serverUrl)
        Self.logger.info("Paired with \(deviceName) via QR")
    }
}
