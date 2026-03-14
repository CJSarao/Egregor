import Foundation

struct TerminalTextNormalizer {
    // MARK: Internal

    func normalizeForInjection(_ text: String) -> String {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)

        while let scalar = normalized.unicodeScalars.last,
              Self.trailingPunctuation.contains(scalar) {
            normalized.unicodeScalars.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalized
    }

    // MARK: Private

    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?")
}
