import AppKit
import Observation
import SwiftUI

@main
struct KinkoClawApp: App {
    @NSApplicationDelegateAdaptor(KinkoClawAppDelegate.self) private var delegate
    @State private var settings = PetCompanionSettings.shared
    @State private var gateway = PetGatewayController.shared

    var body: some Scene {
        MenuBarExtra {
            PetMenuBarContent(settings: self.settings, gateway: self.gateway)
        } label: {
            PetMenuBarLabel(settings: self.settings, gateway: self.gateway)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            EmptyView()
                .frame(width: 1, height: 1)
        }
    }
}

@MainActor
final class KinkoClawAppDelegate: NSObject, NSApplicationDelegate {
    private let settings = PetCompanionSettings.shared
    private let gateway = PetGatewayController.shared

    func applicationDidFinishLaunching(_: Notification) {
        if self.isDuplicateInstance() {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        PetOverlayController.shared.show()
        self.gateway.start()
    }

    func applicationWillTerminate(_: Notification) {
        CharacterStageWindowController.shared.close()
        PetChatPanelController.shared.close()
        PetSettingsWindowController.shared.close()
        PetOverlayController.shared.close()
        self.gateway.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            PetOverlayController.shared.show()
        }
        return true
    }

    private func isDuplicateInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        return running.count > 1
    }
}

@MainActor
enum PetOverlayPanelFactory {
    static func makePanel(
        contentRect: NSRect,
        level: NSWindow.Level,
        hasShadow: Bool,
        acceptsMouseMovedEvents: Bool = false) -> NSPanel
    {
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = hasShadow
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.acceptsMouseMovedEvents = acceptsMouseMovedEvents
        return panel
    }

    static func clearGlobalEventMonitor(_ monitor: inout Any?) {
        if let existing = monitor {
            NSEvent.removeMonitor(existing)
            monitor = nil
        }
    }
}

@MainActor
enum PetWindowPlacement {
    static func bottomRightFrame(size: NSSize, padding: CGFloat, on screen: NSScreen? = NSScreen.main) -> NSRect {
        let bounds = (screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero)
        let x = round(bounds.maxX - size.width - padding)
        let y = round(bounds.minY + padding)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func centeredFrame(size: NSSize, on screen: NSScreen? = NSScreen.main) -> NSRect {
        let bounds = (screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero)
        let x = round(bounds.midX - size.width / 2)
        let y = round(bounds.midY - size.height / 2)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func isFrameVisibleOnAnyScreen(_ frame: NSRect, minimumVisibleArea: CGFloat = 64 * 64) -> Bool {
        NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(frame)
            return !intersection.isNull && intersection.width * intersection.height >= minimumVisibleArea
        }
    }

    static func anchoredChatFrame(
        size: NSSize,
        anchor: NSRect,
        padding: CGFloat,
        in bounds: NSRect) -> NSRect
    {
        let preferredLeft = anchor.minX - size.width - padding
        let fallbackRight = anchor.maxX + padding
        let y = min(max(anchor.midY - size.height * 0.72, bounds.minY), bounds.maxY - size.height)

        let x: CGFloat
        if preferredLeft >= bounds.minX {
            x = preferredLeft
        } else if fallbackRight + size.width <= bounds.maxX {
            x = fallbackRight
        } else {
            x = min(max(bounds.maxX - size.width, bounds.minX), bounds.maxX - size.width)
        }

        return NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
    }
}

@MainActor
final class PetOverlayController {
    static let shared = PetOverlayController()

    private let settings = PetCompanionSettings.shared
    private let gateway = PetGatewayController.shared

    private var window: NSPanel?
    private var hostingView: NSHostingView<PetOverlayView>?
    private var menuTarget = PetContextMenuTarget()
    private let size = NSSize(width: 188, height: 236)
    private var suspendedForStage = false

    private init() {}

    func show() {
        guard !self.suspendedForStage else { return }
        self.ensureWindow()
        self.hostingView?.rootView = PetOverlayView(settings: self.settings, gateway: self.gateway)
        if let window {
            window.contentView?.isHidden = false
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            let defaultFrame = PetWindowPlacement.bottomRightFrame(size: self.size, padding: 18)
            if let origin = self.settings.windowOrigin {
                let savedFrame = NSRect(origin: origin, size: self.size)
                if PetWindowPlacement.isFrameVisibleOnAnyScreen(savedFrame) {
                    window.setFrameOrigin(origin)
                } else {
                    self.settings.resetWindowOrigin()
                    window.setFrame(defaultFrame, display: false)
                }
            } else {
                window.setFrame(defaultFrame, display: false)
            }
            window.orderFrontRegardless()
        }
    }

    func close() {
        self.window?.orderOut(nil)
    }

    func suspendForStage() {
        self.ensureWindow()
        guard !self.suspendedForStage else { return }
        self.suspendedForStage = true
        self.window?.contentView?.isHidden = true
        self.window?.alphaValue = 0
        self.window?.ignoresMouseEvents = true
        self.window?.orderOut(nil)
    }

    func resumeAfterStage() {
        guard self.suspendedForStage else { return }
        self.suspendedForStage = false
        self.window?.contentView?.isHidden = false
        self.window?.alphaValue = 1
        self.window?.ignoresMouseEvents = false
        self.show()
    }

    func currentFrame() -> NSRect? {
        self.window?.frame
    }

    func anchorFrame() -> NSRect? {
        self.window?.frame
    }

    func toggleChatPanel() {
        CharacterStageWindowController.shared.show(anchorFrame: self.anchorFrame())
    }

    func petDidMoveWindow() {
        guard let window else { return }
        self.settings.windowOrigin = window.frame.origin
        if CharacterStageWindowController.shared.isVisible {
            CharacterStageWindowController.shared.reposition(anchorFrame: window.frame)
        }
    }

    func resetToDefaultPosition() {
        guard let window else { return }
        self.settings.resetWindowOrigin()
        let frame = PetWindowPlacement.bottomRightFrame(size: self.size, padding: 18)
        window.setFrame(frame, display: true, animate: true)
        if CharacterStageWindowController.shared.isVisible {
            CharacterStageWindowController.shared.reposition(anchorFrame: window.frame)
        }
    }

    func presentContextMenu(with event: NSEvent, for view: NSView) {
        self.menuTarget.onOpenChat = { [weak self] in self?.toggleChatPanel() }
        self.menuTarget.onOpenSettings = {
            CharacterStageWindowController.shared.openSettings(anchorFrame: PetOverlayController.shared.currentFrame())
        }
        self.menuTarget.onReconnect = {
            Task { @MainActor in
                _ = await PetGatewayController.shared.reconnect(reason: "context-menu")
            }
        }
        self.menuTarget.onResetPosition = { [weak self] in
            self?.resetToDefaultPosition()
        }
        self.menuTarget.onQuit = { NSApp.terminate(nil) }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Stage", action: #selector(PetContextMenuTarget.openChat), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Debug Text Chat", action: #selector(PetContextMenuTarget.openDebugChat), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(PetContextMenuTarget.openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reconnect", action: #selector(PetContextMenuTarget.reconnect), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())

        let packsMenu = NSMenu(title: "Live2D Model")
        for pack in self.settings.availablePacks {
            let item = NSMenuItem(title: pack.displayName, action: #selector(PetContextMenuTarget.selectPack(_:)), keyEquivalent: "")
            item.target = self.menuTarget
            item.representedObject = pack.id
            item.state = self.settings.selectedPackId == pack.id ? .on : .off
            packsMenu.addItem(item)
        }
        let packsItem = NSMenuItem(title: "Live2D Model", action: nil, keyEquivalent: "")
        menu.addItem(packsItem)
        menu.setSubmenu(packsMenu, for: packsItem)

        menu.addItem(NSMenuItem(title: "Reset Position", action: #selector(PetContextMenuTarget.resetPosition), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit KinkoClaw", action: #selector(PetContextMenuTarget.quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = item.target ?? self.menuTarget
        }
        self.menuTarget.onSelectPack = { packID in
            PetCompanionSettings.shared.selectedLive2DModelId = packID
            CharacterStageWindowController.shared.refreshAppearance()
            PetChatPanelController.shared.refreshAppearance()
        }
        self.menuTarget.onOpenDebugChat = {
            PetChatPanelController.shared.toggle(anchorFrame: PetOverlayController.shared.currentFrame())
        }

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func ensureWindow() {
        if self.window != nil { return }

        let panel = PetOverlayPanelFactory.makePanel(
            contentRect: NSRect(origin: .zero, size: self.size),
            level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 6),
            hasShadow: false,
            acceptsMouseMovedEvents: true)

        let host = NSHostingView(rootView: PetOverlayView(settings: self.settings, gateway: self.gateway))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        self.hostingView = host
        self.window = panel
    }
}

@MainActor
final class PetChatPanelController {
    static let shared = PetChatPanelController()

    private let settings = PetCompanionSettings.shared
    private let gateway = PetGatewayController.shared
    private let transport = PetChatTransport(gateway: PetGatewayController.shared)

    private var window: NSPanel?
    private var hostingController: NSHostingController<KinkoChatPanelView>?
    private var viewModel: KinkoChatPanelViewModel?
    private var dismissMonitor: Any?
    private let panelSize = NSSize(width: 440, height: 620)

    private init() {}

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
        self.refreshAppearance()
        self.viewModel?.activate()
        self.reposition(anchorFrame: anchorFrame)
        self.window?.orderFrontRegardless()
        self.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        self.installDismissMonitor()
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
                padding: 14,
                in: bounds)
        } else {
            frame = PetWindowPlacement.centeredFrame(size: self.panelSize, on: screen)
        }
        window.setFrame(frame, display: true)
    }

    func close() {
        self.window?.orderOut(nil)
        self.removeDismissMonitor()
        self.viewModel?.deactivate()
    }

    func refreshAppearance() {
        self.ensureWindow()
        if self.viewModel == nil {
            self.viewModel = KinkoChatPanelViewModel(
                gateway: self.gateway,
                transport: self.transport)
        }

        let accent = PetHexColorSupport.color(from: self.settings.selectedPack.accentHex)
        if let viewModel, let hostingController {
            hostingController.rootView = KinkoChatPanelView(
                viewModel: viewModel,
                accent: accent)
        }
    }

    private func ensureWindow() {
        if self.window != nil { return }
        if self.viewModel == nil {
            self.viewModel = KinkoChatPanelViewModel(
                gateway: self.gateway,
                transport: self.transport)
        }

        let accent = PetHexColorSupport.color(from: self.settings.selectedPack.accentHex)
        let hostingController = NSHostingController(rootView: KinkoChatPanelView(
            viewModel: self.viewModel!,
            accent: accent))
        self.hostingController = hostingController

        let container = NSViewController()
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        effect.layer?.cornerCurve = .continuous
        effect.translatesAutoresizingMaskIntoConstraints = true
        effect.autoresizingMask = [.width, .height]

        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.cornerRadius = 22
        hostingController.view.layer?.cornerCurve = .continuous
        hostingController.view.layer?.masksToBounds = true

        container.addChild(hostingController)
        effect.addSubview(hostingController.view)
        container.view = effect

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: effect.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let panel = PetOverlayPanelFactory.makePanel(
            contentRect: NSRect(origin: .zero, size: self.panelSize),
            level: .statusBar,
            hasShadow: true)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = container
        self.window = panel
    }

    private func installDismissMonitor() {
        guard self.dismissMonitor == nil, self.window != nil else { return }
        self.dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let window = self.window else { return }
            let point = NSEvent.mouseLocation
            let overlayContainsPoint = PetOverlayController.shared.anchorFrame()?.contains(point) ?? false
            if !window.frame.contains(point) && !overlayContainsPoint {
                self.close()
            }
        }
    }

    private func removeDismissMonitor() {
        PetOverlayPanelFactory.clearGlobalEventMonitor(&self.dismissMonitor)
    }
}

@MainActor
final class PetSettingsWindowController {
    static let shared = PetSettingsWindowController()

    private let settings = PetCompanionSettings.shared
    private let gateway = PetGatewayController.shared

    private var window: NSWindow?
    private var hostingController: NSHostingController<PetSettingsView>?

    private init() {}

    func show(onboarding: Bool) {
        self.ensureWindow(onboarding: onboarding)
        self.hostingController?.rootView = PetSettingsView(
            settings: self.settings,
            gateway: self.gateway,
            onboarding: onboarding,
            onClose: { [weak self] in self?.close() })
        self.window?.title = onboarding ? "Connect to Existing OpenClaw" : "KinkoClaw Settings"
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        self.window?.orderOut(nil)
    }

    private func ensureWindow(onboarding: Bool) {
        if let window {
            window.title = onboarding ? "Connect to Existing OpenClaw" : "KinkoClaw Settings"
            return
        }

        let hosting = NSHostingController(rootView: PetSettingsView(
            settings: self.settings,
            gateway: self.gateway,
            onboarding: onboarding,
            onClose: { [weak self] in self?.close() }))
        self.hostingController = hosting

        let window = NSWindow(
            contentRect: PetWindowPlacement.centeredFrame(size: NSSize(width: 540, height: 680)),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = onboarding ? "Connect to Existing OpenClaw" : "KinkoClaw Settings"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }
}

@MainActor
private final class PetContextMenuTarget: NSObject {
    var onOpenChat: (() -> Void)?
    var onOpenDebugChat: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onResetPosition: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSelectPack: ((String) -> Void)?

    @objc func openChat() { self.onOpenChat?() }
    @objc func openDebugChat() { self.onOpenDebugChat?() }
    @objc func openSettings() { self.onOpenSettings?() }
    @objc func reconnect() { self.onReconnect?() }
    @objc func resetPosition() { self.onResetPosition?() }
    @objc func quit() { self.onQuit?() }
    @objc func selectPack(_ sender: NSMenuItem) {
        if let packID = sender.representedObject as? String {
            self.onSelectPack?(packID)
        }
    }
}

struct PetMenuBarContent: View {
    @Bindable var settings: PetCompanionSettings
    @Bindable var gateway: PetGatewayController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(self.statusTitle, systemImage: self.statusImage)
                .font(.headline)
            Text(self.gateway.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Open Stage") {
                CharacterStageWindowController.shared.show(anchorFrame: PetOverlayController.shared.currentFrame())
            }
            Button("Debug Text Chat") {
                PetChatPanelController.shared.toggle(anchorFrame: PetOverlayController.shared.currentFrame())
            }
            Button("Settings…") {
                CharacterStageWindowController.shared.openSettings(anchorFrame: PetOverlayController.shared.currentFrame())
            }
            Button("Reconnect") {
                Task { @MainActor in
                    _ = await self.gateway.reconnect(reason: "menu-bar")
                }
            }

            Menu("Live2D Model") {
                ForEach(self.settings.availablePacks, id: \.id) { pack in
                    Button(pack.displayName) {
                        self.settings.selectedLive2DModelId = pack.id
                        CharacterStageWindowController.shared.refreshAppearance()
                        PetChatPanelController.shared.refreshAppearance()
                    }
                }
            }

            Toggle("Launch at login", isOn: self.$settings.launchAtLogin)

            Divider()

            Button("Quit KinkoClaw") {
                NSApp.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 250, alignment: .leading)
    }

    private var statusTitle: String {
        switch self.gateway.connectionStatus {
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting…"
        case .connected:
            "Connected"
        case let .error(message):
            message.isEmpty ? "Connection Error" : "Connection Error"
        }
    }

    private var statusImage: String {
        switch self.gateway.connectionStatus {
        case .connected:
            "checkmark.circle.fill"
        case .connecting:
            "arrow.triangle.2.circlepath.circle.fill"
        case .error:
            "exclamationmark.triangle.fill"
        case .disconnected:
            "bolt.slash.fill"
        }
    }
}

struct PetMenuBarLabel: View {
    @Bindable var settings: PetCompanionSettings
    @Bindable var gateway: PetGatewayController

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(.primary.opacity(0.12))
                    .frame(width: 18, height: 18)

                Image(systemName: "pawprint.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 11, weight: .bold))
            }

            Circle()
                .fill(self.statusColor)
                .overlay(
                    Circle()
                        .stroke(.regularMaterial, lineWidth: 1))
                .frame(width: 7, height: 7)
                .offset(x: 1, y: 1)
        }
        .frame(width: 19, height: 19)
            .help(self.tooltip)
    }

    private var statusColor: Color {
        switch self.gateway.connectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .error:
            return .red
        case .disconnected:
            return .gray
        }
    }

    private var tooltip: String {
        switch self.gateway.connectionStatus {
        case .connected:
            return "KinkoClaw connected"
        case .connecting:
            return "KinkoClaw connecting"
        case let .error(message):
            return message.isEmpty ? "KinkoClaw connection error" : "KinkoClaw: \(message)"
        case .disconnected:
            return "KinkoClaw disconnected"
        }
    }
}

struct PetOverlayView: View {
    @Bindable var settings: PetCompanionSettings
    @Bindable var gateway: PetGatewayController
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PetLive2DOverlayView(
                pack: self.settings.selectedPack,
                presenceState: self.gateway.presenceState,
                connectionStatus: self.gateway.connectionStatus,
                statusMessage: self.gateway.statusMessage)
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .padding(.bottom, 6)

            if self.hovering {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(self.settings.selectedPack.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(self.overlayStatusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 2)
                .padding(.trailing, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            PetInteractionOverlay(
                onSingleClick: {
                    PetOverlayController.shared.toggleChatPanel()
                },
                onContextMenu: { event, view in
                    PetOverlayController.shared.presentContextMenu(with: event, for: view)
                },
                onDragStart: {
                    CharacterStageWindowController.shared.close()
                    PetChatPanelController.shared.close()
                },
                onDragEnd: {
                    PetOverlayController.shared.petDidMoveWindow()
                })
        }
        .frame(width: 188, height: 236)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onHover { self.hovering = $0 }
    }

    private var overlayStatusText: String {
        switch self.gateway.presenceState {
        case .disconnected:
            "Offline"
        case .idle:
            "Ready"
        case .thinking:
            "Thinking"
        case .replying:
            "Replying"
        case .error:
            "Needs attention"
        }
    }
}

private struct PetInteractionOverlay: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onContextMenu: (NSEvent, NSView) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PetInteractionNSView()
        view.onSingleClick = self.onSingleClick
        view.onContextMenu = self.onContextMenu
        view.onDragStart = self.onDragStart
        view.onDragEnd = self.onDragEnd
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PetInteractionNSView else { return }
        view.onSingleClick = self.onSingleClick
        view.onContextMenu = self.onContextMenu
        view.onDragStart = self.onDragStart
        view.onDragEnd = self.onDragEnd
    }
}

private final class PetInteractionNSView: NSView {
    var onSingleClick: (() -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        self.mouseDownEvent = event
        self.didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = self.mouseDownEvent else { return }
        if !self.didDrag {
            let dx = event.locationInWindow.x - start.locationInWindow.x
            let dy = event.locationInWindow.y - start.locationInWindow.y
            if abs(dx) + abs(dy) < 2 { return }
            self.didDrag = true
            self.onDragStart?()
            self.window?.performDrag(with: start)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !self.didDrag {
            self.onSingleClick?()
        } else {
            self.onDragEnd?()
        }
        self.mouseDownEvent = nil
        self.didDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        self.onContextMenu?(event, self)
    }
}

struct PetCharacterView: View {
    let pack: PetPackManifest
    let presenceState: PetPresenceState
    let compact: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let bob = sin(time * self.pack.animationProfile.floatSpeed) * self.pack.animationProfile.floatAmplitude
            let scale = self.presenceState == .thinking ? 1.018 : 1.0
            let glowColor = PetHexColorSupport.color(from: self.pack.assets.glowHex)

            ZStack(alignment: .bottomTrailing) {
                self.characterBody(time: time, glowColor: glowColor)
                    .scaleEffect(scale)
                    .offset(y: self.compact ? 0 : bob)
                    .opacity(self.presenceState == .disconnected ? 0.72 : 1)
                    .saturation(self.presenceState == .disconnected ? 0.2 : 1)

                self.stateOverlay(time: time, badgeColor: glowColor)
                    .padding(self.compact ? 2 : 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func characterBody(time: TimeInterval, glowColor: Color) -> some View {
        let hairColor = PetHexColorSupport.color(from: self.pack.assets.hairHex)
        let hairShadowColor = PetHexColorSupport.color(from: self.pack.assets.hairShadowHex)
        let skinColor = PetHexColorSupport.color(from: self.pack.assets.skinHex)
        let eyeColor = PetHexColorSupport.color(from: self.pack.assets.eyeHex)
        let outfitColor = PetHexColorSupport.color(from: self.pack.assets.outfitHex)
        let ribbonColor = PetHexColorSupport.color(from: self.pack.assets.ribbonHex)
        let blink = self.shouldBlink(time: time)
        let sway = sin(time * self.pack.animationProfile.focusSwaySpeed) * (self.compact ? 0.7 : 1.7)

        ZStack(alignment: .bottom) {
            ZStack {
                Circle()
                    .fill(glowColor.opacity(self.compact ? 0.2 : 0.28))
                    .frame(width: self.compact ? 58 : 124, height: self.compact ? 58 : 124)
                    .blur(radius: self.compact ? 8 : 18)
                    .offset(y: self.compact ? -4 : -10)
                Circle()
                    .stroke(glowColor.opacity(0.35), lineWidth: self.compact ? 1 : 2)
                    .frame(width: self.compact ? 46 : 92, height: self.compact ? 46 : 92)
                    .blur(radius: self.compact ? 1.2 : 2)
                    .offset(y: self.compact ? -5 : -12)
            }
            .opacity(self.presenceState == .thinking || self.presenceState == .replying ? 1 : 0.45)

            ZStack(alignment: .bottom) {
                self.outfit(outfitColor: outfitColor, ribbonColor: ribbonColor)
                    .offset(y: self.compact ? 8 : 18)

                self.hairBack(hairColor: hairColor, hairShadowColor: hairShadowColor)
                    .rotationEffect(.degrees(sway))
                    .offset(y: self.compact ? -2 : -5)

                self.face(skinColor: skinColor)
                    .rotationEffect(.degrees(sway * 0.45))
                    .offset(y: self.compact ? -2 : -4)

                self.frontHair(hairColor: hairColor, hairShadowColor: hairShadowColor)
                    .rotationEffect(.degrees(sway * 0.65))
                    .offset(y: self.compact ? -10 : -21)

                self.expression(eyeColor: eyeColor, blink: blink)
                    .rotationEffect(.degrees(sway * 0.18))
                    .offset(y: self.compact ? -2 : -2)

                self.ribbon(color: ribbonColor, mirrored: false)
                    .offset(x: self.compact ? -16 : -34, y: self.compact ? -4 : -8)
                self.ribbon(color: ribbonColor, mirrored: true)
                    .offset(x: self.compact ? 16 : 34, y: self.compact ? -4 : -8)
            }
        }
        .padding(.horizontal, self.compact ? 4 : 10)
    }

    private func hairBack(hairColor: Color, hairShadowColor: Color) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: self.compact ? 18 : 36, style: .continuous)
                .fill(hairShadowColor.opacity(0.92))
                .frame(width: self.compact ? 56 : 118, height: self.compact ? 50 : 102)
                .offset(y: self.compact ? 6 : 12)
            RoundedRectangle(cornerRadius: self.compact ? 18 : 36, style: .continuous)
                .fill(hairColor.gradient)
                .frame(width: self.compact ? 54 : 112, height: self.compact ? 46 : 96)
            HStack(spacing: self.compact ? 22 : 48) {
                RoundedRectangle(cornerRadius: self.compact ? 14 : 28, style: .continuous)
                    .fill(hairColor.opacity(0.95))
                    .frame(width: self.compact ? 14 : 30, height: self.compact ? 40 : 82)
                    .rotationEffect(.degrees(-8))
                RoundedRectangle(cornerRadius: self.compact ? 14 : 28, style: .continuous)
                    .fill(hairColor.opacity(0.95))
                    .frame(width: self.compact ? 14 : 30, height: self.compact ? 40 : 82)
                    .rotationEffect(.degrees(8))
            }
            .offset(y: self.compact ? 12 : 20)
        }
    }

    private func face(skinColor: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.compact ? 16 : 34, style: .continuous)
                .fill(skinColor.gradient)
                .overlay {
                    RoundedRectangle(cornerRadius: self.compact ? 16 : 34, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: self.compact ? 1 : 2)
                }
                .frame(width: self.compact ? 42 : 88, height: self.compact ? 42 : 88)
            Circle()
                .fill(.white.opacity(0.28))
                .frame(width: self.compact ? 9 : 18, height: self.compact ? 9 : 18)
                .offset(x: self.compact ? -8 : -16, y: self.compact ? -10 : -18)
        }
    }

    private func frontHair(hairColor: Color, hairShadowColor: Color) -> some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(hairColor.gradient)
                .frame(width: self.compact ? 46 : 98, height: self.compact ? 26 : 54)
            HStack(spacing: self.compact ? -1 : -2) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: self.compact ? 7 : 14, style: .continuous)
                        .fill(index.isMultiple(of: 2) ? hairShadowColor.opacity(0.9) : hairColor)
                        .frame(width: self.compact ? 8 : 16, height: self.compact ? 18 : 36)
                        .rotationEffect(.degrees(index == 0 ? -10 : (index == 4 ? 10 : 0)))
                }
            }
            .offset(y: self.compact ? 10 : 18)
        }
    }

    private func expression(eyeColor: Color, blink: Bool) -> some View {
        VStack(spacing: self.compact ? 3 : 6) {
            HStack(spacing: self.compact ? 10 : 20) {
                self.eye(color: eyeColor, blink: blink, mirrored: false)
                self.eye(color: eyeColor, blink: blink, mirrored: true)
            }
            self.mouth(color: eyeColor)
        }
        .offset(y: self.compact ? 0 : 2)
    }

    @ViewBuilder
    private func eye(color: Color, blink: Bool, mirrored _: Bool) -> some View {
        if blink || self.presenceState == .disconnected {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.opacity(0.92))
                .frame(width: self.compact ? 7 : 13, height: self.compact ? 1.6 : 3)
        } else {
            switch self.presenceState {
            case .thinking:
                RoundedRectangle(cornerRadius: self.compact ? 4 : 6, style: .continuous)
                    .fill(color.opacity(0.92))
                    .frame(width: self.compact ? 7 : 13, height: self.compact ? 4 : 8)
            case .replying:
                VStack(spacing: self.compact ? 0.6 : 1.2) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color.opacity(0.9))
                        .frame(width: self.compact ? 8 : 16, height: self.compact ? 1.8 : 3)
                    Circle()
                        .fill(color)
                        .frame(width: self.compact ? 5 : 9, height: self.compact ? 5 : 9)
                }
            default:
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: self.compact ? 7 : 13, height: self.compact ? 8 : 14)
                    .overlay(alignment: .top) {
                        Circle()
                            .fill(.white.opacity(0.92))
                            .frame(width: self.compact ? 2 : 4, height: self.compact ? 2 : 4)
                            .offset(y: self.compact ? 1 : 2)
                    }
            }
        }
    }

    @ViewBuilder
    private func mouth(color: Color) -> some View {
        switch self.presenceState {
        case .replying:
            Capsule()
                .fill(color.opacity(0.18))
                .frame(width: self.compact ? 10 : 18, height: self.compact ? 2.2 : 4)
        case .thinking:
            Circle()
                .fill(color.opacity(0.34))
                .frame(width: self.compact ? 3 : 5, height: self.compact ? 3 : 5)
        default:
            RoundedRectangle(cornerRadius: self.compact ? 2 : 4, style: .continuous)
                .fill(color.opacity(0.18))
                .frame(width: self.compact ? 10 : 18, height: self.compact ? 1.8 : 3)
        }
    }

    private func outfit(outfitColor: Color, ribbonColor: Color) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: self.compact ? 16 : 30, style: .continuous)
                .fill(outfitColor.gradient)
                .frame(width: self.compact ? 58 : 120, height: self.compact ? 26 : 54)
            RoundedRectangle(cornerRadius: self.compact ? 8 : 14, style: .continuous)
                .fill(.white.opacity(0.16))
                .frame(width: self.compact ? 18 : 40, height: self.compact ? 8 : 14)
                .offset(y: self.compact ? 5 : 10)
            VStack(spacing: self.compact ? 1 : 2) {
                Triangle()
                    .fill(ribbonColor)
                    .frame(width: self.compact ? 7 : 14, height: self.compact ? 8 : 16)
                RoundedRectangle(cornerRadius: self.compact ? 3 : 6, style: .continuous)
                    .fill(ribbonColor.opacity(0.95))
                    .frame(width: self.compact ? 4 : 8, height: self.compact ? 8 : 18)
            }
            .offset(y: self.compact ? 4 : 7)
        }
    }

    private func ribbon(color: Color, mirrored: Bool) -> some View {
        HStack(spacing: self.compact ? -2 : -3) {
            Triangle()
                .fill(color.opacity(0.92))
                .frame(width: self.compact ? 8 : 16, height: self.compact ? 9 : 18)
                .rotationEffect(.degrees(mirrored ? 94 : -94))
            Triangle()
                .fill(color.opacity(0.78))
                .frame(width: self.compact ? 7 : 14, height: self.compact ? 8 : 16)
                .rotationEffect(.degrees(mirrored ? 34 : -34))
        }
    }

    @ViewBuilder
    private func stateOverlay(time: TimeInterval, badgeColor: Color) -> some View {
        switch self.presenceState {
        case .idle, .disconnected:
            EmptyView()
        case .thinking:
            ZStack {
                Circle()
                    .stroke(badgeColor.opacity(0.35), lineWidth: self.compact ? 1 : 2)
                    .frame(width: self.compact ? 12 : 26, height: self.compact ? 12 : 26)
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(badgeColor.opacity(0.9))
                        .frame(width: self.compact ? 2.4 : 5, height: self.compact ? 2.4 : 5)
                        .offset(
                            x: cos(time * self.pack.animationProfile.thinkingHaloSpeed * 4 + Double(index) * 2.1) * (self.compact ? 5 : 11),
                            y: sin(time * self.pack.animationProfile.thinkingHaloSpeed * 4 + Double(index) * 2.1) * (self.compact ? 5 : 11))
                }
            }
        case .replying:
            ZStack {
                RoundedRectangle(cornerRadius: self.compact ? 5 : 10, style: .continuous)
                    .fill(badgeColor)
                    .frame(width: self.compact ? 18 : 38, height: self.compact ? 12 : 24)
                HStack(spacing: self.compact ? 2 : 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(.white.opacity(0.95))
                            .frame(width: self.compact ? 2 : 4, height: self.compact ? 2 : 4)
                            .offset(y: sin(time * 6 + Double(index)) * (self.compact ? 0.5 : 1.2))
                    }
                }
            }
        case .error:
            ZStack {
                Circle()
                    .fill(.red.gradient)
                    .frame(width: self.compact ? 16 : 30, height: self.compact ? 16 : 30)
                Image(systemName: "exclamationmark")
                    .font(.system(size: self.compact ? 8 : 14, weight: .black))
                    .foregroundStyle(.white)
            }
        }
    }

    private func shouldBlink(time: TimeInterval) -> Bool {
        let blinkEvery = max(self.pack.animationProfile.blinkEvery, 2.5)
        let progress = time.truncatingRemainder(dividingBy: blinkEvery)
        return progress < 0.18
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct PetSettingsView: View {
    @Bindable var settings: PetCompanionSettings
    @Bindable var gateway: PetGatewayController
    let onboarding: Bool
    let onClose: () -> Void

    @State private var isSubmitting = false
    @State private var feedbackMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if self.onboarding {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect to Existing OpenClaw")
                        .font(.system(size: 22, weight: .bold))
                    Text("KinkoClaw now hosts an AIRI-style stage. Point it at an OpenClaw gateway that already exists on this Mac or on a remote host, and the character stage will stay attached to the same `main` assistant.")
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                Section("Connection") {
                    Picker("Mode", selection: self.$settings.connectionMode) {
                        ForEach(GatewayConnectionProfile.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(self.settings.connectionMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Gateway port")
                        Spacer()
                        TextField(
                            "18789",
                            text: Binding(
                                get: { String(self.settings.localPort) },
                                set: { self.settings.localPort = Int($0) ?? 18789 }))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)
                    }

                    if self.settings.connectionMode == .sshTunnel {
                        TextField("user@host[:22]", text: self.$settings.sshTarget)
                        TextField("~/.ssh/id_ed25519 (optional)", text: self.$settings.sshIdentityPath)
                    }

                    if self.settings.connectionMode == .directWss {
                        TextField("wss://gateway.example.ts.net", text: self.$settings.directGatewayURL)
                        Text("Direct mode only supports remote `wss://` gateways. Use Local or SSH Tunnel for `ws://127.0.0.1`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SecureField("Gateway auth token (optional)", text: self.$settings.gatewayAuthToken)

                    HStack(spacing: 10) {
                        Button(self.onboarding ? "Save and Connect" : "Reconnect") {
                            Task { await self.submit(closeOnSuccess: self.onboarding) }
                        }
                        .disabled(self.isSubmitting || !self.settings.isConnectionProfileComplete)

                        Button("Test Connection") {
                            Task { await self.submit(closeOnSuccess: false) }
                        }
                        .disabled(self.isSubmitting || !self.settings.isConnectionProfileComplete)

                        if self.isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let feedbackMessage {
                        Text(feedbackMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(self.gateway.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Live2D 模型") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(self.settings.availablePacks, id: \.id) { pack in
                            Button {
                                self.settings.selectedPackId = pack.id
                                CharacterStageWindowController.shared.refreshAppearance()
                                PetChatPanelController.shared.refreshAppearance()
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    PetCharacterView(
                                        pack: pack,
                                        presenceState: .idle,
                                        compact: false)
                                        .frame(height: 88)
                                        .frame(maxWidth: .infinity)
                                    Text(pack.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(pack.interactionProfile.personaLabel)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(pack.id == self.settings.selectedPackId
                                            ? PetHexColorSupport.color(from: pack.accentHex).opacity(0.18)
                                            : Color.secondary.opacity(0.08)))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(pack.id == self.settings.selectedPackId
                                            ? PetHexColorSupport.color(from: pack.accentHex)
                                            : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("App") {
                    Toggle("Launch at login", isOn: self.$settings.launchAtLogin)
                    Text("KinkoClaw always stays in the menu bar so the desktop pet never loses its main entry point.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let launchAtLoginErrorMessage = self.settings.launchAtLoginErrorMessage,
                       !launchAtLoginErrorMessage.isEmpty
                    {
                        Text(launchAtLoginErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Launch at login only works once KinkoClaw is packaged as an app bundle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button(self.onboarding ? "Later" : "Done") {
                    self.onClose()
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 640, alignment: .topLeading)
    }

    private func submit(closeOnSuccess: Bool) async {
        self.isSubmitting = true
        self.feedbackMessage = nil
        defer { self.isSubmitting = false }

        let success = await self.gateway.reconnect(reason: closeOnSuccess ? "onboarding" : "manual")
        if success {
            self.settings.hasCompletedOnboarding = true
            self.feedbackMessage = "Connected to \(self.settings.connectionSummary)"
            PetChatPanelController.shared.refreshAppearance()
            if closeOnSuccess {
                self.onClose()
            }
        } else {
            self.feedbackMessage = self.gateway.lastErrorMessage ?? "Connection failed"
        }
    }
}
