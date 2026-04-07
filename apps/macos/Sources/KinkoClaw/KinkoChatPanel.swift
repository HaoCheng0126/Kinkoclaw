import Observation
import SwiftUI

@MainActor
@Observable
final class KinkoChatPanelViewModel {
    struct MessageRow: Identifiable, Equatable {
        let id: String
        let role: String
        let text: String
        let timestamp: Double
        let pending: Bool
    }

    let sessionKey = "main"

    var messages: [MessageRow] = []
    var availableModels: [ChatModelChoice] = []
    var selectedModelID = ""
    var thinkingLevel = "adaptive"
    var draft = ""
    var streamingAssistantText = ""
    var statusMessage = "Not connected"
    var errorMessage: String?
    var activeRunID: String?
    var isLoading = false
    var isSending = false

    private let gateway: PetGatewayController
    private let transport: PetChatTransport
    private var subscriptionTask: Task<Void, Never>?
    private var didActivate = false

    init(gateway: PetGatewayController, transport: PetChatTransport) {
        self.gateway = gateway
        self.transport = transport
        self.statusMessage = gateway.statusMessage
    }

    func activate() {
        self.statusMessage = self.gateway.statusMessage
        guard !self.didActivate else { return }
        self.didActivate = true
        self.subscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.gateway.subscribe()
            for await event in stream {
                guard !Task.isCancelled else { return }
                self.handleGatewayEvent(event)
            }
        }
        Task {
            await self.refresh()
        }
    }

    func deactivate() {
        self.subscriptionTask?.cancel()
        self.subscriptionTask = nil
        self.didActivate = false
    }

    func refresh() async {
        self.isLoading = true
        self.errorMessage = nil
        self.statusMessage = self.gateway.statusMessage
        defer { self.isLoading = false }

        await self.loadHistory()
        await self.loadModels()
        await self.loadSessionSummary()
    }

    func sendDraft() async {
        let trimmed = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.draft = ""
        self.isSending = true
        self.errorMessage = nil
        let optimistic = MessageRow(
            id: UUID().uuidString,
            role: "user",
            text: trimmed,
            timestamp: Date().timeIntervalSince1970,
            pending: true)
        self.messages.append(optimistic)

        do {
            let response = try await self.transport.sendMessage(
                sessionKey: self.sessionKey,
                message: trimmed,
                thinking: self.thinkingLevel,
                idempotencyKey: UUID().uuidString,
                attachments: [])
            self.activeRunID = response.runId
            self.isSending = false
        } catch {
            self.messages.removeAll { $0.id == optimistic.id }
            self.isSending = false
            self.errorMessage = error.localizedDescription
        }
    }

    func abortRun() async {
        guard let activeRunID else { return }
        do {
            try await self.transport.abortRun(sessionKey: self.sessionKey, runID: activeRunID)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func selectModel(_ selectionID: String) async {
        let nextSelection = selectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedModelID = nextSelection
        let payload = nextSelection.isEmpty ? nil : nextSelection
        do {
            try await self.transport.setSessionModel(sessionKey: self.sessionKey, model: payload)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func updateThinkingLevel(_ nextValue: String) async {
        self.thinkingLevel = nextValue
        do {
            try await self.transport.setSessionThinking(sessionKey: self.sessionKey, thinkingLevel: nextValue)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func handleGatewayEvent(_ event: GatewayEvent) {
        self.statusMessage = self.gateway.statusMessage

        switch event {
        case .snapshot:
            Task {
                await self.loadHistory()
                await self.loadSessionSummary()
            }
        case let .event(frame):
            self.handleGatewayFrame(frame)
        case .seqGap:
            Task {
                await self.loadHistory()
            }
        }
    }

    private func handleGatewayFrame(_ frame: EventFrame) {
        switch frame.event {
        case "chat":
            guard let payload = frame.payload,
                  let chat = try? Self.decode(payload, as: ChatEventPayload.self),
                  self.matchesMain(chat.sessionKey)
            else {
                return
            }

            if let runID = chat.runId, !runID.isEmpty {
                self.activeRunID = runID
            }

            switch chat.state {
            case "queued", "running", "input", "dispatch":
                self.isSending = true
            case "final", "aborted":
                self.isSending = false
                self.activeRunID = nil
                self.streamingAssistantText = ""
                Task {
                    await self.loadHistory()
                }
            case "error":
                self.isSending = false
                self.activeRunID = nil
                self.streamingAssistantText = ""
                self.errorMessage = chat.errorMessage ?? "Chat failed"
                Task {
                    await self.loadHistory()
                }
            default:
                break
            }
        case "agent":
            guard let payload = frame.payload,
                  let agent = try? Self.decode(payload, as: AgentEventPayload.self),
                  agent.stream == "assistant"
            else {
                return
            }
            self.activeRunID = agent.runId
            if let text = agent.data["text"]?.value as? String {
                self.streamingAssistantText = text
            }
        case "health":
            self.statusMessage = self.gateway.statusMessage
        default:
            break
        }
    }

    private func matchesMain(_ sessionKey: String?) -> Bool {
        guard let sessionKey = sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionKey.isEmpty
        else {
            return true
        }
        let normalized = sessionKey.lowercased()
        return normalized == "main" || normalized == "agent:main:main"
    }

    private func loadHistory() async {
        do {
            let history = try await self.transport.requestHistory(sessionKey: self.sessionKey)
            self.messages = Self.messageRows(from: history.messages ?? [])
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func loadModels() async {
        do {
            self.availableModels = try await self.transport.listModels()
        } catch {
            self.availableModels = []
        }
    }

    private func loadSessionSummary() async {
        do {
            let sessions = try await self.transport.listSessions(limit: 20)
            if let summary = sessions.sessions.first(where: { $0.key == self.sessionKey || $0.key == "agent:main:main" }) {
                self.selectedModelID = summary.model ?? ""
                if let thinkingLevel = summary.thinkingLevel?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !thinkingLevel.isEmpty
                {
                    self.thinkingLevel = thinkingLevel
                }
            } else {
                if let mainSessionKey = sessions.defaults?.mainSessionKey,
                   !mainSessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    self.selectedModelID = sessions.defaults?.model ?? ""
                }
                if let defaultModel = sessions.defaults?.model {
                    self.selectedModelID = defaultModel
                }
            }
        } catch {
            // The debug panel is optional. Keep defaults if session metadata is unavailable.
        }
    }

    private static func messageRows(from rawMessages: [AnyCodable]) -> [MessageRow] {
        rawMessages.compactMap { item in
            guard let message = try? Self.decode(item, as: ChatMessage.self) else { return nil }
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard role == "assistant" || role == "user" || role == "tool" else { return nil }

            let text = message.content
                .compactMap(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let displayText = role == "user" ? KinkoPersonaSupport.visibleMessage(from: text) : text
            guard !displayText.isEmpty else { return nil }

            return MessageRow(
                id: message.id.uuidString,
                role: role == "tool" ? "assistant" : role,
                text: displayText,
                timestamp: message.timestamp ?? Date().timeIntervalSince1970,
                pending: false)
        }
    }

    private static func decode<T: Decodable>(_ payload: AnyCodable, as _: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct KinkoChatPanelView: View {
    @Bindable var viewModel: KinkoChatPanelViewModel
    let accent: Color

    private let thinkingOptions = ["low", "adaptive", "medium", "high"]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("main assistant")
                            .font(.system(size: 20, weight: .bold))
                        Text(self.viewModel.statusMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if self.viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker(
                            "",
                            selection: Binding(
                                get: { self.viewModel.selectedModelID },
                                set: { newValue in
                                    Task { await self.viewModel.selectModel(newValue) }
                                }))
                        {
                            Text("Gateway default").tag("")
                            ForEach(self.viewModel.availableModels) { choice in
                                Text(choice.selectionID).tag(choice.selectionID)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Thinking")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker(
                            "",
                            selection: Binding(
                                get: { self.viewModel.thinkingLevel },
                                set: { newValue in
                                    Task { await self.viewModel.updateThinkingLevel(newValue) }
                                }))
                        {
                            ForEach(self.thinkingOptions, id: \.self) { option in
                                Text(option.capitalized).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }

                if let errorMessage = self.viewModel.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }
            }
            .padding(18)
            .background(.ultraThinMaterial)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(self.viewModel.messages) { message in
                            MessageBubbleRow(message: message, accent: self.accent)
                        }

                        if !self.viewModel.streamingAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MessageBubbleRow(
                                message: .init(
                                    id: "streaming-assistant",
                                    role: "assistant",
                                    text: self.viewModel.streamingAssistantText,
                                    timestamp: Date().timeIntervalSince1970,
                                    pending: true),
                                accent: self.accent)
                        }
                    }
                    .padding(18)
                }
                .background(Color.black.opacity(0.08))
                .onChange(of: self.viewModel.messages.count) { _, _ in
                    self.scrollToBottom(proxy)
                }
                .onChange(of: self.viewModel.streamingAssistantText) { _, _ in
                    self.scrollToBottom(proxy)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: self.$viewModel.draft)
                    .font(.system(size: 14, weight: .medium))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 92, maxHeight: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.16)))

                HStack {
                    Button("Abort Run") {
                        Task { await self.viewModel.abortRun() }
                    }
                    .disabled(self.viewModel.activeRunID == nil)

                    Spacer()

                    Button("Send") {
                        Task { await self.viewModel.sendDraft() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(self.accent)
                    .disabled(self.viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.viewModel.isSending)
                }
            }
            .padding(18)
            .background(.ultraThinMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let lastID = self.viewModel.messages.last?.id ?? (!self.viewModel.streamingAssistantText.isEmpty ? "streaming-assistant" : nil) else {
            return
        }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

private struct MessageBubbleRow: View {
    let message: KinkoChatPanelViewModel.MessageRow
    let accent: Color

    var body: some View {
        VStack(alignment: self.message.role == "user" ? .trailing : .leading, spacing: 6) {
            HStack {
                if self.message.role == "user" { Spacer() }
                Text(self.message.role == "user" ? "你" : "角色")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if self.message.role != "user" { Spacer() }
            }

            Text(self.message.text)
                .textSelection(.enabled)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(self.message.role == "user" ? self.accent.opacity(0.18) : Color.white.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(self.message.pending ? self.accent.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: self.message.role == "user" ? .trailing : .leading)
    }
}
