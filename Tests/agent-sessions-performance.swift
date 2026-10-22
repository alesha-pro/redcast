import Foundation

/// Timings for Agent Sessions' pure layer on synthetic data; prints JSON, asserts nothing.
@main
struct AgentSessionsPerformance {
    static let words = [
        "fix", "the", "login", "redirect", "add", "tests", "rate", "limiter", "refactor", "parser",
        "migrate", "database", "schema", "deploy", "staging", "review", "pull", "request", "docs", "cache"
    ]

    static func main() {
        var generator = SystemRandomNumberGenerator()
        func phrase(_ count: Int) -> String {
            (0..<count).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
        }
        let sessions = (0..<1_000).map { index in
            AgentSession(
                source: index % 3 == 0 ? .codex : .claude, sessionID: UUID().uuidString, title: phrase(5),
                titleOrigin: .generated, firstPrompt: phrase(40), lastPrompt: phrase(20),
                directory: "/Users/me/dev/project-\(index % 40)", branch: "main",
                createdAt: Date(timeIntervalSince1970: Double(index)),
                updatedAt: Date(timeIntervalSince1970: Double(index)), host: .terminal)
        }
        let foldStart = Date()
        let entries = sessions.map { ($0, AgentSessionSearchKeys($0)) }
        let fold = Date().timeIntervalSince(foldStart)

        let typed = "refactor parser migrate database deploy staging review pull request docs"
        let prefixes = (1...50).map { String(typed.prefix($0)) }
        let rankStart = Date()
        for prefix in prefixes {
            _ = AgentSessionQuery.rank(entries, query: prefix, filter: .init(), live: [:])
        }
        let rank = Date().timeIntervalSince(rankStart) / Double(prefixes.count)

        let transcripts = (0..<500).map { index in transcript(index, phrase: phrase) }
        let decodeStart = Date()
        for data in transcripts {
            var reader = ClaudeTranscriptDecoder.HeadReader()
            _ = reader.consume(data.prefix(32_768))
            _ = reader.finish()
            let window = data.suffix(ClaudeTranscriptDecoder.tailWindow)
            _ = ClaudeTranscriptDecoder.tail(Data(window), startsMidLine: data.count > window.count)
        }
        let decode = Date().timeIntervalSince(decodeStart)

        print(
            """
            {"foldMs": \(ms(fold)), "rankMsPerKeystroke": \(ms(rank)), "headTail500Ms": \(ms(decode))}
            """)
    }

    static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds * 1_000)
    }

    /// About 96 KB of prompts, replies and tool output, titled near the end as Claude writes it.
    static func transcript(_ index: Int, phrase: (Int) -> String) -> Data {
        var lines: [[String: Any]] = []
        let session = UUID().uuidString
        func user(_ content: Any) -> [String: Any] {
            [
                "parentUuid": NSNull(), "isSidechain": false, "promptId": "p", "type": "user",
                "message": ["role": "user", "content": content], "uuid": UUID().uuidString,
                "timestamp": "2026-10-22T14:09:26.947Z", "origin": ["kind": "human"], "entrypoint": "cli",
                "cwd": "/Users/me/dev/project-\(index % 40)", "sessionId": session, "gitBranch": "main"
            ]
        }
        func reply(_ text: String) -> [String: Any] {
            [
                "parentUuid": "u", "isSidechain": false,
                "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
                "type": "assistant", "uuid": UUID().uuidString, "sessionId": session
            ]
        }
        for turn in 0..<40 {
            lines.append(user(phrase(30)))
            lines.append(reply(phrase(120)))
            lines.append(user([["tool_use_id": "t\(turn)", "type": "tool_result", "content": phrase(250)]]))
        }
        lines.append(["type": "ai-title", "aiTitle": phrase(4), "sessionId": session])
        lines.append(["type": "last-prompt", "lastPrompt": phrase(10), "sessionId": session])
        var data = Data()
        for line in lines {
            data.append((try? JSONSerialization.data(withJSONObject: line)) ?? Data())
            data.append(0x0A)
        }
        return data
    }
}
