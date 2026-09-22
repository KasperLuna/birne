// birne — on-device embedding daemon
// Surfaces NLContextualEmbedding via an OpenAI-compatible /v1/embeddings HTTP API.
// Mirrors the apfel design: zero external dependencies, runs on-device, brew-services compatible.
//
// Usage:
//   birne embed "Hello world"          # one-shot embedding (JSON out)
//   birne --serve                      # HTTP daemon on port 11435
//   birne info                         # show model properties
//   birne prepare [--language en]      # pre-download model assets
//
// Requires macOS 14+ (Sonoma). No Apple Intelligence needed — NaturalLanguage
// framework ships with the OS.

import Foundation

// MARK: - Version

enum Version {
    static let current = "0.1.0"
}

@main
struct Birne {
    static func main() async {
        let args = CommandLine.arguments.dropFirst() // drop binary name
        var rest = Array(args)

        // Flags
        let serve    = rest.removeAll(of: "--serve")
        let quiet    = rest.removeAll(of: "-q") || rest.removeAll(of: "--quiet")
        let jsonOut  = extractFlag(&rest, names: ["-o", "--output"]) == "json"
        let port     = Int(extractFlag(&rest, names: ["--port"]) ?? "") ?? 11435
        let lang     = extractFlag(&rest, names: ["--language", "-l"]) ?? "en"
        let script   = extractFlag(&rest, names: ["--script"]) // "latin" | "cyrillic" | "cjk"

        if serve {
            if !quiet { fputs("birne \(Version.current) — embedding daemon on :\(port)\n", stderr) }
            await HTTPServer(port: port, quiet: quiet).run()
            return
        }

        let subcommand = rest.first

        switch subcommand {
        case "info":
            await InfoCommand().run(script: script, language: lang)
        case "prepare":
            rest.removeFirst()
            await PrepareCommand().run(script: script, language: lang, quiet: quiet)
        case "embed", nil:
            if subcommand == "embed" { rest.removeFirst() }
            let prompt = rest.joined(separator: " ")
            if prompt.isEmpty {
                // Check stdin
                let stdin = readLine(strippingNewline: false) ?? ""
                if stdin.isEmpty {
                    fputs("usage: birne embed <text> | birne --serve\n", stderr)
                    exit(1)
                }
                await EmbedCommand().run(text: stdin, language: lang, script: script, json: true, quiet: quiet)
            } else {
                await EmbedCommand().run(text: prompt, language: lang, script: script, json: jsonOut, quiet: quiet)
            }
        default:
            fputs("unknown subcommand '\(subcommand!)'. try: embed, info, prepare, --serve\n", stderr)
            exit(1)
        }
    }
}

// MARK: - Argument helpers

extension Array where Element == String {
    @discardableResult
    mutating func removeAll(of flag: String) -> Bool {
        if let i = firstIndex(of: flag) { remove(at: i); return true }
        return false
    }
}

func extractFlag(_ args: inout [String], names: [String]) -> String? {
    for name in names {
        if let i = args.firstIndex(of: name), i + 1 < args.count {
            let val = args[i + 1]
            args.removeSubrange(i...i+1)
            return val
        }
    }
    return nil
}
