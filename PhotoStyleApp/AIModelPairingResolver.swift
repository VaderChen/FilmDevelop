import Foundation

enum AIModelPairingResolver {
    static func bestRunnableModelFile(in candidates: [URL], auxiliaryCandidates: [URL]) -> URL? {
        guard candidates.count > 1 else { return candidates.first }
        guard !auxiliaryCandidates.isEmpty else { return sortedByModificationDate(candidates).first }

        return candidates.map { modelURL in
            (
                url: modelURL,
                score: auxiliaryCandidates.map { pairingScore(modelURL: modelURL, auxiliaryURL: $0) }.max() ?? 0
            )
        }.sorted(by: rankedBefore).first?.url
    }

    static func bestAuxiliaryModelFile(forModel modelURL: URL, candidates: [URL]) -> URL? {
        guard !candidates.isEmpty else { return nil }

        let best = candidates.map { auxiliaryURL in
            (url: auxiliaryURL, score: pairingScore(modelURL: modelURL, auxiliaryURL: auxiliaryURL))
        }.sorted(by: rankedBefore).first

        guard let best, best.score > 0 else { return nil }
        return best.url
    }

    static func pairingScore(modelURL: URL, auxiliaryURL: URL) -> Int {
        let modelKey = normalizedModelName(modelURL.deletingPathExtension().lastPathComponent)
        let auxiliaryKey = normalizedAuxiliaryKey(from: auxiliaryURL)
        guard !modelKey.isEmpty, !auxiliaryKey.isEmpty else { return 0 }

        if modelKey == auxiliaryKey { return 100 }
        if modelKey.hasPrefix(auxiliaryKey) || auxiliaryKey.hasPrefix(modelKey) { return 80 }

        let modelTokens = tokens(in: modelKey)
        let auxiliaryTokens = tokens(in: auxiliaryKey)
        let sharedTokens = modelTokens.intersection(auxiliaryTokens)
        return sharedTokens.count >= 2 ? 20 + sharedTokens.count : 0
    }

    static func sortedByModificationDate(_ files: [URL]) -> [URL] {
        files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
    }

    private static func normalizedAuxiliaryKey(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name.hasPrefix("mmproj") { return "" }
        for marker in [".mmproj", "-mmproj", "_mmproj"] {
            if let range = name.range(of: marker) {
                name = String(name[..<range.lowerBound])
                break
            }
        }
        return normalizedModelName(name)
    }

    private static func normalizedModelName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(
                of: #"([._-](q[0-9]+(?:_[a-z0-9]+)*|f16|bf16|fp16|f32))+$"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func tokens(in value: String) -> Set<String> {
        Set(value.split(whereSeparator: { "-_ .".contains($0) }).map(String.init).filter { $0.count > 1 })
    }

    private static func rankedBefore(_ lhs: (url: URL, score: Int), _ rhs: (url: URL, score: Int)) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
    }
}
