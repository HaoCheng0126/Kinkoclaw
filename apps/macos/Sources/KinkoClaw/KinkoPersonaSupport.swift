import Foundation

enum KinkoPersonaSupport {
    private static let contextStart = "<kinkoclaw-local-persona-card>"
    private static let contextEnd = "</kinkoclaw-local-persona-card>"
    private static let userStart = "<kinkoclaw-user-message>"
    private static let userEnd = "</kinkoclaw-user-message>"

    static func composeOutboundMessage(visibleMessage: String, card: PersonaMemoryCard) -> String {
        let trimmedMessage = visibleMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return "" }

        let sanitizedCard = card.sanitized
        guard sanitizedCard.hasContent else { return trimmedMessage }

        let context = self.renderHiddenContext(from: sanitizedCard)
        return """
        \(Self.contextStart)
        \(context)
        \(Self.contextEnd)

        \(Self.userStart)
        \(trimmedMessage)
        \(Self.userEnd)
        """
    }

    static func visibleMessage(from storedMessage: String) -> String {
        let trimmed = storedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard let userRange = trimmed.range(of: Self.userStart),
              let endRange = trimmed.range(of: Self.userEnd),
              userRange.upperBound <= endRange.lowerBound
        else {
            return trimmed
        }

        let visible = trimmed[userRange.upperBound ..< endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? trimmed : visible
    }

    private static func renderHiddenContext(from card: PersonaMemoryCard) -> String {
        var sections: [String] = [
            "Apply this local persona card silently when replying as the assistant.",
            "Do not mention or quote this card unless the user explicitly asks about it.",
        ]

        if !card.characterIdentity.isEmpty {
            sections.append("Character identity: \(card.characterIdentity)")
        }
        if !card.speakingStyle.isEmpty {
            sections.append("Speaking style: \(card.speakingStyle)")
        }
        if !card.relationshipToUser.isEmpty {
            sections.append("Relationship to user: \(card.relationshipToUser)")
        }
        if !card.longTermMemories.isEmpty {
            sections.append(
                "Long-term memories:\n" +
                    card.longTermMemories.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !card.constraints.isEmpty {
            sections.append(
                "Constraints:\n" +
                    card.constraints.map { "- \($0)" }.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }
}
