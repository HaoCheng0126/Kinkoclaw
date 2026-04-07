import Foundation
import Network
import Observation
import OSLog

enum PetGatewayConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

private struct PetResolvedGatewayEndpoint: Equatable {
    let url: URL
    let token: String?
    let fingerprint: String
    let description: String
}

struct PetSSHParsedTarget: Equatable {
    let user: String?
    let host: String
    let port: Int

    var displayString: String {
        if let user {
            return "\(user)@\(host)"
        }
        return host
    }
}

enum PetSSHTargetParser {
    static func parse(_ raw: String) -> PetSSHParsedTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("-") { return nil }
        if trimmed.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) != nil {
            return nil
        }

        let user: String?
        let hostPort: String
        if let at = trimmed.lastIndex(of: "@") {
            user = String(trimmed[..<at])
            hostPort = String(trimmed[trimmed.index(after: at)...])
        } else {
            user = nil
            hostPort = trimmed
        }

        let host: String
        let port: Int
        if let colon = hostPort.lastIndex(of: ":"), colon != hostPort.startIndex {
            host = String(hostPort[..<colon])
            let suffix = String(hostPort[hostPort.index(after: colon)...])
            guard let parsedPort = Int(suffix), (1...65535).contains(parsedPort) else { return nil }
            port = parsedPort
        } else {
            host = hostPort
            port = 22
        }

        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { return nil }
        if normalizedHost.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) != nil {
            return nil
        }

        let normalizedUser = user?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedUser, !normalizedUser.isEmpty,
           normalizedUser.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) != nil
        {
            return nil
        }

        return PetSSHParsedTarget(
            user: normalizedUser?.isEmpty == false ? normalizedUser : nil,
            host: normalizedHost,
            port: port)
    }

    static func sshArguments(target: PetSSHParsedTarget, identityPath: String, options: [String]) -> [String] {
        var args = options
        args.append(contentsOf: ["-p", String(target.port)])
        let trimmedIdentity = identityPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentity.isEmpty {
            args.append(contentsOf: ["-o", "IdentitiesOnly=yes"])
            args.append(contentsOf: ["-i", trimmedIdentity])
        }
        args.append("--")
        args.append(target.displayString)
        return args
    }
}

private final class PetRemotePortTunnel {
    private static let logger = Logger(subsystem: "ai.kinkoclaw.app", category: "ssh-tunnel")

    let process: Process
    let localPort: UInt16
    private let stderrHandle: FileHandle

    private init(process: Process, localPort: UInt16, stderrHandle: FileHandle) {
        self.process = process
        self.localPort = localPort
        self.stderrHandle = stderrHandle
    }

    deinit {
        self.terminate()
    }

    func terminate() {
        self.stderrHandle.readabilityHandler = nil
        try? self.stderrHandle.close()
        if self.process.isRunning {
            self.process.terminate()
            self.process.waitUntilExit()
        }
    }

    static func create(
        target: PetSSHParsedTarget,
        identityPath: String,
        remotePort: Int,
        preferredLocalPort: UInt16? = nil) async throws -> PetRemotePortTunnel
    {
        let localPort = try await self.findAvailablePort(preferred: preferredLocalPort)
        let args = PetSSHTargetParser.sshArguments(
            target: target,
            identityPath: identityPath,
            options: [
                "-o", "BatchMode=yes",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "UpdateHostKeys=yes",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "TCPKeepAlive=yes",
                "-N",
                "-L", "\(localPort):127.0.0.1:\(remotePort)",
            ])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args

        let pipe = Pipe()
        process.standardError = pipe
        let stderrHandle = pipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty
            {
                Self.logger.error("ssh stderr: \(output, privacy: .public)")
            }
        }

        try process.run()
        try? await Task.sleep(nanoseconds: 200_000_000)
        if !process.isRunning {
            stderrHandle.readabilityHandler = nil
            let errorOutput = try? stderrHandle.readToEnd()
            let errorMessage = errorOutput.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "PetRemotePortTunnel",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: errorMessage?.isEmpty == false
                        ? errorMessage!
                        : "SSH tunnel exited immediately",
                ])
        }

        return PetRemotePortTunnel(process: process, localPort: localPort, stderrHandle: stderrHandle)
    }

    private static func findAvailablePort(preferred: UInt16?) async throws -> UInt16 {
        if let preferred, self.portIsAvailable(preferred) {
            return preferred
        }

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "ai.kinkoclaw.app.port", qos: .utility)
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                listener.newConnectionHandler = { connection in connection.cancel() }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            listener.stateUpdateHandler = nil
                            listener.cancel()
                            continuation.resume(returning: port)
                        }
                    case let .failed(error):
                        listener.stateUpdateHandler = nil
                        listener.cancel()
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func portIsAvailable(_ port: UInt16) -> Bool {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            return false
        }
        listener.cancel()
        return true
    }
}

@MainActor
@Observable
final class PetGatewayController {
    static let shared = PetGatewayController()

    private let logger = Logger(subsystem: "ai.kinkoclaw.app", category: "gateway")
    private let settings = PetCompanionSettings.shared
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var transport: GatewayTransport?
    private var currentEndpoint: PetResolvedGatewayEndpoint?
    private var tunnel: PetRemotePortTunnel?
    private var subscribers: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var healthTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingRunIDs = Set<String>()
    private var currentSessionKey = "main"

    var connectionStatus: PetGatewayConnectionStatus = .disconnected
    var presenceState: PetPresenceState = .disconnected
    var statusMessage = "Not connected"
    var lastErrorMessage: String?

    private init() {}

    func start() {
        self.startHealthLoop()
        guard self.settings.hasCompletedOnboarding || self.settings.lastConnectionSucceededAt != nil else {
            self.connectionStatus = .disconnected
            self.presenceState = .disconnected
            self.statusMessage = "Connect to an existing gateway"
            self.lastErrorMessage = nil
            return
        }
        Task {
            _ = await self.reconnect(reason: "launch")
        }
    }

    func stop() {
        self.healthTask?.cancel()
        self.healthTask = nil
        self.reconnectTask?.cancel()
        self.reconnectTask = nil
        Task {
            await self.shutdownTransport()
        }
    }

    @discardableResult
    func reconnect(reason: String) async -> Bool {
        self.reconnectTask?.cancel()
        self.reconnectTask = nil

        guard self.settings.isConnectionProfileComplete else {
            self.connectionStatus = .disconnected
            self.presenceState = .disconnected
            self.statusMessage = self.settings.connectionSummary
            self.lastErrorMessage = "Connection details are incomplete."
            return false
        }

        self.logger.info("reconnect reason=\(reason, privacy: .public)")
        self.connectionStatus = .connecting
        self.lastErrorMessage = nil
        self.statusMessage = "Connecting to \(self.settings.connectionSummary)"

        do {
            let endpoint = try await self.resolveEndpoint()
            try await self.configureTransportIfNeeded(endpoint: endpoint)
            _ = try await self.request(method: "health", params: nil, timeoutMs: 10_000, allowRecovery: false)
            self.currentEndpoint = endpoint
            self.connectionStatus = .connected
            if self.presenceState == .disconnected || self.presenceState == .error {
                self.presenceState = .idle
            }
            self.statusMessage = endpoint.description
            self.settings.markSuccessfulConnection()
            return true
        } catch {
            self.logger.error("reconnect failed \(error.localizedDescription, privacy: .public)")
            self.connectionStatus = .error(error.localizedDescription)
            self.presenceState = .error
            self.statusMessage = self.settings.connectionSummary
            self.lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func subscribe() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.subscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in
                    self.subscribers[id] = nil
                }
            }
        }
    }

    func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double? = nil,
        allowRecovery: Bool = true) async throws -> Data
    {
        if self.transport == nil {
            guard await self.reconnect(reason: "request:\(method)") else {
                throw NSError(
                    domain: "PetGatewayController",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: self.lastErrorMessage ?? "Gateway unavailable"])
            }
        }

        do {
            guard let transport = self.transport else {
                throw NSError(
                    domain: "PetGatewayController",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Gateway transport unavailable"])
            }
            let data = try await transport.request(method: method, params: params, timeoutMs: timeoutMs)
            self.connectionStatus = .connected
            if self.presenceState == .disconnected {
                self.presenceState = .idle
            }
            return data
        } catch {
            self.logger.error("request failed method=\(method, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            self.lastErrorMessage = error.localizedDescription

            if allowRecovery && self.settings.connectionMode == .sshTunnel {
                await self.resetTransport()
                guard await self.reconnect(reason: "ssh-recover:\(method)") else {
                    throw error
                }
                guard let transport = self.transport else { throw error }
                return try await transport.request(method: method, params: params, timeoutMs: timeoutMs)
            }

            if self.connectionStatus != .connecting {
                self.connectionStatus = .error(error.localizedDescription)
            }
            if self.presenceState != .replying && self.presenceState != .thinking {
                self.presenceState = .error
            }
            throw error
        }
    }

    func prepareForOutgoingMessage() {
        self.presenceState = .thinking
    }

    func applyStagePresence(_ state: PetPresenceState) {
        if self.connectionStatus == .disconnected && state != .error {
            return
        }
        self.presenceState = state
    }

    func restorePresenceAfterStageOverride() {
        guard self.connectionStatus.isConnected else {
            self.presenceState = .disconnected
            return
        }

        if self.pendingRunIDs.isEmpty {
            self.presenceState = .idle
        } else if self.presenceState != .replying {
            self.presenceState = .thinking
        }
    }

    private func resolveEndpoint() async throws -> PetResolvedGatewayEndpoint {
        switch self.settings.connectionMode {
        case .local:
            let port = min(max(self.settings.localPort, 1), 65535)
            return PetResolvedGatewayEndpoint(
                url: URL(string: "ws://127.0.0.1:\(port)")!,
                token: self.settings.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                fingerprint: "local:\(port):\(self.settings.gatewayAuthTokenRef)",
                description: "Local gateway on 127.0.0.1:\(port)")
        case .sshTunnel:
            guard let parsed = PetSSHTargetParser.parse(self.settings.sshTarget) else {
                throw NSError(
                    domain: "PetGatewayController",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "SSH target must look like user@host[:port]"])
            }
            self.tunnel?.terminate()
            self.tunnel = try await PetRemotePortTunnel.create(
                target: parsed,
                identityPath: self.settings.sshIdentityPath,
                remotePort: self.settings.localPort,
                preferredLocalPort: nil)
            let localPort = Int(self.tunnel?.localPort ?? 0)
            return PetResolvedGatewayEndpoint(
                url: URL(string: "ws://127.0.0.1:\(localPort)")!,
                token: self.settings.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                fingerprint: "ssh:\(parsed.displayString):\(parsed.port):\(localPort):\(self.settings.gatewayAuthTokenRef)",
                description: "SSH tunnel via \(parsed.displayString)")
        case .directWss:
            let trimmed = self.settings.directGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let url = Self.normalizedDirectURL(from: trimmed) else {
                throw NSError(
                    domain: "PetGatewayController",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Direct gateway URL must use wss://"])
            }
            return PetResolvedGatewayEndpoint(
                url: url,
                token: self.settings.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                fingerprint: "direct:\(url.absoluteString):\(self.settings.gatewayAuthTokenRef)",
                description: "Direct gateway \(url.host ?? url.absoluteString)")
        }
    }

    private func configureTransportIfNeeded(endpoint: PetResolvedGatewayEndpoint) async throws {
        if self.currentEndpoint == endpoint, self.transport != nil {
            return
        }

        await self.shutdownTransport()
        self.currentEndpoint = endpoint
        self.transport = GatewayTransport(
            url: endpoint.url,
            token: endpoint.token,
            pushHandler: { [weak self] event in
                await MainActor.run {
                    self?.handle(event: event)
                }
            },
            disconnectHandler: { [weak self] reason in
                await MainActor.run {
                    self?.handleDisconnect(reason: reason)
                }
            })
    }

    private func handle(event: GatewayEvent) {
        self.connectionStatus = .connected
        if self.presenceState == .disconnected {
            self.presenceState = .idle
        }

        switch event {
        case let .snapshot(hello):
            let mainKey = Self.mainSessionKey(from: hello)
            self.currentSessionKey = mainKey
            self.statusMessage = self.currentEndpoint?.description ?? "Connected"
            if self.pendingRunIDs.isEmpty, self.presenceState != .replying, self.presenceState != .thinking {
                self.presenceState = .idle
            }
        case let .event(frame):
            self.handleGatewayEvent(frame)
        case .seqGap:
            self.pendingRunIDs.removeAll()
            self.presenceState = .idle
        }

        for continuation in self.subscribers.values {
            continuation.yield(event)
        }
    }

    private func handleGatewayEvent(_ event: EventFrame) {
        switch event.event {
        case "health":
            if let payload = event.payload,
               let health = try? self.decode(GatewayHealthOK.self, from: payload),
               health.ok == false
            {
                self.connectionStatus = .error("Gateway reported unhealthy status")
                self.presenceState = .error
            } else if self.pendingRunIDs.isEmpty, self.presenceState != .replying {
                self.presenceState = .idle
            }
        case "chat":
            guard let payload = event.payload,
                  let chat = try? self.decode(ChatEventPayload.self, from: payload)
            else { return }
            let sessionKey = chat.sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesMain = sessionKey == nil || Self.matchesMainSessionKey(sessionKey!, current: self.currentSessionKey)
            guard matchesMain else { return }

            if let runID = chat.runId, !runID.isEmpty {
                if chat.state == "final" || chat.state == "aborted" || chat.state == "error" {
                    self.pendingRunIDs.remove(runID)
                } else {
                    self.pendingRunIDs.insert(runID)
                }
            }

            switch chat.state {
            case "queued", "running", "input", "dispatch":
                self.presenceState = .thinking
            case "final", "aborted":
                self.presenceState = .idle
            case "error":
                self.lastErrorMessage = chat.errorMessage ?? "Chat failed"
                self.presenceState = .error
            default:
                break
            }
        case "agent":
            guard let payload = event.payload,
                  let agent = try? self.decode(AgentEventPayload.self, from: payload)
            else { return }
            if agent.stream == "assistant" {
                self.presenceState = .replying
            } else if agent.stream == "tool", self.presenceState != .replying {
                self.presenceState = .thinking
            }
        default:
            break
        }
    }

    private func handleDisconnect(reason: String) {
        self.logger.warning("gateway disconnected \(reason, privacy: .public)")
        if self.connectionStatus == .connecting {
            return
        }
        self.connectionStatus = .error(reason)
        self.lastErrorMessage = reason
        self.presenceState = .disconnected
        self.statusMessage = reason
        self.scheduleReconnectAfterDisconnect()
    }

    private func scheduleReconnectAfterDisconnect() {
        guard self.settings.isConnectionProfileComplete else { return }
        self.reconnectTask?.cancel()
        self.reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            _ = await self.reconnect(reason: "socket-disconnect")
        }
    }

    private func startHealthLoop() {
        self.healthTask?.cancel()
        self.healthTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard self.settings.isConnectionProfileComplete else { continue }
                do {
                    _ = try await self.request(method: "health", params: nil, timeoutMs: 8_000, allowRecovery: true)
                    if self.connectionStatus.isConnected,
                       self.pendingRunIDs.isEmpty,
                       self.presenceState != .replying,
                       self.presenceState != .thinking
                    {
                        self.presenceState = .idle
                    }
                } catch {
                    if self.connectionStatus != .connecting {
                        self.connectionStatus = .error(error.localizedDescription)
                        self.presenceState = .disconnected
                    }
                }
            }
        }
    }

    private func shutdownTransport() async {
        if let transport {
            await transport.shutdown()
        }
        self.transport = nil
    }

    private func resetTransport() async {
        await self.shutdownTransport()
        self.tunnel?.terminate()
        self.tunnel = nil
        self.currentEndpoint = nil
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: AnyCodable) throws -> T {
        let data = try self.encoder.encode(payload)
        return try self.decoder.decode(type, from: data)
    }

    nonisolated static func normalizedDirectURL(from raw: String) -> URL? {
        guard let components = URLComponents(string: raw) else { return nil }
        guard components.scheme?.lowercased() == "wss" else { return nil }
        return components.url
    }

    private static func matchesMainSessionKey(_ incoming: String, current: String) -> Bool {
        let incomingNormalized = incoming.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let currentNormalized = current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if incomingNormalized == currentNormalized {
            return true
        }
        return (incomingNormalized == "main" && currentNormalized == "agent:main:main") ||
            (incomingNormalized == "agent:main:main" && currentNormalized == "main")
    }

    private static func mainSessionKey(from hello: HelloOk) -> String {
        if let mainSessionKey = hello.snapshot.sessionDefaults?["mainSessionKey"]?.value as? String,
           !mainSessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return mainSessionKey
        }
        return "main"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class PetChatTransport: @unchecked Sendable {
    private unowned let gateway: PetGatewayController

    init(gateway: PetGatewayController) {
        self.gateway = gateway
    }

    func requestHistory(sessionKey: String) async throws -> ChatHistoryResponse {
        let data = try await self.gateway.request(
            method: "chat.history",
            params: ["sessionKey": AnyCodable(sessionKey)],
            timeoutMs: 15_000)
        return try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
    }

    func listModels() async throws -> [ChatModelChoice] {
        let data = try await self.gateway.request(
            method: "models.list",
            params: [:],
            timeoutMs: 15_000)
        let result = try JSONDecoder().decode(ModelsListResult.self, from: data)
        return result.models.map {
            ChatModelChoice(
                modelID: $0.id,
                name: $0.name,
                provider: $0.provider,
                contextWindow: $0.contextWindow)
        }
    }

    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [ChatAttachmentPayload]) async throws -> ChatSendResponse
    {
        await MainActor.run {
            self.gateway.prepareForOutgoingMessage()
        }

        let outboundMessage = await MainActor.run {
            KinkoPersonaSupport.composeOutboundMessage(
                visibleMessage: message,
                card: PetCompanionSettings.shared.personaMemoryCard)
        }

        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "message": AnyCodable(outboundMessage),
            "thinking": AnyCodable(thinking),
            "idempotencyKey": AnyCodable(idempotencyKey),
        ]
        if !attachments.isEmpty {
            params["attachments"] = AnyCodable(attachments)
        }

        let data = try await self.gateway.request(method: "chat.send", params: params, timeoutMs: 30_000)
        return try JSONDecoder().decode(ChatSendResponse.self, from: data)
    }

    func abortRun(sessionKey: String, runID: String) async throws {
        _ = try await self.gateway.request(
            method: "chat.abort",
            params: [
                "sessionKey": AnyCodable(sessionKey),
                "runId": AnyCodable(runID),
            ],
            timeoutMs: 10_000)
    }

    func listSessions(limit: Int?) async throws -> ChatSessionsListResponse {
        let data = try await self.gateway.request(
            method: "sessions.list",
            params: ["limit": AnyCodable(limit ?? 1)],
            timeoutMs: 15_000)
        return try JSONDecoder().decode(ChatSessionsListResponse.self, from: data)
    }

    func setSessionModel(sessionKey: String, model: String?) async throws {
        var params: [String: AnyCodable] = ["key": AnyCodable(sessionKey)]
        params["model"] = model.map(AnyCodable.init) ?? AnyCodable(NSNull())
        _ = try await self.gateway.request(method: "sessions.patch", params: params, timeoutMs: 15_000)
    }

    func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws {
        _ = try await self.gateway.request(
            method: "sessions.patch",
            params: [
                "key": AnyCodable(sessionKey),
                "thinkingLevel": AnyCodable(thinkingLevel),
            ],
            timeoutMs: 15_000)
    }

    func requestHealth(timeoutMs: Int) async throws -> Bool {
        let data = try await self.gateway.request(
            method: "health",
            params: nil,
            timeoutMs: Double(timeoutMs),
            allowRecovery: true)
        if let decoded = try? JSONDecoder().decode(GatewayHealthOK.self, from: data),
           let ok = decoded.ok
        {
            return ok
        }
        return true
    }
}
