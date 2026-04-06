//
//  ServerConnection.swift
//  ClaudeIsland
//
//  Manages the connection to a CodeLight Server.
//  Handles auth, Socket.io lifecycle, and reconnection.
//

import Combine
import Foundation
import os.log
import CodeLightCrypto
import CodeLightProtocol
import SocketIO

/// Connection state for a CodeLight Server
enum ServerConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case error(String)
}

/// Manages connection to a single CodeLight Server instance.
@MainActor
final class ServerConnection: ObservableObject {

    static let logger = Logger(subsystem: "com.codeisland", category: "ServerConnection")

    @Published private(set) var state: ServerConnectionState = .disconnected

    private let serverUrl: String
    private let keyManager: KeyManager
    private var token: String?
    private var deviceId: String?
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var crypto: MessageCrypto?

    /// Called when an RPC request arrives from the phone
    var onRpcCall: ((String, String, @escaping (String) -> Void) -> Void)?

    /// Called when a user message arrives from another device (phone)
    var onUserMessage: ((String, String, String?, String?) -> Void)?  // (serverSessionId, messageText, claudeUuid, cwd)

    var isConnected: Bool { state == .connected }

    init(serverUrl: String, keyManager: KeyManager = KeyManager(serviceName: "com.codeisland.keys")) {
        self.serverUrl = serverUrl
        self.keyManager = keyManager
        self.token = keyManager.loadToken(forServer: serverUrl)
    }

    // MARK: - Authentication

    func authenticate() async throws {
        state = .authenticating

        let _ = try keyManager.getOrCreateIdentityKey()

        let challenge = UUID().uuidString
        let challengeData = Data(challenge.utf8)
        let signature = try keyManager.sign(challengeData)
        let publicKey = try keyManager.publicKeyBase64()

        let request = AuthRequest(
            publicKey: publicKey,
            challenge: challengeData.base64EncodedString(),
            signature: signature.base64EncodedString()
        )

        let url = URL(string: "\(serverUrl)/v1/auth")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            state = .error("Auth failed")
            return
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        if let t = authResponse.token {
            self.token = t
            self.deviceId = authResponse.deviceId
            try keyManager.storeToken(t, forServer: serverUrl)
            Self.logger.info("Authenticated with \(self.serverUrl)")
        } else {
            state = .error("No token received")
        }
    }

    // MARK: - Socket.io Connection

    func connect() {
        guard let token else {
            Self.logger.warning("Cannot connect: no auth token")
            return
        }

        state = .connecting

        let url = URL(string: serverUrl)!
        manager = SocketManager(socketURL: url, config: [
            .log(false),
            .path("/v1/updates"),
            .connectParams(["token": token, "clientType": "user-scoped"]),
            .reconnects(true),
            .reconnectWait(1),
            .reconnectWaitMax(5),
            .forceWebsockets(true),
            .extraHeaders(["Authorization": "Bearer \(token)"]),
        ])

        socket = manager?.defaultSocket

        socket?.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                self?.state = .connected
                Self.logger.info("Socket connected to \(self?.serverUrl ?? "")")
            }
        }

        socket?.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in
                self?.state = .disconnected
                Self.logger.info("Socket disconnected")
            }
        }

        socket?.on(clientEvent: .error) { [weak self] data, _ in
            Task { @MainActor in
                let msg = (data.first as? String) ?? "Unknown error"
                self?.state = .error(msg)
                Self.logger.error("Socket error: \(msg)")
            }
        }

        // Handle RPC calls from phone
        socket?.on("rpc-call") { [weak self] data, ack in
            guard let dict = data.first as? [String: Any],
                  let method = dict["method"] as? String,
                  let params = dict["params"] as? String else { return }

            self?.onRpcCall?(method, params) { result in
                ack.with(["ok": true, "result": result] as [String: Any])
            }
        }

        // Handle messages from other devices (phone → terminal)
        socket?.on("update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let type = dict["type"] as? String,
                  type == "new-message",
                  let sessionId = dict["sessionId"] as? String,
                  let msgDict = dict["message"] as? [String: Any],
                  let content = msgDict["content"] as? String else { return }

            // Parse message — if it's a plain text user message from phone, forward to terminal
            if let jsonData = content.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let msgType = parsed["type"] as? String {
                // Skip non-user messages (don't echo our own synced messages)
                if msgType != "user" { return }
            }
            let sessionTag = dict["sessionTag"] as? String
            let sessionPath = dict["sessionPath"] as? String

            // Plain text = message from phone (not JSON-serialized by MessageRelay)
            Task { @MainActor in
                Self.logger.info("Received user message from phone for session \(sessionId.prefix(8))...")
                self?.onUserMessage?(sessionId, content, sessionTag, sessionPath)
            }
        }

        socket?.connect()
    }

    func disconnect() {
        socket?.disconnect()
        manager = nil
        socket = nil
        state = .disconnected
    }

    // MARK: - Sending

    /// Send a session message (encrypted content) to the server
    func sendMessage(sessionId: String, content: String, localId: String? = nil) {
        guard isConnected else { return }

        var payload: [String: Any] = ["sid": sessionId, "message": content]
        if let localId { payload["localId"] = localId }

        socket?.emitWithAck("message", payload).timingOut(after: 30) { _ in }
    }

    /// Send session-alive heartbeat
    func sendAlive(sessionId: String) {
        guard isConnected else { return }
        socket?.emit("session-alive", ["sid": sessionId] as [String: Any])
    }

    /// Send session-end
    func sendSessionEnd(sessionId: String) {
        guard isConnected else { return }
        socket?.emit("session-end", ["sid": sessionId] as [String: Any])
    }

    /// Ack successful consumption of a blob so the server can delete it immediately.
    func sendBlobConsumed(blobId: String) {
        guard isConnected else { return }
        socket?.emit("blob-consumed", ["blobId": blobId] as [String: Any])
    }

    /// Download a blob by ID. Returns (data, mime) or throws.
    func downloadBlob(blobId: String) async throws -> (Data, String) {
        guard let token else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "\(serverUrl)/v1/blobs/\(blobId)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "CodeIsland.Blob", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Blob download failed"])
        }
        let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg").split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "image/jpeg"
        return (data, mime)
    }

    /// Update session metadata
    func updateMetadata(sessionId: String, metadata: String, expectedVersion: Int) {
        guard isConnected else { return }
        socket?.emitWithAck("update-metadata", [
            "sid": sessionId,
            "metadata": metadata,
            "expectedVersion": expectedVersion,
        ] as [String: Any]).timingOut(after: 10) { _ in }
    }

    /// Register as RPC handler for a method
    func registerRpc(method: String) {
        guard isConnected else { return }
        socket?.emit("rpc-register", ["method": method] as [String: Any])
    }

    // MARK: - HTTP API

    /// Create or load a session on the server
    func createSession(tag: String, metadata: String) async throws -> [String: Any] {
        return try await postJSON(path: "/v1/sessions", body: ["tag": tag, "metadata": metadata])
    }

    // MARK: - HTTP Helpers

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
