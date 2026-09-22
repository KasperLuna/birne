// EmbeddingEngine.swift
// Wraps NLContextualEmbedding with asset management, mean-pooling, and
// a reusable actor so the model is loaded once and shared across requests.

import Foundation
import NaturalLanguage

// MARK: - Script resolution

enum EmbeddingScript: String {
    case latin, cyrillic, cjk

    var nlScript: NLScript {
        switch self {
        case .latin:    return .latin
        case .cyrillic: return .cyrillic
        case .cjk:      return .simplifiedChinese // covers CJK model
        }
    }

    /// Best script for a given BCP-47 language tag.
    static func forLanguage(_ tag: String) -> EmbeddingScript {
        switch tag.lowercased().prefix(2) {
        case "ru", "uk", "bg", "sr": return .cyrillic
        case "zh", "ja", "ko":       return .cjk
        default:                     return .latin
        }
    }
}

// MARK: - Result type

struct EmbeddingResult: Sendable {
    let vector: [Float]     // mean-pooled sentence vector
    let dimension: Int
    let tokenCount: Int
    let modelIdentifier: String
}

// MARK: - Engine cache actor

private actor EngineCache {
    var cache: [EmbeddingScript: EmbeddingEngine] = [:]
    static let shared = EngineCache()

    func get(_ key: EmbeddingScript) -> EmbeddingEngine? { cache[key] }
    func set(_ engine: EmbeddingEngine, for key: EmbeddingScript) { cache[key] = engine }
}

// MARK: - Engine actor (singleton per script)

actor EmbeddingEngine {

    static func shared(script: EmbeddingScript) async throws -> EmbeddingEngine {
        if let existing = await EngineCache.shared.get(script) { return existing }
        let engine = try await EmbeddingEngine(script: script)
        await EngineCache.shared.set(engine, for: script)
        return engine
    }

    // ----

    private let model: NLContextualEmbedding
    private let dim: Int
    let modelIdentifier: String

    init(script: EmbeddingScript) async throws {
        guard let m = NLContextualEmbedding(script: script.nlScript) else {
            throw EmbeddingError.modelUnavailable("No NLContextualEmbedding for script '\(script.rawValue)'")
        }
        // Ensure assets are present
        if !m.hasAvailableAssets {
            try await m.requestAssets()
        }
        try m.load()
        self.model = m
        self.dim = m.dimension
        self.modelIdentifier = m.modelIdentifier
    }

    /// Embed a single string. Returns a mean-pooled Float vector.
    func embed(_ text: String) throws -> EmbeddingResult {
        let result = try model.embeddingResult(for: text, language: nil)

        var sum = [Double](repeating: 0, count: dim)
        var tokenCount = 0

        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
            for i in 0..<min(vec.count, self.dim) {
                sum[i] += vec[i]
            }
            tokenCount += 1
            return true
        }

        guard tokenCount > 0 else {
            throw EmbeddingError.emptyResult
        }

        let vector = sum.map { Float($0 / Double(tokenCount)) }
        return EmbeddingResult(
            vector: vector,
            dimension: dim,
            tokenCount: tokenCount,
            modelIdentifier: modelIdentifier
        )
    }

    /// Embed multiple strings. Sequential — NLContextualEmbedding is not thread-safe.
    func embedBatch(_ texts: [String]) throws -> [EmbeddingResult] {
        try texts.map { try embed($0) }
    }

    var dimension: Int { dim }

    func info() -> ModelInfo {
        ModelInfo(
            modelIdentifier: modelIdentifier,
            dimension: dim,
            hasAvailableAssets: model.hasAvailableAssets,
            revision: model.revision,
            languages: model.languages.map { $0.rawValue }
        )
    }
}

// MARK: - Supporting types

struct ModelInfo: Sendable {
    let modelIdentifier: String
    let dimension: Int
    let hasAvailableAssets: Bool
    let revision: Int
    let languages: [String]
}

enum EmbeddingError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case emptyResult

    var description: String {
        switch self {
        case .modelUnavailable(let m): return "model unavailable: \(m)"
        case .emptyResult: return "embedding returned zero tokens"
        }
    }
}
