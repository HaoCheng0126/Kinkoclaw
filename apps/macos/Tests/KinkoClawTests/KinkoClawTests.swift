import Testing
@testable import KinkoClaw

struct KinkoClawTests {
    @Test
    func packRegistryHasStableUniqueIDs() {
        let ids = PetPackRegistry.packs.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(PetPackRegistry.pack(for: "airi-classic").displayName == "AIRI Classic")
        #expect(PetPackRegistry.pack(for: "missing").id == PetPackRegistry.defaultPack.id)
    }

    @Test
    func stagePackRegistryCarriesLive2DModelMetadata() {
        let pack = PetPackRegistry.defaultPack
        #expect(pack.model.modelPath == "models/hiyori_free_zh/runtime/hiyori_free_t08.model3.json")
        #expect(pack.model.textures.isEmpty == false)
        #expect(pack.model.motions["idle"]?.contains("Idle:0") == true)
        #expect(pack.model.motions["replying"]?.contains("Tap:0") == true)
        #expect(pack.model.expressions["replying"] != nil)
        #expect(pack.defaultSceneFrame.scale > 0)
        #expect(pack.dialogueProfile.subtitlePrefix == "AIRI")
    }

    @Test
    func personaCardInjectionRoundTripsVisibleUserText() {
        let outbound = KinkoPersonaSupport.composeOutboundMessage(
            visibleMessage: "Hello there",
            card: .init(
                characterIdentity: "AIRI is a composed anime companion.",
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
}
