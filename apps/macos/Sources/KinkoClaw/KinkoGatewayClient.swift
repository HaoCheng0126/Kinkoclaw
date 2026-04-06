import Foundation
import OSLog

struct AnyCodable: Codable, @unchecked Sendable, Hashable {
    let value: Any

    init(_ value: Any) {
        self.value = Self.normalize(value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) { self.value = boolValue; return }
        if let intValue = try? container.decode(Int.self) { self.value = intValue; return }
        if let doubleValue = try? container.decode(Double.self) { self.value = doubleValue; return }
        if let stringValue = try? container.decode(String.self) { self.value = stringValue; return }
        if container.decodeNil() { self.value = NSNull(); return }
        if let dictionary = try? container.decode([String: AnyCodable].self) { self.value = dictionary; return }
        if let array = try? container.decode([AnyCodable].self) { self.value = array; return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self.value {
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            try container.encode(number.boolValue)
        case is NSNull:
            try container.encodeNil()
        case let dictionary as [String: AnyCodable]:
            try container.encode(dictionary)
        case let array as [AnyCodable]:
            try container.encode(array)
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as NSDictionary:
            var converted: [String: AnyCodable] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String else { continue }
                converted[key] = AnyCodable(value)
            }
            try container.encode(converted)
        case let array as NSArray:
            try container.encode(array.map { AnyCodable($0) })
        default:
            let context = EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Unsupported type")
            throw EncodingError.invalidValue(self.value, context)
        }
    }

    private static func normalize(_ value: Any) -> Any {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return value
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (left as Bool, right as Bool): left == right
        case let (left as Int, right as Int): left == right
        case let (left as Double, right as Double): left == right
        case let (left as String, right as String): left == right
        case (_ as NSNull, _ as NSNull): true
        case let (left as [String: AnyCodable], right as [String: AnyCodable]): left == right
        case let (left as [AnyCodable], right as [AnyCodable]): left == right
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self.value {
        case let value as Bool:
            hasher.combine(2)
            hasher.combine(value)
        case let value as Int:
            hasher.combine(0)
            hasher.combine(value)
        case let value as Double:
            hasher.combine(1)
            hasher.combine(value)
        case let value as String:
            hasher.combine(3)
            hasher.combine(value)
        case _ as NSNull:
            hasher.combine(4)
        case let value as [String: AnyCodable]:
            hasher.combine(5)
            for (key, element) in value.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(element)
            }
        case let value as [AnyCodable]:
            hasher.combine(6)
            for element in value {
                hasher.combine(element)
            }
        default:
            hasher.combine(999)
        }
    }
}

private enum GatewayProtocolVersion {
    static let current = 3
}

struct GatewayConnectResponse: Codable, Sendable {
    let type: String
    let `protocol`: Int
    let server: [String: AnyCodable]
    let features: [String: AnyCodable]
    let snapshot: GatewaySnapshot
    let auth: [String: AnyCodable]?
    let policy: [String: AnyCodable]
}

typealias HelloOk = GatewayConnectResponse

struct GatewaySnapshot: Codable, Sendable {
    let presence: [GatewayPresenceEntry]
    let health: AnyCodable
    let stateVersion: GatewayStateVersion
    let uptimeMs: Int
    let configPath: String?
    let stateDir: String?
    let sessionDefaults: [String: AnyCodable]?
    let authMode: AnyCodable?
    let updateAvailable: [String: AnyCodable]?
}

struct GatewayPresenceEntry: Codable, Sendable {
    let host: String?
    let ip: String?
    let version: String?
    let platform: String?
    let deviceFamily: String?
    let modelIdentifier: String?
    let mode: String?
    let lastInputSeconds: Int?
    let reason: String?
    let tags: [String]?
    let text: String?
    let ts: Int
    let deviceId: String?
    let roles: [String]?
    let scopes: [String]?
    let instanceId: String?
}

struct GatewayStateVersion: Codable, Sendable {
    let presence: Int
    let health: Int
}

struct RequestFrame: Codable, Sendable {
    let type: String
    let id: String
    let method: String
    let params: AnyCodable?
}

struct ResponseFrame: Codable, Sendable {
    let type: String
    let id: String
    let ok: Bool
    let payload: AnyCodable?
    let error: [String: AnyCodable]?
}

struct EventFrame: Codable, Sendable {
    let type: String
    let event: String
    let payload: AnyCodable?
    let seq: Int?
    let stateVersion: [String: AnyCodable]?
}

private enum GatewayFrame: Decodable, Sendable {
    case response(ResponseFrame)
    case event(EventFrame)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "res":
            self = .response(try ResponseFrame(from: decoder))
        case "event":
            self = .event(try EventFrame(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported gateway frame type")
        }
    }
}

struct ModelChoice: Codable, Sendable {
    let id: String
    let name: String
    let provider: String
    let contextWindow: Int?
    let reasoning: Bool?
}

struct ModelsListResult: Codable, Sendable {
    let models: [ModelChoice]
}

enum GatewayEvent: Sendable {
    case snapshot(HelloOk)
    case event(EventFrame)
    case seqGap(expected: Int, received: Int)
}

struct GatewayResponseError: LocalizedError, @unchecked Sendable {
    let method: String
    let code: String
    let message: String
    let details: [String: AnyCodable]

    init(method: String, code: String?, message: String?, details: [String: AnyCodable]?) {
        self.method = method
        self.code = (code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? code!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "GATEWAY_ERROR"
        self.message = (message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? message!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "gateway error"
        self.details = details ?? [:]
    }

    var errorDescription: String? {
        if self.code == "GATEWAY_ERROR" {
            return "\(self.method): \(self.message)"
        }
        return "\(self.method): [\(self.code)] \(self.message)"
    }
}

actor GatewayTransport {
    private let logger = Logger(subsystem: "ai.openclaw.kinkoclaw", category: "gateway-transport")
    private let url: URL
    private let token: String?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let pushHandler: (@Sendable (GatewayEvent) async -> Void)?
    private let disconnectHandler: (@Sendable (String) async -> Void)?
    private let defaultRequestTimeoutMs: Double = 15_000
    private let connectTimeoutSeconds: Double = 12
    private let connectChallengeTimeoutSeconds: Double = 6
    private let keepAliveIntervalSeconds: Double = 15

    private var task: URLSessionWebSocketTask?
    private var connected = false
    private var isConnecting = false
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var pending: [String: CheckedContinuation<ResponseFrame, Error>] = [:]
    private var receiveLoopTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var lastSeq: Int?
    private var lastTick: Date?

    init(
        url: URL,
        token: String?,
        pushHandler: (@Sendable (GatewayEvent) async -> Void)? = nil,
        disconnectHandler: (@Sendable (String) async -> Void)? = nil)
    {
        self.url = url
        self.token = token
        self.pushHandler = pushHandler
        self.disconnectHandler = disconnectHandler
    }

    func shutdown() async {
        self.connected = false
        self.receiveLoopTask?.cancel()
        self.receiveLoopTask = nil
        self.keepAliveTask?.cancel()
        self.keepAliveTask = nil
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
        self.failPending(NSError(
            domain: "GatewayTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "gateway transport shutdown"]))

        let waiters = self.connectWaiters
        self.connectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: NSError(
                domain: "GatewayTransport",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "gateway transport shutdown"]))
        }
    }

    func request(
        method: String,
        params: [String: AnyCodable]?,
        timeoutMs: Double? = nil) async throws -> Data
    {
        try await self.connect()
        let payload = try self.encodeRequest(method: method, params: params)
        let effectiveTimeout = timeoutMs ?? self.defaultRequestTimeoutMs
        guard let task = self.task else {
            throw NSError(
                domain: "GatewayTransport",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "gateway transport unavailable"])
        }

        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResponseFrame, Error>) in
            self.pending[payload.id] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await task.send(.data(payload.data))
                } catch {
                    await self.handleSendFailure(id: payload.id, method: method, error: error)
                }
            }

            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000))
                await self.timeoutRequest(id: payload.id, timeoutMs: effectiveTimeout)
            }
        }

        if response.ok == false {
            let details = response.error?["details"]?.value as? [String: AnyCodable]
            throw GatewayResponseError(
                method: method,
                code: response.error?["code"]?.value as? String,
                message: response.error?["message"]?.value as? String,
                details: details ?? response.error)
        }
        if let body = response.payload {
            return try self.encoder.encode(body)
        }
        return Data()
    }

    private func connect() async throws {
        if self.connected, self.task?.state == .running {
            return
        }
        if self.isConnecting {
            try await withCheckedThrowingContinuation { continuation in
                self.connectWaiters.append(continuation)
            }
            return
        }

        self.isConnecting = true
        defer { self.isConnecting = false }

        self.receiveLoopTask?.cancel()
        self.keepAliveTask?.cancel()
        self.task?.cancel(with: .goingAway, reason: nil)

        let task = URLSession(configuration: .default).webSocketTask(with: self.url)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        self.task = task

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.sendConnect(on: task)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.connectTimeoutSeconds * 1_000_000_000))
                    throw NSError(
                        domain: "GatewayTransport",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "connect timed out"])
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            let wrapped = self.wrap(error, context: "connect to gateway @ \(self.url.absoluteString)")
            self.connected = false
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            await self.disconnectHandler?("connect failed: \(wrapped.localizedDescription)")
            let waiters = self.connectWaiters
            self.connectWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: wrapped)
            }
            throw wrapped
        }

        self.connected = true
        self.startReceiveLoop()
        self.startKeepAlive()

        let waiters = self.connectWaiters
        self.connectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: ())
        }
    }

    private func sendConnect(on task: URLSessionWebSocketTask) async throws {
        _ = try await self.waitForConnectChallenge(on: task)

        let requestID = UUID().uuidString
        let clientVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var client: [String: AnyCodable] = [
            "id": AnyCodable("kinkoclaw-\(KinkoInstanceIdentity.instanceID)"),
            "displayName": AnyCodable(KinkoInstanceIdentity.displayName),
            "version": AnyCodable(clientVersion),
            "platform": AnyCodable(KinkoInstanceIdentity.platformString),
            "mode": AnyCodable("ui"),
            "instanceId": AnyCodable(KinkoInstanceIdentity.instanceID),
            "deviceFamily": AnyCodable(KinkoInstanceIdentity.deviceFamily),
        ]
        if let modelIdentifier = KinkoInstanceIdentity.modelIdentifier {
            client["modelIdentifier"] = AnyCodable(modelIdentifier)
        }

        var params: [String: AnyCodable] = [
            "minProtocol": AnyCodable(GatewayProtocolVersion.current),
            "maxProtocol": AnyCodable(GatewayProtocolVersion.current),
            "client": AnyCodable(client),
            "caps": AnyCodable([String]()),
            "commands": AnyCodable([String]()),
            "permissions": AnyCodable([String: Bool]()),
            "locale": AnyCodable(Locale.preferredLanguages.first ?? Locale.current.identifier),
            "userAgent": AnyCodable(ProcessInfo.processInfo.operatingSystemVersionString),
            "role": AnyCodable("operator"),
            "scopes": AnyCodable(["operator.read", "operator.write"]),
        ]
        if let token = self.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            params["auth"] = AnyCodable(["token": AnyCodable(token)])
        }

        let frame = RequestFrame(
            type: "req",
            id: requestID,
            method: "connect",
            params: AnyCodable(params))
        try await task.send(.data(self.encoder.encode(frame)))

        let response = try await self.waitForConnectResponse(on: task, requestID: requestID)
        if response.ok == false {
            let details = response.error?["details"]?.value as? [String: AnyCodable]
            throw GatewayResponseError(
                method: "connect",
                code: response.error?["code"]?.value as? String,
                message: response.error?["message"]?.value as? String,
                details: details ?? response.error)
        }
        guard let payload = response.payload else {
            throw NSError(
                domain: "GatewayTransport",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "connect failed (missing payload)"])
        }
        let hello = try self.decoder.decode(HelloOk.self, from: self.encoder.encode(payload))
        self.lastTick = Date()
        self.lastSeq = nil
        if let pushHandler = self.pushHandler {
            Task {
                await pushHandler(.snapshot(hello))
            }
        }
    }

    private func waitForConnectChallenge(on task: URLSessionWebSocketTask) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw NSError(domain: "GatewayTransport", code: 3) }
                while true {
                    let message = try await task.receive()
                    guard let data = self.decodeMessageData(message) else { continue }
                    guard let frame = try? self.decoder.decode(GatewayFrame.self, from: data) else { continue }
                    if case let .event(event) = frame,
                       event.event == "connect.challenge",
                       let payload = event.payload?.value as? [String: AnyCodable],
                       let nonce = payload["nonce"]?.value as? String
                    {
                        return nonce
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.connectChallengeTimeoutSeconds * 1_000_000_000))
                throw NSError(
                    domain: "GatewayTransport",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "connect failed (no challenge)"])
            }
            let result = try await group.next()
            group.cancelAll()
            guard let result else {
                throw NSError(domain: "GatewayTransport", code: 5, userInfo: [NSLocalizedDescriptionKey: "connect failed"])
            }
            return result
        }
    }

    private func waitForConnectResponse(on task: URLSessionWebSocketTask, requestID: String) async throws -> ResponseFrame {
        while true {
            let message = try await task.receive()
            guard let data = self.decodeMessageData(message) else { continue }
            let frame = try self.decoder.decode(GatewayFrame.self, from: data)
            switch frame {
            case let .response(response) where response.id == requestID:
                return response
            case let .event(event):
                if event.event == "tick" {
                    self.lastTick = Date()
                }
            default:
                continue
            }
        }
    }

    private func startReceiveLoop() {
        self.receiveLoopTask?.cancel()
        self.receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    private func startKeepAlive() {
        self.keepAliveTask?.cancel()
        self.keepAliveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.keepAliveIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let shouldContinue = await self.performKeepAliveTick()
                if shouldContinue == false {
                    return
                }
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, self.connected, let task = self.task {
            do {
                let message = try await task.receive()
                guard let data = self.decodeMessageData(message) else { continue }
                let frame = try self.decoder.decode(GatewayFrame.self, from: data)
                switch frame {
                case let .response(response):
                    self.pending.removeValue(forKey: response.id)?.resume(returning: response)
                case let .event(event):
                    if event.event == "tick" {
                        self.lastTick = Date()
                    }
                    if let seq = event.seq {
                        if let lastSeq = self.lastSeq, seq > lastSeq + 1 {
                            await self.pushHandler?(.seqGap(expected: lastSeq + 1, received: seq))
                        }
                        self.lastSeq = seq
                    }
                    await self.pushHandler?(.event(event))
                }
            } catch {
                let wrapped = self.wrap(error, context: "gateway receive")
                await self.handleSocketFailure(wrapped)
                return
            }
        }
    }

    private func handleSocketFailure(_ error: Error) async {
        guard self.connected || self.task != nil else { return }
        self.connected = false
        self.receiveLoopTask?.cancel()
        self.receiveLoopTask = nil
        self.keepAliveTask?.cancel()
        self.keepAliveTask = nil
        self.task?.cancel(with: .goingAway, reason: nil)
        self.task = nil
        self.failPending(error)
        await self.disconnectHandler?(error.localizedDescription)
    }

    private func handleSendFailure(id: String, method: String, error: Error) async {
        let wrapped = self.wrap(error, context: "gateway send \(method)")
        self.pending.removeValue(forKey: id)?.resume(throwing: wrapped)
        await self.handleSocketFailure(wrapped)
    }

    private func performKeepAliveTick() async -> Bool {
        guard self.connected, let task = self.task else {
            return true
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
            return true
        } catch {
            await self.handleSocketFailure(self.wrap(error, context: "gateway ping"))
            return false
        }
    }

    private func encodeRequest(method: String, params: [String: AnyCodable]?) throws -> (id: String, data: Data) {
        let requestID = UUID().uuidString
        let frame = RequestFrame(
            type: "req",
            id: requestID,
            method: method,
            params: params.map(AnyCodable.init))
        return (requestID, try self.encoder.encode(frame))
    }

    private func timeoutRequest(id: String, timeoutMs: Double) {
        guard let waiter = self.pending.removeValue(forKey: id) else { return }
        waiter.resume(throwing: NSError(
            domain: "GatewayTransport",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "gateway request timed out after \(Int(timeoutMs))ms"]))
    }

    private func failPending(_ error: Error) {
        let pending = self.pending
        self.pending.removeAll()
        for (_, waiter) in pending {
            waiter.resume(throwing: error)
        }
    }

    private nonisolated func decodeMessageData(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    private func wrap(_ error: Error, context: String) -> Error {
        if error is GatewayResponseError {
            return error
        }

        if let urlError = error as? URLError {
            let description = urlError.localizedDescription.isEmpty ? "cancelled" : urlError.localizedDescription
            return NSError(
                domain: URLError.errorDomain,
                code: urlError.errorCode,
                userInfo: [NSLocalizedDescriptionKey: "\(context): \(description)"])
        }

        let nsError = error as NSError
        let description = nsError.localizedDescription.isEmpty ? "unknown" : nsError.localizedDescription
        self.logger.error("\(context, privacy: .public) failed \(description, privacy: .public)")
        return NSError(
            domain: nsError.domain,
            code: nsError.code,
            userInfo: [NSLocalizedDescriptionKey: "\(context): \(description)"])
    }
}
