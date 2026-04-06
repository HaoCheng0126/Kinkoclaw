import AppKit
import AVFoundation
import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import Speech
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
        let assets: PetPackManifest.Assets
        let model: PetPackManifest.StageModelManifest
        let voiceProfile: PetPackManifest.VoiceProfile
        let interactionProfile: PetPackManifest.InteractionProfile
    }

    private struct StageVoiceSnapshot: Encodable {
        let presence: String
        let transcript: String
        let level: Double
        let errorMessage: String?
        let permissionsGranted: Bool
    }

    private struct StageBootstrapPayload: Encodable {
        let connectionStatus: String
        let statusMessage: String
        let presenceState: String
        let pack: StagePackPayload
        let messages: [StageMessage]
        let streamingAssistantText: String?
        let voice: StageVoiceSnapshot
        let fallbackChatAvailable: Bool
    }

    private struct StageErrorPayload: Encodable {
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
    private let voiceRuntime = PetVoiceRuntime.shared
    private let panelSize = NSSize(width: 980, height: 700)
    private var window: NSPanel?
    private var webView: WKWebView?
    private var bundleRootURL: URL?
    private var stageSchemeHandler: StageBundleSchemeHandler?
    private var subscriptionTask: Task<Void, Never>?
    private var lastMessages: [StageMessage] = []
    private var streamingAssistantText: String?
    private var voiceSnapshot = PetVoiceRuntime.Snapshot()
    private var lastSpokenAssistantText: String?
    private var webViewReady = false

    private override init() {
        super.init()
        self.voiceRuntime.onSnapshot = { [weak self] snapshot in
            self?.handleVoiceSnapshot(snapshot)
        }
        self.voiceRuntime.onTranscriptCommitted = { [weak self] transcript in
            Task { @MainActor in
                await self?.sendMessage(transcript, source: "voice")
            }
        }
        self.subscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.gateway.subscribe()
            for await push in stream {
                if Task.isCancelled { return }
                self.handle(push: push)
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

    func show(anchorFrame: NSRect?) {
        self.ensureWindow()
        self.reposition(anchorFrame: anchorFrame)
        self.window?.orderFrontRegardless()
        self.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        self.refreshAppearance()
        Task {
            await self.syncHistory(ttsOnNewAssistant: false)
        }
    }

    func close() {
        self.window?.orderOut(nil)
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
    }

    func windowWillClose(_: Notification) {
        self.close()
    }

    func webView(
        _ webView: WKWebView,
        didFinish _: WKNavigation!)
    {
        self.webViewReady = true
        self.publishBootstrap()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage)
    {
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

        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: MessageNames.bridge)
        let bootstrapScript = """
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
        """
        controller.addUserScript(
            WKUserScript(
                source: bootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        config.userContentController = controller
        config.preferences.isElementFullscreenEnabled = true
        config.setURLSchemeHandler(schemeHandler, forURLScheme: StageRuntimeSupport.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
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
            let text = (payload["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            Task {
                await self.sendMessage(text, source: "stage")
            }
        case "voice.begin":
            Task {
                await self.voiceRuntime.beginCapture(localeID: self.settings.selectedPack.voiceProfile.localeID)
            }
        case "voice.end":
            Task {
                await self.voiceRuntime.endCapture(sendTranscript: true)
            }
        case "voice.cancel":
            Task {
                await self.voiceRuntime.cancelCapture()
            }
        case "voice.stopSpeaking":
            Task {
                await self.voiceRuntime.stopSpeaking()
            }
        case "settings.open":
            PetSettingsWindowController.shared.show(onboarding: self.settings.shouldAutoPresentConnectionWindow)
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

    private func handle(push: GatewayPush) {
        switch push {
        case let .snapshot(hello):
            self.publishStatus()
            if let mainKey = hello.snapshot.sessiondefaults?["mainSessionKey"]?.value as? String,
               !mainKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                self.publish("gateway.session", payload: ["sessionKey": mainKey])
            }
            Task {
                await self.syncHistory(ttsOnNewAssistant: false)
            }
        case let .event(event):
            self.handle(event: event)
        case .seqGap:
            self.publishStatus()
        }
    }

    private func handle(event: EventFrame) {
        switch event.event {
        case "chat":
            guard let payload = event.payload,
                  let chat = try? Self.decodePayload(payload, as: OpenClawChatEventPayload.self)
            else {
                self.publishStatus()
                return
            }

            switch chat.state {
            case "queued", "input", "dispatch", "running":
                self.publishStatus()
            case "final":
                self.streamingAssistantText = nil
                self.publishAssistantStream()
                Task {
                    await self.syncHistory(ttsOnNewAssistant: true)
                }
            case "aborted":
                self.streamingAssistantText = nil
                self.publishAssistantStream()
                Task {
                    await self.syncHistory(ttsOnNewAssistant: false)
                }
            case "error":
                self.streamingAssistantText = nil
                self.publishAssistantStream()
                self.publishError(chat.errorMessage ?? "Chat failed")
            default:
                break
            }
        case "agent":
            guard let payload = event.payload,
                  let agent = try? Self.decodePayload(payload, as: OpenClawAgentEventPayload.self)
            else { return }
            guard agent.stream == "assistant" else { return }
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

    private func syncHistory(ttsOnNewAssistant: Bool) async {
        do {
            let history = try await self.transport.requestHistory(sessionKey: "main")
            let messages = Self.stageMessages(from: history.messages ?? [])
            self.lastMessages = messages
            self.publishMessages()

            if ttsOnNewAssistant,
               let lastAssistant = messages.last(where: { $0.role == "assistant" }),
               lastAssistant.text != self.lastSpokenAssistantText
            {
                self.lastSpokenAssistantText = lastAssistant.text
                await self.voiceRuntime.speak(
                    text: lastAssistant.text,
                    localeID: self.settings.selectedPack.voiceProfile.localeID)
            }
        } catch {
            self.publishError(error.localizedDescription)
        }
    }

    private func handleVoiceSnapshot(_ snapshot: PetVoiceRuntime.Snapshot) {
        self.voiceSnapshot = snapshot
        switch snapshot.presence {
        case .listening, .hearing, .speaking:
            self.gateway.applyStagePresence(snapshot.presence)
        case .error:
            self.gateway.applyStagePresence(.error)
        case .idle:
            self.gateway.restorePresenceAfterStageOverride()
        default:
            break
        }
        self.publishVoice()
        self.publishStatus()
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
                voice: self.stageVoiceSnapshot(),
                fallbackChatAvailable: true))
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

    private func publishMessages() {
        self.publish("stage.messages", payload: ["messages": self.lastMessages])
    }

    private func publishAssistantStream() {
        self.publish(
            "stage.assistant-stream",
            payload: StageAssistantStreamPayload(text: self.streamingAssistantText))
    }

    private func publishVoice() {
        self.publish("stage.voice", payload: self.stageVoiceSnapshot())
    }

    private func publishError(_ message: String) {
        self.publish("stage.error", payload: StageErrorPayload(message: message))
    }

    private func stageVoiceSnapshot() -> StageVoiceSnapshot {
        StageVoiceSnapshot(
            presence: self.voiceSnapshot.presence.rawValue,
            transcript: self.voiceSnapshot.transcript,
            level: self.voiceSnapshot.level,
            errorMessage: self.voiceSnapshot.errorMessage,
            permissionsGranted: self.voiceSnapshot.permissionsGranted)
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
            assets: pack.assets,
            model: pack.model,
            voiceProfile: pack.voiceProfile,
            interactionProfile: pack.interactionProfile)
    }

    private static func stageMessages(from raw: [AnyCodable]) -> [StageMessage] {
        raw.compactMap { item in
            guard let message = try? Self.decodePayload(item, as: OpenClawChatMessage.self) else { return nil }
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard role == "assistant" || role == "user" || role == "tool" else { return nil }

            let text = message.content
                .compactMap(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            guard !text.isEmpty else { return nil }

            return StageMessage(
                id: message.id.uuidString,
                role: role == "tool" ? "assistant" : role,
                text: text,
                timestamp: message.timestamp ?? Date().timeIntervalSince1970,
                pending: false)
        }
    }
}

@MainActor
final class PetVoiceRuntime: NSObject {
    struct Snapshot: Equatable {
        var presence: PetPresenceState = .idle
        var transcript = ""
        var level = 0.0
        var errorMessage: String?
        var permissionsGranted = false
    }

    static let shared = PetVoiceRuntime()

    var onSnapshot: ((Snapshot) -> Void)?
    var onTranscriptCommitted: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var tapInstalled = false
    private var transcriptBuffer = ""
    private var snapshot = Snapshot()

    private override init() {
        super.init()
    }

    func beginCapture(localeID: String?) async {
        guard self.snapshot.presence != .listening && self.snapshot.presence != .hearing else { return }
        await self.stopSpeaking()

        let permissionsGranted = await Self.ensureVoicePermissions(interactive: true)
        self.snapshot.permissionsGranted = permissionsGranted
        guard permissionsGranted else {
            self.setError("Microphone or Speech Recognition permission is missing.")
            return
        }

        let locale = Locale(identifier: localeID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? localeID!
            : Locale.current.identifier)
        let recognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer, recognizer.isAvailable else {
            self.setError("Speech recognizer is unavailable right now.")
            return
        }

        self.snapshot.errorMessage = nil
        self.snapshot.transcript = ""
        self.snapshot.level = 0
        self.snapshot.presence = .listening
        self.publishSnapshot()

        self.recognizer = recognizer
        self.transcriptBuffer = ""
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest?.shouldReportPartialResults = true

        if self.audioEngine == nil {
            self.audioEngine = AVAudioEngine()
        }

        guard let request = self.recognitionRequest, let audioEngine = self.audioEngine else {
            self.setError("Failed to start audio capture.")
            return
        }

        let input = audioEngine.inputNode
        if self.tapInstalled {
            input.removeTap(onBus: 0)
            self.tapInstalled = false
        }

        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            request.append(buffer)
            let level = Self.audioLevel(from: buffer)
            Task { @MainActor in
                self.snapshot.level = level
                if self.snapshot.presence == .listening && level > 0.025 {
                    self.snapshot.presence = .hearing
                }
                self.publishSnapshot()
            }
        }
        self.tapInstalled = true

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty
                {
                    self.transcriptBuffer = text
                    self.snapshot.transcript = text
                    self.snapshot.presence = .hearing
                    self.publishSnapshot()
                }

                if let error {
                    if (error as NSError).code != 216 {
                        self.setError(error.localizedDescription)
                    }
                } else if result?.isFinal == true {
                    Task {
                        await self.endCapture(sendTranscript: true)
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            self.setError(error.localizedDescription)
            await self.cancelCapture()
        }
    }

    func endCapture(sendTranscript: Bool) async {
        let transcript = (self.transcriptBuffer.isEmpty ? self.snapshot.transcript : self.transcriptBuffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.recognitionRequest?.endAudio()
        self.audioEngine?.stop()
        if self.tapInstalled {
            self.audioEngine?.inputNode.removeTap(onBus: 0)
            self.tapInstalled = false
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        self.recognitionTask?.finish()
        self.recognitionTask?.cancel()
        self.recognitionTask = nil
        self.recognitionRequest = nil
        self.recognizer = nil
        self.snapshot.level = 0
        self.snapshot.presence = .idle
        self.publishSnapshot()

        if sendTranscript, !transcript.isEmpty {
            self.onTranscriptCommitted?(transcript)
        }
        self.snapshot.transcript = ""
        self.publishSnapshot()
    }

    func cancelCapture() async {
        self.recognitionRequest?.endAudio()
        self.audioEngine?.stop()
        if self.tapInstalled {
            self.audioEngine?.inputNode.removeTap(onBus: 0)
            self.tapInstalled = false
        }
        self.recognitionTask?.cancel()
        self.recognitionTask = nil
        self.recognitionRequest = nil
        self.recognizer = nil
        self.snapshot.level = 0
        self.snapshot.transcript = ""
        self.snapshot.presence = .idle
        self.publishSnapshot()
    }

    func speak(text: String, localeID: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.snapshot.presence = .speaking
        self.snapshot.errorMessage = nil
        self.snapshot.transcript = trimmed
        self.publishSnapshot()

        do {
            try await TalkSystemSpeechSynthesizer.shared.speak(
                text: trimmed,
                language: localeID,
                onStart: { [weak self] in
                    Task { @MainActor in
                        self?.snapshot.presence = .speaking
                        self?.publishSnapshot()
                    }
                })
            self.snapshot.presence = .idle
            self.snapshot.transcript = ""
            self.publishSnapshot()
        } catch {
            if case TalkSystemSpeechSynthesizer.SpeakError.canceled = error {
                self.snapshot.presence = .idle
                self.snapshot.transcript = ""
                self.publishSnapshot()
                return
            }
            self.setError(error.localizedDescription)
        }
    }

    func stopSpeaking() async {
        TalkSystemSpeechSynthesizer.shared.stop()
        if self.snapshot.presence == .speaking {
            self.snapshot.presence = .idle
            self.snapshot.transcript = ""
            self.publishSnapshot()
        }
    }

    private func setError(_ message: String) {
        self.snapshot.presence = .error
        self.snapshot.errorMessage = message
        self.publishSnapshot()
    }

    private func publishSnapshot() {
        self.onSnapshot?(self.snapshot)
    }

    private static func audioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        var total: Double = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var channelTotal: Double = 0
            for index in 0..<frameLength {
                let sample = Double(samples[index])
                channelTotal += sample * sample
            }
            total += channelTotal / Double(frameLength)
        }

        let meanSquare = total / Double(max(channelCount, 1))
        return min(1, sqrt(meanSquare) * 8.5)
    }

    private static func ensureVoicePermissions(interactive: Bool) async -> Bool {
        let microphoneGranted = await self.ensureMicrophone(interactive: interactive)
        let speechGranted = await self.ensureSpeech(interactive: interactive)
        return microphoneGranted && speechGranted
    }

    private static func ensureMicrophone(interactive: Bool) async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard interactive else { return false }
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private static func ensureSpeech(interactive: Bool) async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            return true
        }
        guard status == .notDetermined, interactive else { return false }
        await withUnsafeContinuation { (cont: UnsafeContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                DispatchQueue.main.async {
                    cont.resume()
                }
            }
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}
