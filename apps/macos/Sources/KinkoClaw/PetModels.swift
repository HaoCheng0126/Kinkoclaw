import AppKit
import Observation
import OpenClawKit
import ServiceManagement
import SwiftUI

enum GatewayConnectionProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case sshTunnel
    case direct

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .local: "Local"
        case .sshTunnel: "SSH Tunnel"
        case .direct: "Direct wss"
        }
    }

    var subtitle: String {
        switch self {
        case .local: "Connect to a local gateway running on this Mac."
        case .sshTunnel: "Forward a remote gateway to localhost over SSH."
        case .direct: "Connect straight to a remote wss:// gateway."
        }
    }
}

enum PetPresenceState: String, Codable, CaseIterable, Sendable {
    case disconnected
    case idle
    case listening
    case hearing
    case thinking
    case replying
    case speaking
    case error
}

struct PetPackManifest: Identifiable, Codable, Hashable, Sendable {
    struct Assets: Codable, Hashable, Sendable {
        let hairHex: String
        let hairShadowHex: String
        let skinHex: String
        let eyeHex: String
        let ribbonHex: String
        let outfitHex: String
        let glowHex: String
    }

    struct AnimationProfile: Codable, Hashable, Sendable {
        let floatAmplitude: Double
        let floatSpeed: Double
        let blinkEvery: Double
        let focusSwaySpeed: Double
        let thinkingHaloSpeed: Double
        let mouthSmoothing: Double
    }

    struct StageModelManifest: Codable, Hashable, Sendable {
        let modelPath: String
        let textures: [String]
        let motions: [String: [String]]
        let expressions: [String: String]
    }

    struct VoiceProfile: Codable, Hashable, Sendable {
        let localeID: String
        let ttsStyle: String
        let subtitlePrefix: String
    }

    struct InteractionProfile: Codable, Hashable, Sendable {
        let personaLabel: String
        let pointerFollowStrength: Double
        let shimmerIntensity: Double
        let breathingScale: Double
    }

    let id: String
    let displayName: String
    let accentHex: String
    let assets: Assets
    let animationProfile: AnimationProfile
    let model: StageModelManifest
    let voiceProfile: VoiceProfile
    let interactionProfile: InteractionProfile
}

enum PetPackRegistry {
    static let packs: [PetPackManifest] = [
        PetPackManifest(
            id: "airi-classic",
            displayName: "AIRI Classic",
            accentHex: "#FF6B9B",
            assets: .init(
                hairHex: "#F6B0CF",
                hairShadowHex: "#D85D90",
                skinHex: "#FFF1EC",
                eyeHex: "#5D223D",
                ribbonHex: "#FF6B9B",
                outfitHex: "#5A2142",
                glowHex: "#FFD4E3"),
            animationProfile: .init(
                floatAmplitude: 5,
                floatSpeed: 1.05,
                blinkEvery: 4.5,
                focusSwaySpeed: 0.9,
                thinkingHaloSpeed: 0.85,
                mouthSmoothing: 0.78),
            model: .init(
                modelPath: "models/hiyori_free_zh/runtime/hiyori_free_t08.model3.json",
                textures: [
                    "hiyori_free_zh/runtime/hiyori_free_t08.2048/texture_00.png",
                ],
                motions: [
                    "idle": ["Idle:0", "Idle:1", "Idle:2"],
                    "listening": ["Flick:0"],
                    "hearing": ["FlickDown:0"],
                    "thinking": ["Flick:0"],
                    "replying": ["Tap:0"],
                    "speaking": ["Tap@Body:0"],
                    "error": ["FlickDown:0"],
                ],
                expressions: [
                    "idle": "neutral",
                    "listening": "curious",
                    "hearing": "surprised",
                    "thinking": "think",
                    "replying": "happy",
                    "speaking": "smile",
                    "error": "awkward",
                ]),
            voiceProfile: .init(
                localeID: "zh-CN",
                ttsStyle: "dreamy",
                subtitlePrefix: "AIRI"),
            interactionProfile: .init(
                personaLabel: "Dreamlink Core",
                pointerFollowStrength: 0.32,
                shimmerIntensity: 0.86,
                breathingScale: 1.024)),
        PetPackManifest(
            id: "airi-twilight",
            displayName: "AIRI Twilight",
            accentHex: "#7D7BFF",
            assets: .init(
                hairHex: "#C7C6FF",
                hairShadowHex: "#6D64D7",
                skinHex: "#FDF3FF",
                eyeHex: "#3F3365",
                ribbonHex: "#7D7BFF",
                outfitHex: "#2B234D",
                glowHex: "#D9D7FF"),
            animationProfile: .init(
                floatAmplitude: 4,
                floatSpeed: 0.92,
                blinkEvery: 5.2,
                focusSwaySpeed: 0.72,
                thinkingHaloSpeed: 0.68,
                mouthSmoothing: 0.72),
            model: .init(
                modelPath: "models/hiyori_free_zh/runtime/hiyori_free_t08.model3.json",
                textures: [
                    "hiyori_free_zh/runtime/hiyori_free_t08.2048/texture_00.png",
                ],
                motions: [
                    "idle": ["Idle:0", "Idle:1", "Idle:2"],
                    "listening": ["Flick:0"],
                    "hearing": ["FlickDown:0"],
                    "thinking": ["Flick:0"],
                    "replying": ["Tap:0"],
                    "speaking": ["Tap@Body:0"],
                    "error": ["FlickDown:0"],
                ],
                expressions: [
                    "idle": "neutral",
                    "listening": "curious",
                    "hearing": "question",
                    "thinking": "think",
                    "replying": "happy",
                    "speaking": "smile",
                    "error": "sad",
                ]),
            voiceProfile: .init(
                localeID: "en-US",
                ttsStyle: "velvet",
                subtitlePrefix: "AIRI"),
            interactionProfile: .init(
                personaLabel: "Nocturne Link",
                pointerFollowStrength: 0.28,
                shimmerIntensity: 0.72,
                breathingScale: 1.02)),
        PetPackManifest(
            id: "airi-sunrise",
            displayName: "AIRI Sunrise",
            accentHex: "#FF8B5E",
            assets: .init(
                hairHex: "#FFD39B",
                hairShadowHex: "#FF8B5E",
                skinHex: "#FFF1E8",
                eyeHex: "#6A2A20",
                ribbonHex: "#FF8B5E",
                outfitHex: "#7A3044",
                glowHex: "#FFE5BC"),
            animationProfile: .init(
                floatAmplitude: 6,
                floatSpeed: 1.18,
                blinkEvery: 4.1,
                focusSwaySpeed: 1.06,
                thinkingHaloSpeed: 0.92,
                mouthSmoothing: 0.8),
            model: .init(
                modelPath: "models/hiyori_free_zh/runtime/hiyori_free_t08.model3.json",
                textures: [
                    "hiyori_free_zh/runtime/hiyori_free_t08.2048/texture_00.png",
                ],
                motions: [
                    "idle": ["Idle:0", "Idle:1", "Idle:2"],
                    "listening": ["Flick:0"],
                    "hearing": ["FlickDown:0"],
                    "thinking": ["Flick:0"],
                    "replying": ["Tap:0"],
                    "speaking": ["Tap@Body:0"],
                    "error": ["FlickDown:0"],
                ],
                expressions: [
                    "idle": "neutral",
                    "listening": "curious",
                    "hearing": "surprised",
                    "thinking": "think",
                    "replying": "happy",
                    "speaking": "smile",
                    "error": "awkward",
                ]),
            voiceProfile: .init(
                localeID: "ja-JP",
                ttsStyle: "spark",
                subtitlePrefix: "AIRI"),
            interactionProfile: .init(
                personaLabel: "Solar Bloom",
                pointerFollowStrength: 0.34,
                shimmerIntensity: 0.92,
                breathingScale: 1.028)),
    ]

    static var defaultPack: PetPackManifest {
        self.packs[0]
    }

    static func pack(for id: String) -> PetPackManifest {
        self.packs.first(where: { $0.id == id }) ?? self.defaultPack
    }
}

enum PetHexColorSupport {
    static func nsColor(from raw: String) -> NSColor? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        let hex: String
        switch trimmed.count {
        case 3:
            hex = trimmed.map { "\($0)\($0)" }.joined()
        case 6, 8:
            hex = trimmed
        default:
            return nil
        }

        guard let value = UInt64(hex, radix: 16) else { return nil }

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        if hex.count == 8 {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        } else {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }

        return NSColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha))
    }

    static func color(from raw: String) -> Color {
        Color(nsColor: self.nsColor(from: raw) ?? .systemOrange)
    }
}

@MainActor
@Observable
final class PetCompanionSettings {
    static let shared = PetCompanionSettings()

    private enum Keys {
        static let connectionMode = "kinkoclaw.connectionMode"
        static let localPort = "kinkoclaw.localPort"
        static let sshTarget = "kinkoclaw.sshTarget"
        static let sshIdentityPath = "kinkoclaw.sshIdentityPath"
        static let directGatewayURL = "kinkoclaw.directGatewayURL"
        static let gatewayAuthTokenRef = "kinkoclaw.gatewayAuthTokenRef"
        static let selectedPackId = "kinkoclaw.selectedPackId"
        static let launchAtLogin = "kinkoclaw.launchAtLogin"
        static let windowOriginX = "kinkoclaw.windowOriginX"
        static let windowOriginY = "kinkoclaw.windowOriginY"
        static let lastGatewayMode = "kinkoclaw.lastGatewayMode"
        static let hasCompletedOnboarding = "kinkoclaw.hasCompletedOnboarding"
        static let lastConnectionSucceededAt = "kinkoclaw.lastConnectionSucceededAt"
    }

    private enum Keychain {
        static let service = "ai.openclaw.kinkoclaw"
    }

    @ObservationIgnored
    private let defaults = UserDefaults.standard
    @ObservationIgnored
    private var isInitializing = true

    var connectionMode: GatewayConnectionProfile {
        didSet { self.persistString(self.connectionMode.rawValue, key: Keys.connectionMode) }
    }

    var localPort: Int {
        didSet {
            let clamped = min(max(self.localPort, 1), 65535)
            if clamped != self.localPort {
                self.localPort = clamped
                return
            }
            self.defaults.set(clamped, forKey: Keys.localPort)
        }
    }

    var sshTarget: String {
        didSet { self.persistString(self.sshTarget, key: Keys.sshTarget) }
    }

    var sshIdentityPath: String {
        didSet { self.persistString(self.sshIdentityPath, key: Keys.sshIdentityPath) }
    }

    var directGatewayURL: String {
        didSet { self.persistString(self.directGatewayURL, key: Keys.directGatewayURL) }
    }

    var gatewayAuthTokenRef: String {
        didSet {
            let trimmed = self.gatewayAuthTokenRef.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = trimmed.isEmpty ? "default" : trimmed
            if next != self.gatewayAuthTokenRef {
                self.gatewayAuthTokenRef = next
                return
            }
            self.persistString(next, key: Keys.gatewayAuthTokenRef)
            self.gatewayAuthToken = self.loadToken(ref: next)
        }
    }

    var gatewayAuthToken: String {
        didSet {
            guard !self.isInitializing else { return }
            self.saveToken(self.gatewayAuthToken, ref: self.gatewayAuthTokenRef)
        }
    }

    var selectedPackId: String {
        didSet {
            let pack = PetPackRegistry.pack(for: self.selectedPackId)
            if pack.id != self.selectedPackId {
                self.selectedPackId = pack.id
                return
            }
            self.persistString(pack.id, key: Keys.selectedPackId)
        }
    }

    var launchAtLogin: Bool {
        didSet {
            self.defaults.set(self.launchAtLogin, forKey: Keys.launchAtLogin)
            self.syncLaunchAtLogin()
        }
    }

    var showMenuBarItem: Bool {
        didSet {
            if self.showMenuBarItem == false {
                self.showMenuBarItem = true
            }
        }
    }

    var windowOrigin: CGPoint? {
        didSet { self.persistWindowOrigin(self.windowOrigin) }
    }

    var lastGatewayMode: GatewayConnectionProfile {
        didSet { self.persistString(self.lastGatewayMode.rawValue, key: Keys.lastGatewayMode) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { self.defaults.set(self.hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    var lastConnectionSucceededAt: TimeInterval? {
        didSet {
            if let lastConnectionSucceededAt {
                self.defaults.set(lastConnectionSucceededAt, forKey: Keys.lastConnectionSucceededAt)
            } else {
                self.defaults.removeObject(forKey: Keys.lastConnectionSucceededAt)
            }
        }
    }

    var launchAtLoginErrorMessage: String?

    private init() {
        let storedMode = GatewayConnectionProfile(rawValue: self.defaults.string(forKey: Keys.connectionMode) ?? "")
        let storedPack = self.defaults.string(forKey: Keys.selectedPackId) ?? PetPackRegistry.defaultPack.id
        let tokenRef = self.defaults.string(forKey: Keys.gatewayAuthTokenRef) ?? "default"
        let storedGatewayMode = GatewayConnectionProfile(rawValue: self.defaults.string(forKey: Keys.lastGatewayMode) ?? "")
        let resolvedMode = storedMode ?? .local

        self.connectionMode = resolvedMode
        self.localPort = self.defaults.object(forKey: Keys.localPort) as? Int ?? 18789
        self.sshTarget = self.defaults.string(forKey: Keys.sshTarget) ?? ""
        self.sshIdentityPath = self.defaults.string(forKey: Keys.sshIdentityPath) ?? ""
        self.directGatewayURL = self.defaults.string(forKey: Keys.directGatewayURL) ?? ""
        self.gatewayAuthTokenRef = tokenRef
        self.gatewayAuthToken = GenericPasswordKeychainStore.loadString(
            service: Keychain.service,
            account: tokenRef) ?? ""
        self.selectedPackId = PetPackRegistry.pack(for: storedPack).id
        self.launchAtLogin = self.defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        self.showMenuBarItem = true
        if self.defaults.object(forKey: Keys.windowOriginX) != nil,
           self.defaults.object(forKey: Keys.windowOriginY) != nil
        {
            self.windowOrigin = CGPoint(
                x: self.defaults.double(forKey: Keys.windowOriginX),
                y: self.defaults.double(forKey: Keys.windowOriginY))
        } else {
            self.windowOrigin = nil
        }
        self.lastGatewayMode = storedGatewayMode ?? resolvedMode
        self.hasCompletedOnboarding = self.defaults.bool(forKey: Keys.hasCompletedOnboarding)
        if self.defaults.object(forKey: Keys.lastConnectionSucceededAt) != nil {
            self.lastConnectionSucceededAt = self.defaults.double(forKey: Keys.lastConnectionSucceededAt)
        } else {
            self.lastConnectionSucceededAt = nil
        }
        self.isInitializing = false
    }

    var selectedPack: PetPackManifest {
        PetPackRegistry.pack(for: self.selectedPackId)
    }

    var isConnectionProfileComplete: Bool {
        switch self.connectionMode {
        case .local:
            true
        case .sshTunnel:
            !self.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .direct:
            !self.directGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var connectionSummary: String {
        switch self.connectionMode {
        case .local:
            return "ws://127.0.0.1:\(self.localPort)"
        case .sshTunnel:
            let trimmed = self.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "SSH target missing" : "SSH \(trimmed)"
        case .direct:
            let trimmed = self.directGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Gateway URL missing" : trimmed
        }
    }

    var shouldAutoPresentConnectionWindow: Bool {
        !self.hasCompletedOnboarding || !self.isConnectionProfileComplete
    }

    func markSuccessfulConnection() {
        self.lastConnectionSucceededAt = Date().timeIntervalSince1970
        self.lastGatewayMode = self.connectionMode
    }

    func resetWindowOrigin() {
        self.windowOrigin = nil
    }

    private func persistString(_ value: String, key: String) {
        self.defaults.set(value, forKey: key)
    }

    private func persistWindowOrigin(_ point: CGPoint?) {
        if let point {
            self.defaults.set(point.x, forKey: Keys.windowOriginX)
            self.defaults.set(point.y, forKey: Keys.windowOriginY)
        } else {
            self.defaults.removeObject(forKey: Keys.windowOriginX)
            self.defaults.removeObject(forKey: Keys.windowOriginY)
        }
    }

    private func loadToken(ref: String) -> String {
        GenericPasswordKeychainStore.loadString(service: Keychain.service, account: ref) ?? ""
    }

    private func saveToken(_ token: String, ref: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            _ = GenericPasswordKeychainStore.delete(service: Keychain.service, account: ref)
        } else {
            _ = GenericPasswordKeychainStore.saveString(trimmed, service: Keychain.service, account: ref)
        }
    }

    private func syncLaunchAtLogin() {
        guard !self.isInitializing else { return }
        self.launchAtLoginErrorMessage = nil

        let enabled = self.launchAtLogin
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                self.launchAtLoginErrorMessage = error.localizedDescription
            }
        }
    }
}
