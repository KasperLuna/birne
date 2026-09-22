// HTTPServer.swift
// A minimal, zero-external-dependency HTTP/1.1 server using POSIX sockets.
// Exposes:
//   POST /v1/embeddings        — OpenAI-compatible embeddings endpoint
//   GET  /v1/models            — lists available embedding models
//   GET  /health               — liveness check
//
// Drop-in compatible with the OpenAI embeddings API shape, so any client
// that works against text-embedding-3-small also works against birne.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Server

struct HTTPServer: Sendable {
    let port: Int
    let quiet: Bool

    func run() async {
        // Bind socket
        let serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else { fatalError("socket() failed: \(errno)") }

        var yes: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { fatalError("bind() failed on port \(port): \(errno)") }
        guard listen(serverFd, 128) == 0 else { fatalError("listen() failed: \(errno)") }

        if !quiet {
            fputs("birne listening on http://127.0.0.1:\(port)\n", stderr)
            fputs("  POST /v1/embeddings\n", stderr)
            fputs("  GET  /v1/models\n", stderr)
            fputs("  GET  /health\n", stderr)
        }

        // Accept loop
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFd, $0, &clientLen)
                }
            }
            guard clientFd >= 0 else { continue }

            // Handle each connection concurrently
            let fd = clientFd
            let q = quiet
            Task.detached {
                await ConnectionHandler(fd: fd, quiet: q).handle()
            }
        }
    }
}

// MARK: - Connection handler

actor ConnectionHandler {
    let fd: Int32
    let quiet: Bool

    init(fd: Int32, quiet: Bool) {
        self.fd = fd
        self.quiet = quiet
    }

    func handle() async {
        defer { close(fd) }

        // Read request (up to 256 KB)
        var buffer = [UInt8](repeating: 0, count: 262_144)
        let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
        guard bytesRead > 0 else { return }

        let raw = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""
        let (method, path, body) = parseHTTP(raw)

        if !quiet {
            fputs("\(method) \(path)\n", stderr)
        }

        let (status, responseBody) = await route(method: method, path: path, body: body)
        sendResponse(status: status, body: responseBody)
    }

    // MARK: Router

    private func route(method: String, path: String, body: String) async -> (Int, String) {
        switch (method, path) {
        case ("GET", "/health"), ("GET", "/health/"):
            return (200, #"{"status":"ok","service":"birne"}"#)

        case ("GET", "/v1/models"), ("GET", "/v1/models/"):
            return (200, modelsResponse())

        case ("POST", "/v1/embeddings"), ("POST", "/v1/embeddings/"):
            return await handleEmbeddings(body: body)

        default:
            return (404, #"{"error":{"message":"not found","type":"invalid_request_error"}}"#)
        }
    }

    // MARK: /v1/embeddings

    private func handleEmbeddings(body: String) async -> (Int, String) {
        guard let data = body.data(using: .utf8),
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (400, errorJSON("could not parse request body"))
        }

        // Extract input — string or array of strings
        let inputs: [String]
        if let single = req["input"] as? String {
            inputs = [single]
        } else if let arr = req["input"] as? [String] {
            inputs = arr
        } else {
            return (400, errorJSON("'input' must be a string or array of strings"))
        }

        // Resolve script/language
        let modelHint = req["model"] as? String ?? ""
        let script = scriptFromModelHint(modelHint)

        do {
            let engine = try await EmbeddingEngine.shared(script: script)
            let results = try await engine.embedBatch(inputs)

            var dataArray: [[String: Any]] = []
            for (i, r) in results.enumerated() {
                dataArray.append([
                    "object": "embedding",
                    "index": i,
                    "embedding": r.vector.map { Double($0) }
                ])
            }

            let usage: [String: Any] = [
                "prompt_tokens": results.map(\.tokenCount).reduce(0, +),
                "total_tokens":  results.map(\.tokenCount).reduce(0, +)
            ]

            let response: [String: Any] = [
                "object": "list",
                "data": dataArray,
                "model": "birne-\(script.rawValue)",
                "usage": usage
            ]

            let json = try JSONSerialization.data(withJSONObject: response)
            return (200, String(data: json, encoding: .utf8) ?? "{}")
        } catch {
            return (500, errorJSON(error.localizedDescription))
        }
    }

    // MARK: /v1/models

    private func modelsResponse() -> String {
        let models = ["latin", "cyrillic", "cjk"].map { script in
            [
                "id": "birne-\(script)",
                "object": "model",
                "created": 1_700_000_000,
                "owned_by": "birne"
            ] as [String: Any]
        }
        let response: [String: Any] = ["object": "list", "data": models]
        let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: Helpers

    private func scriptFromModelHint(_ hint: String) -> EmbeddingScript {
        let h = hint.lowercased()
        if h.contains("cyrillic") || h.contains("cyr") { return .cyrillic }
        if h.contains("cjk") || h.contains("chinese") || h.contains("japanese") || h.contains("korean") { return .cjk }
        return .latin
    }

    private func errorJSON(_ msg: String) -> String {
        let obj: [String: Any] = ["error": ["message": msg, "type": "api_error"]]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"error":{"message":"unknown"}}"#
    }

    // MARK: Raw HTTP helpers

    private func parseHTTP(_ raw: String) -> (method: String, path: String, body: String) {
        let lines = raw.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let path   = parts.count > 1 ? parts[1] : "/"

        // Body is after the blank line
        if let bodyRange = raw.range(of: "\r\n\r\n") {
            return (method, path, String(raw[bodyRange.upperBound...]))
        }
        return (method, path, "")
    }

    private func sendResponse(status: Int, body: String) {
        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
        let bodyBytes = body.utf8
        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(bodyBytes.count)\r
        Connection: close\r
        \r
        \(body)
        """
        var bytes = Array(response.utf8)
        send(fd, &bytes, bytes.count, 0)
    }
}
