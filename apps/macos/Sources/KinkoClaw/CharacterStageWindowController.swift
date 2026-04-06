import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

@MainActor
final class CharacterStageWindowController: NSObject, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    static let shared = CharacterStageWindowController()

    private struct StageMessage: Codable, Identifiable, Sendable, Hashable {
        let id: String
        let role: String
        let text: String
        let timestamp: Double
        let pending: Bool
    }

    private struct StagePackPayload: Encodable {
        let id: String
        let displayName: String
        let accentHex: String
        let previewImage: String?
        let sourceLabel: String
        let isImported: Bool
        let assets: PetPackManifest.Assets
        let model: PetPackManifest.StageModelManifest
        let defaultSceneFrame: PetPackManifest.StageSceneFrame
        let dialogueProfile: PetPackManifest.DialogueProfile
        let interactionProfile: PetPackManifest.InteractionProfile
    }

    private struct StageConnectionPayload: Encodable {
        let mode: String
        let localPort: Int
        let sshTarget: String
        let sshIdentityPath: String
        let directGatewayURL: String
        let gatewayAuthTokenRef: String
        let gatewayAuthToken: String
        let summary: String
    }

    private struct StageSettingsPayload: Encodable {
        let availablePacks: [StagePackPayload]
        let selectedLive2DModelId: String
        let sceneFrame: PetPackManifest.StageSceneFrame
        let connection: StageConnectionPayload
        let personaCard: PersonaMemoryCard
        let settingsOpen: Bool
    }

    private struct StageBootstrapPayload: Encodable {
        let connectionStatus: String
        let statusMessage: String
        let presenceState: String
        let pack: StagePackPayload
        let messages: [StageMessage]
        let streamingAssistantText: String?
        let fallbackChatAvailable: Bool
        let settings: StageSettingsPayload
    }

    private struct StageErrorPayload: Encodable {
        let message: String
    }

    private struct StageToastPayload: Encodable {
        let message: String
    }

    private struct StageStatusPayload: Encodable {
        let connectionStatus: String
        let statusMessage: String
        let presenceState: String
    }

    private struct StageAssistantStreamPayload: Encodable {
        let text: String?
    }

    private struct StageEnvelope<Value: Encodable>: Encodable {
        let type: String
        let payload: Value
    }

    private enum MessageNames {
        static let bridge = "kinkoClawStageBridge"
    }

    private let settings = PetCompanionSettings.shared
    private let gateway = PetGatewayController.shared
    private let transport = PetChatTransport(gateway: PetGatewayController.shared)
    private let panelSize = NSSize(width: 1180, height: 760)

    private var window: NSPanel?
    private var webView: WKWebView?
    private var bundleRootURL: URL?
    private var stageSchemeHandler: StageBundleSchemeHandler?
    private var subscriptionTask: Task<Void, Never>?
    private var lastMessages: [StageMessage] = []
    private var streamingAssistantText: String?
    private var webViewReady = false
    private var settingsDrawerPresented = false

    private override init() {
        super.init()
        self.subscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.gateway.subscribe()
            for await event in stream {
                if Task.isCancelled { return }
                self.handle(event: event)
            }
        }
    }

    deinit {
        self.subscriptionTask?.cancel()
    }

    var isVisible: Bool {
        self.window?.isVisible ?? false
    }

    func toggle(anchorFrame: NSRect?) {
        if self.isVisible {
            self.close()
        } else {
            self.show(anchorFrame: anchorFrame)
        }
    }

    func show(anchorFrame: NSRect?, openSettings: Bool = false) {
        self.ensureWindow()
        self.settingsDrawerPresented = openSettings || self.settings.shouldAutoPresentConnectionWindow
        PetOverlayController.shared.suspendForStage()
        self.reposition(anchorFrame: anchorFrame)
        self.window?.orderFrontRegardless()
        self.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        self.refreshAppearance()
        Task {
            await self.syncHistory()
        }
    }

    func openSettings(anchorFrame: NSRect?) {
        self.show(anchorFrame: anchorFrame, openSettings: true)
    }

    func close() {
        self.window?.orderOut(nil)
        PetOverlayController.shared.resumeAfterStage()
    }

    func reposition(anchorFrame: NSRect?) {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let bounds = screen?.visibleFrame ?? .zero
        let frame: NSRect
        if let anchorFrame {
            frame = PetWindowPlacement.anchoredChatFrame(
                size: self.panelSize,
                anchor: anchorFrame,
                padding: 18,
                in: bounds)
        } else {
            frame = PetWindowPlacement.centeredFrame(size: self.panelSize, on: screen)
        }
        window.setFrame(frame, display: true)
    }

    func refreshAppearance() {
        self.publishStatus()
        self.publishPack()
        self.publishSettings()
    }

    func windowWillClose(_: Notification) {
        self.close()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        self.webViewReady = true
        self.publishBootstrap()
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == MessageNames.bridge else { return }
        self.handleBridgeMessage(message.body)
    }

    private func ensureWindow() {
        if self.window != nil { return }

        guard let stageRootURL = StageRuntimeSupport.resolveRootURL() else {
            self.publishError("Stage resources are missing from the app bundle.")
            return
        }
        self.bundleRootURL = stageRootURL
        let schemeHandler = StageBundleSchemeHandler(rootURL: stageRootURL)
        self.stageSchemeHandler = schemeHandler

        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: MessageNames.bridge)
        controller.addUserScript(
            WKUserScript(
                source: """
                (() => {
                  if (window.KinkoClawNativeBridge) return;
                  window.KinkoClawNativeBridge = {
                    postMessage(payload) {
                      try {
                        window.webkit?.messageHandlers?.\(MessageNames.bridge)?.postMessage(payload);
                      } catch (error) {
                        console.error("KinkoClawNativeBridge.postMessage failed", error);
                      }
                    }
                  };
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        configuration.userContentController = controller
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: StageRuntimeSupport.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = false
        self.webView = webView

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 28
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            webView.topAnchor.constraint(equalTo: effect.topAnchor),
            webView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let container = NSViewController()
        container.view = effect

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: self.panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = container
        panel.delegate = self
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.toolbarStyle = .unifiedCompact
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.window = panel

        self.loadStage()
    }

    private func loadStage() {
        guard let webView else { return }
        guard self.bundleRootURL != nil else {
            self.publishError("Stage index.html is missing from the app bundle.")
            return
        }
        guard let stageURL = StageRuntimeSupport.stageURL() else {
            self.publishError("Stage URL could not be created.")
            return
        }
        webView.load(URLRequest(url: stageURL))
    }

    private func handleBridgeMessage(_ body: Any) {
        guard let payload = body as? [String: Any],
              let type = payload["type"] as? String
        else {
            return
        }

        switch type {
        case "stage.ready":
            self.webViewReady = true
            self.publishBootstrap()
        case "chat.send":
            let text = Self.stringValue(payload["text"])
            guard !text.isEmpty else { return }
            Task {
                await self.sendMessage(text, source: "stage")
            }
        case "settings.visibility":
            self.settingsDrawerPresented = Self.boolValue(payload["open"])
            self.publishSettings()
        case "settings.saveConnection":
            self.saveConnectionSettings(from: payload)
        case "settings.saveCharacter":
            self.saveCharacterSettings(from: payload)
        case "settings.importModel":
            self.importLive2DModel()
        case "settings.savePersona":
            self.savePersonaSettings(from: payload)
        case "settings.resetPetPosition":
            PetOverlayController.shared.resetToDefaultPosition()
        case "gateway.reconnect":
            Task { @MainActor in
                _ = await self.gateway.reconnect(reason: "stage-bridge")
            }
        case "chat.debugFallback":
            PetChatPanelController.shared.toggle(anchorFrame: PetOverlayController.shared.currentFrame())
        case "window.hide":
            self.close()
        default:
            break
        }
    }

    private func saveConnectionSettings(from payload: [String: Any]) {
        if let rawMode = Self.stringOptional(payload["mode"]),
           let mode = GatewayConnectionProfile.fromStoredValue(rawMode)
        {
            self.settings.connectionMode = mode
        }

        if let localPort = Self.intValue(payload["localPort"]) {
            self.settings.localPort = localPort
        }
        if let sshTarget = Self.stringOptional(payload["sshTarget"]) {
            self.settings.sshTarget = sshTarget
        }
        if let sshIdentityPath = Self.stringOptional(payload["sshIdentityPath"]) {
            self.settings.sshIdentityPath = sshIdentityPath
        }
        if let directGatewayURL = Self.stringOptional(payload["directGatewayURL"]) {
            self.settings.directGatewayURL = directGatewayURL
        }
        if let tokenRef = Self.stringOptional(payload["gatewayAuthTokenRef"]) {
            self.settings.gatewayAuthTokenRef = tokenRef.isEmpty ? "default" : tokenRef
        }
        if let token = Self.stringOptional(payload["gatewayAuthToken"]) {
            self.settings.gatewayAuthToken = token
        }

        self.settings.hasCompletedOnboarding = true
        self.settingsDrawerPresented = true
        self.publishSettings()
        self.publishStatus()
        Task { @MainActor in
            _ = await self.gateway.reconnect(reason: "stage-settings-save")
        }
    }

    private func saveCharacterSettings(from payload: [String: Any]) {
        if let modelId = Self.stringOptional(payload["selectedLive2DModelId"]), !modelId.isEmpty {
            self.settings.selectedLive2DModelId = modelId
        }
        if let scale = Self.doubleValue(payload["sceneModelScale"]) {
            self.settings.sceneModelScale = scale
        }
        if let offsetX = Self.doubleValue(payload["sceneModelOffsetX"]) {
            self.settings.sceneModelOffsetX = offsetX
        }
        if let offsetY = Self.doubleValue(payload["sceneModelOffsetY"]) {
            self.settings.sceneModelOffsetY = offsetY
        }

        self.publishPack()
        self.publishSettings()
    }

    private func importLive2DModel() {
        let panel = NSOpenPanel()
        panel.title = "导入 Live2D 模型"
        panel.message = "选择模型 ZIP，或选择包含 .model3.json 的文件夹。"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.zip]
        }

        let presentImport: (URL) -> Void = { url in
            do {
                let importedPack = try Live2DModelLibrary.importModelPack(from: url)
                self.settings.selectedLive2DModelId = importedPack.id
                self.settings.resetSceneModelFrame()
                self.publishPack()
                self.publishSettings()
                self.publishToast("已导入模型：\(importedPack.displayName)")
            } catch {
                self.publishError(error.localizedDescription)
            }
        }

        if let window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                presentImport(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            presentImport(url)
        }
    }

    private func savePersonaSettings(from payload: [String: Any]) {
        let card = PersonaMemoryCard(
            characterIdentity: Self.stringValue(payload["characterIdentity"]),
            speakingStyle: Self.stringValue(payload["speakingStyle"]),
            relationshipToUser: Self.stringValue(payload["relationshipToUser"]),
            longTermMemories: Self.stringListValue(payload["longTermMemories"]),
            constraints: Self.stringListValue(payload["constraints"]))
        self.settings.personaMemoryCard = card
        self.publishSettings()
    }

    private func handle(event: GatewayEvent) {
        switch event {
        case let .snapshot(hello):
            self.publishStatus()
            if let mainKey = hello.snapshot.sessionDefaults?["mainSessionKey"]?.value as? String,
               !mainKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                self.publish("gateway.session", payload: ["sessionKey": mainKey])
            }
            Task {
                await self.syncHistory()
            }
        case let .event(frame):
            self.handle(frame: frame)
        case .seqGap:
            self.publishStatus()
        }
    }

    private func handle(frame: EventFrame) {
        switch frame.event {
        case "chat":
            guard let payload = frame.payload,
                  let chat = try? Self.decodePayload(payload, as: ChatEventPayload.self)
            else {
                self.publishStatus()
                return
            }

            switch chat.state {
            case "queued", "input", "dispatch", "running":
                self.publishStatus()
            case "final", "aborted":
                self.streamingAssistantText = nil
                self.publishAssistantStream()
                Task {
                    await self.syncHistory()
                }
            case "error":
                self.streamingAssistantText = nil
                self.publishAssistantStream()
                self.publishError(chat.errorMessage ?? "Chat failed")
            default:
                break
            }
        case "agent":
            guard let payload = frame.payload,
                  let agent = try? Self.decodePayload(payload, as: AgentEventPayload.self),
                  agent.stream == "assistant"
            else {
                return
            }

            if let text = agent.data["text"]?.value as? String {
                self.streamingAssistantText = text
                self.publishAssistantStream()
            }
            self.publishStatus()
        case "health":
            self.publishStatus()
        default:
            break
        }
    }

    private func sendMessage(_ text: String, source: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let optimistic = StageMessage(
            id: UUID().uuidString,
            role: "user",
            text: trimmed,
            timestamp: Date().timeIntervalSince1970,
            pending: true)
        self.lastMessages.append(optimistic)
        self.publishMessages()
        self.publish("chat.pending", payload: ["source": source, "text": trimmed])

        do {
            _ = try await self.transport.sendMessage(
                sessionKey: "main",
                message: trimmed,
                thinking: "adaptive",
                idempotencyKey: UUID().uuidString,
                attachments: [])
        } catch {
            self.lastMessages.removeAll { $0.id == optimistic.id }
            self.publishMessages()
            self.publishError(error.localizedDescription)
        }
    }

    private func syncHistory() async {
        do {
            let history = try await self.transport.requestHistory(sessionKey: "main")
            self.lastMessages = Self.stageMessages(from: history.messages ?? [])
            self.publishMessages()
        } catch {
            self.publishError(error.localizedDescription)
        }
    }

    private func publishBootstrap() {
        guard self.webViewReady else { return }
        self.publish(
            "stage.bootstrap",
            payload: StageBootstrapPayload(
                connectionStatus: Self.connectionStatusID(self.gateway.connectionStatus),
                statusMessage: self.gateway.statusMessage,
                presenceState: self.gateway.presenceState.rawValue,
                pack: Self.stagePackPayload(from: self.settings.selectedPack),
                messages: self.lastMessages,
                streamingAssistantText: self.streamingAssistantText,
                fallbackChatAvailable: true,
                settings: self.settingsPayload()))
    }

    private func publishStatus() {
        self.publish(
            "stage.status",
            payload: StageStatusPayload(
                connectionStatus: Self.connectionStatusID(self.gateway.connectionStatus),
                statusMessage: self.gateway.statusMessage,
                presenceState: self.gateway.presenceState.rawValue))
    }

    private func publishPack() {
        self.publish("stage.pack", payload: Self.stagePackPayload(from: self.settings.selectedPack))
    }

    private func publishSettings() {
        self.publish("stage.settings", payload: self.settingsPayload())
    }

    private func publishMessages() {
        self.publish("stage.messages", payload: ["messages": self.lastMessages])
    }

    private func publishAssistantStream() {
        self.publish("stage.assistant-stream", payload: StageAssistantStreamPayload(text: self.streamingAssistantText))
    }

    private func publishError(_ message: String) {
        self.publish("stage.error", payload: StageErrorPayload(message: message))
    }

    private func publishToast(_ message: String) {
        self.publish("stage.toast", payload: StageToastPayload(message: message))
    }

    private func settingsPayload() -> StageSettingsPayload {
        StageSettingsPayload(
            availablePacks: PetPackRegistry.packs.map { Self.stagePackPayload(from: $0) },
            selectedLive2DModelId: self.settings.selectedLive2DModelId,
            sceneFrame: self.settings.sceneModelFrame,
            connection: StageConnectionPayload(
                mode: self.settings.connectionMode.rawValue,
                localPort: self.settings.localPort,
                sshTarget: self.settings.sshTarget,
                sshIdentityPath: self.settings.sshIdentityPath,
                directGatewayURL: self.settings.directGatewayURL,
                gatewayAuthTokenRef: self.settings.gatewayAuthTokenRef,
                gatewayAuthToken: self.settings.gatewayAuthToken,
                summary: self.settings.connectionSummary),
            personaCard: self.settings.personaMemoryCard,
            settingsOpen: self.settingsDrawerPresented)
    }

    private func publish<T: Encodable>(_ type: String, payload: T) {
        guard self.webViewReady, let webView else { return }

        do {
            let data = try JSONEncoder().encode(StageEnvelope(type: type, payload: payload))
            guard let raw = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__KINKOCLAW_STAGE_RECEIVE__?.(\(raw));", completionHandler: nil)
        } catch {
            NSLog("KinkoClaw stage publish failed: %@", error.localizedDescription)
        }
    }

    private static func decodePayload<T: Decodable>(_ payload: AnyCodable, as _: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func connectionStatusID(_ status: PetGatewayConnectionStatus) -> String {
        switch status {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .error:
            "error"
        }
    }

    private static func stagePackPayload(from pack: PetPackManifest) -> StagePackPayload {
        StagePackPayload(
            id: pack.id,
            displayName: pack.displayName,
            accentHex: pack.accentHex,
            previewImage: pack.previewImage,
            sourceLabel: pack.model.modelPath.hasPrefix("\(Live2DModelLibrary.mountedRootName)/") ? "已导入" : "内置",
            isImported: pack.model.modelPath.hasPrefix("\(Live2DModelLibrary.mountedRootName)/"),
            assets: pack.assets,
            model: pack.model,
            defaultSceneFrame: pack.defaultSceneFrame,
            dialogueProfile: pack.dialogueProfile,
            interactionProfile: pack.interactionProfile)
    }

    private static func stageMessages(from rawMessages: [AnyCodable]) -> [StageMessage] {
        rawMessages.compactMap { item in
            guard let message = try? Self.decodePayload(item, as: ChatMessage.self) else { return nil }
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard role == "assistant" || role == "user" || role == "tool" else { return nil }

            let text = message.content
                .compactMap(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let displayText = role == "user" ? KinkoPersonaSupport.visibleMessage(from: text) : text
            guard !displayText.isEmpty else { return nil }

            return StageMessage(
                id: message.id.uuidString,
                role: role == "tool" ? "assistant" : role,
                text: displayText,
                timestamp: message.timestamp ?? Date().timeIntervalSince1970,
                pending: false)
        }
    }

    private static func stringValue(_ raw: Any?) -> String {
        Self.stringOptional(raw) ?? ""
    }

    private static func stringOptional(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let value as NSString:
            return String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        case let value as String:
            Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            value
        case let value as NSNumber:
            value.doubleValue
        case let value as String:
            Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func boolValue(_ raw: Any?) -> Bool {
        switch raw {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        case let value as String:
            ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            false
        }
    }

    private static func stringListValue(_ raw: Any?) -> [String] {
        switch raw {
        case let array as [String]:
            return array
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case let array as [NSString]:
            return array
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case let value as String:
            return value
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }
}
