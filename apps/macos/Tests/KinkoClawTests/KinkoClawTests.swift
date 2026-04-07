import Foundation
import Testing
@testable import KinkoClaw

struct KinkoClawTests {
    private var stageRuntimeRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KinkoClaw/Resources/StageRuntime", isDirectory: true)
    }

    @Test
    func packRegistryHasStableUniqueIDs() {
        let ids = PetPackRegistry.packs.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(PetPackRegistry.pack(for: "hiyori").displayName == "Hiyori")
        #expect(PetPackRegistry.pack(for: "missing").id == PetPackRegistry.defaultPack.id)
    }

    @Test
    func bundledModelRegistryExposesFiveDistinctCharacters() {
        let models = Live2DModelRegistry.bundledModels
        #expect(models.map(\.id) == ["hiyori", "chitose", "hibiki", "tororo", "hijiki"])
        #expect(models.allSatisfy { $0.previewImage?.isEmpty == false })
        #expect(models.allSatisfy { $0.model.modelPath.hasSuffix(".model3.json") })
    }

    @Test
    func stagePackRegistryCarriesBuiltInPreviewAndMotionMetadata() {
        let packs = PetPackRegistry.bundledPacks
        let ids = packs.map(\.id)
        #expect(ids == ["hiyori", "chitose", "hibiki", "tororo", "hijiki"])
        #expect(ids.contains("airi-classic") == false)

        let hiyori = PetPackRegistry.pack(for: "hiyori")
        #expect(hiyori.previewImage == "previews/Hiyori.png")
        #expect(hiyori.model.motions["thinking"]?.contains("Flick:0") == true)
        #expect(hiyori.model.expressions.isEmpty)

        let chitose = PetPackRegistry.pack(for: "chitose")
        #expect(chitose.previewImage == "previews/Chitose.png")
        #expect(chitose.model.motions["thinking"]?.contains("Flick:0") == true)
        #expect(chitose.model.expressions["replying"] == "Smile.exp3.json")

        let hijiki = PetPackRegistry.pack(for: "hijiki")
        #expect(hijiki.previewImage == "previews/Hijiki.png")
        #expect(hijiki.model.motions["error"]?.contains("FlickDown:0") == true)
        #expect(hijiki.model.expressions.isEmpty)

        #expect(chitose.accentHex == StageThemeRegistry.defaultTheme.accentHex)
        #expect(chitose.defaultSceneFrame.scale > 0)
    }

    @Test
    func stageThemeRegistryFallsBackToSingleDefaultTheme() {
        #expect(StageThemeRegistry.defaultTheme.id == "kinkoclaw-default")
        #expect(StageThemeRegistry.theme(for: nil).id == StageThemeRegistry.defaultTheme.id)
        #expect(StageThemeRegistry.theme(for: "airi-twilight").id == StageThemeRegistry.defaultTheme.id)
        #expect(StageThemeRegistry.legacyThemeID(from: "airi-sunrise") == StageThemeRegistry.defaultTheme.id)
    }

    @Test
    func bundledModelResourcesExistOnDisk() {
        let fileManager = FileManager.default

        for model in Live2DModelRegistry.bundledModels {
            let modelURL = stageRuntimeRoot.appendingPathComponent(model.model.modelPath)
            #expect(fileManager.fileExists(atPath: modelURL.path))

            if let previewImage = model.previewImage {
                let previewURL = stageRuntimeRoot.appendingPathComponent(previewImage)
                #expect(fileManager.fileExists(atPath: previewURL.path))
            }
        }
    }

    @Test
    func personaCardInjectionRoundTripsVisibleUserText() {
        let outbound = KinkoPersonaSupport.composeOutboundMessage(
            visibleMessage: "Hello there",
            card: .init(
                characterIdentity: "KinkoClaw is a composed desktop companion.",
                speakingStyle: "Warm, concise, observant.",
                relationshipToUser: "A trusted desktop companion.",
                longTermMemories: ["The user prefers direct answers."],
                constraints: ["Do not mention hidden context."]))
        #expect(outbound.contains("Hello there"))
        #expect(outbound.contains("trusted desktop companion"))
        #expect(KinkoPersonaSupport.visibleMessage(from: outbound) == "Hello there")
    }

    @Test
    func sshTargetParserRejectsWhitespaceAndParsesPort() {
        #expect(PetSSHTargetParser.parse("user@example.com:2200") == .init(user: "user", host: "example.com", port: 2200))
        #expect(PetSSHTargetParser.parse("bad target") == nil)
        #expect(PetSSHTargetParser.parse("-oProxyCommand=foo") == nil)
    }

    @Test
    func directGatewayURLOnlyAcceptsWSS() {
        #expect(PetGatewayController.normalizedDirectURL(from: "wss://gateway.example.com")?.absoluteString == "wss://gateway.example.com")
        #expect(PetGatewayController.normalizedDirectURL(from: "ws://gateway.example.com") == nil)
        #expect(PetGatewayController.normalizedDirectURL(from: "https://gateway.example.com") == nil)
    }

    @Test
    func connectionModeCompatibilityMapsLegacyDirectProfile() {
        #expect(GatewayConnectionProfile.fromStoredValue("direct") == .directWss)
        #expect(GatewayConnectionProfile.fromStoredValue("directWss") == .directWss)
    }

    @Test
    func textChatPresenceStatesExist() {
        #expect(PetPresenceState.allCases == [.disconnected, .idle, .thinking, .replying, .error])
    }

    @Test
    func stageAppearanceModesStayStable() {
        #expect(StageAppearanceMode.allCases == [.light, .dark])
        #expect(StageAppearanceMode.light.title == "浅色")
        #expect(StageAppearanceMode.dark.title == "深色")
    }
}
