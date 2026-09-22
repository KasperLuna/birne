// Commands.swift
// Implements the three CLI subcommands: embed, info, prepare.

import Foundation
import NaturalLanguage

// MARK: - embed

struct EmbedCommand {
    func run(text: String, language: String, script scriptOverride: String?, json: Bool, quiet: Bool) async {
        let script: EmbeddingScript
        if let s = scriptOverride.flatMap({ EmbeddingScript(rawValue: $0) }) {
            script = s
        } else {
            script = EmbeddingScript.forLanguage(language)
        }

        do {
            let engine = try await EmbeddingEngine.shared(script: script)
            let result = try await engine.embed(text)

            if json {
                let obj: [String: Any] = [
                    "object": "embedding",
                    "embedding": result.vector.map { Double($0) },
                    "dimension": result.dimension,
                    "token_count": result.tokenCount,
                    "model": result.modelIdentifier
                ]
                if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } else {
                // Plain: space-separated floats — pipe-friendly
                print(result.vector.map { String(format: "%.6f", $0) }.joined(separator: " "))
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }
}

// MARK: - info

struct InfoCommand {
    func run(script scriptOverride: String?, language: String) async {
        let script: EmbeddingScript
        if let s = scriptOverride.flatMap({ EmbeddingScript(rawValue: $0) }) {
            script = s
        } else {
            script = EmbeddingScript.forLanguage(language)
        }

        // We don't need to load the model to show basic info
        guard let model = NLContextualEmbedding(script: script.nlScript) else {
            fputs("no model available for script '\(script.rawValue)'\n", stderr)
            exit(1)
        }

        let info: [String: Any] = [
            "script": script.rawValue,
            "model_identifier": model.modelIdentifier,
            "dimension": model.dimension,
            "revision": model.revision,
            "has_available_assets": model.hasAvailableAssets,
            "languages": model.languages.map(\.rawValue)
        ]

        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}

// MARK: - prepare

struct PrepareCommand {
    func run(script scriptOverride: String?, language: String, quiet: Bool) async {
        let script: EmbeddingScript
        if let s = scriptOverride.flatMap({ EmbeddingScript(rawValue: $0) }) {
            script = s
        } else {
            script = EmbeddingScript.forLanguage(language)
        }

        guard let model = NLContextualEmbedding(script: script.nlScript) else {
            fputs("no model for script '\(script.rawValue)'\n", stderr)
            exit(1)
        }

        if model.hasAvailableAssets {
            if !quiet { print("assets already available for '\(script.rawValue)'") }
            return
        }

        if !quiet { fputs("requesting asset download for '\(script.rawValue)'...\n", stderr) }

        do {
            try await model.requestAssets()
            if !quiet { print("assets ready") }
        } catch {
            fputs("error downloading assets: \(error)\n", stderr)
            exit(1)
        }
    }
}
