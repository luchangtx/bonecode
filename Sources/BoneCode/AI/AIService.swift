import Foundation

enum AIError: LocalizedError {
    case notConfigured
    case badURL
    case badResponse
    case http(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置 AI 接口（需要接口地址、模型名与 API Key）"
        case .badURL: return "接口地址格式不正确"
        case .badResponse: return "服务返回了无法识别的响应"
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
            return "HTTP \(code)\(detail.isEmpty ? "" : "：\(detail)")"
        case .cancelled: return "已取消"
        }
    }
}

/// OpenAI-compatible chat client.
///
/// Works with OpenAI, DeepSeek, Moonshot, Qwen (DashScope compatible mode),
/// Ollama's OpenAI shim, vLLM, LM Studio and anything else that speaks
/// `POST {base}/chat/completions` with SSE streaming.
final class AIService {

    static let shared = AIService()

    struct Message {
        let role: String   // system | user | assistant
        let content: String

        static func system(_ s: String) -> Message { Message(role: "system", content: s) }
        static func user(_ s: String) -> Message { Message(role: "user", content: s) }
        static func assistant(_ s: String) -> Message { Message(role: "assistant", content: s) }
    }

    private let d = UserDefaults.standard
    private static let keyAccount = "openai-compatible-api-key"

    private init() {}

    // MARK: - Configuration

    var baseURL: String {
        get { d.string(forKey: "aiBaseURL") ?? "https://api.openai.com/v1" }
        set { d.set(newValue, forKey: "aiBaseURL") }
    }

    var model: String {
        get { d.string(forKey: "aiModel") ?? "gpt-4o-mini" }
        set { d.set(newValue, forKey: "aiModel") }
    }

    var temperature: Double {
        get { d.object(forKey: "aiTemperature") as? Double ?? 0.2 }
        set { d.set(newValue, forKey: "aiTemperature") }
    }

    var maxTokens: Int {
        get { d.object(forKey: "aiMaxTokens") as? Int ?? 4096 }
        set { d.set(newValue, forKey: "aiMaxTokens") }
    }

    var apiKey: String? {
        get { Keychain.load(account: Self.keyAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.save(newValue, account: Self.keyAccount)
            } else {
                Keychain.delete(account: Self.keyAccount)
            }
        }
    }

    var isConfigured: Bool {
        guard let key = apiKey, !key.isEmpty else { return false }
        return !baseURL.isEmpty && !model.isEmpty
    }

    private var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            return URL(string: base)
        }
        return URL(string: base + "/chat/completions")
    }

    // MARK: - Chat

    func streamChat(
        messages: [Message],
        onDelta: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard isConfigured, let key = apiKey else {
            completion(.failure(AIError.notConfigured))
            return
        }
        guard let url = endpoint else {
            completion(.failure(AIError.badURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 180

        let payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(AIError.badResponse))
            return
        }
        request.httpBody = body

        Task.detached(priority: .userInitiated) {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AIError.badResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    var errorText = ""
                    for try await line in bytes.lines {
                        errorText += line
                        if errorText.count > 4000 { break }
                    }
                    throw AIError.http(http.statusCode, errorText)
                }

                var full = ""
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if chunk == "[DONE]" { break }
                    guard let data = chunk.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let first = choices.first else { continue }

                    if let delta = first["delta"] as? [String: Any],
                       let content = delta["content"] as? String, !content.isEmpty {
                        full += content
                        await MainActor.run { onDelta(content) }
                    } else if let message = first["message"] as? [String: Any],
                              let content = message["content"] as? String, !content.isEmpty {
                        // Some servers ignore stream:true and send a single message.
                        full += content
                        await MainActor.run { onDelta(content) }
                    }
                }
                let result = full
                await MainActor.run { completion(.success(result)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    func chat(messages: [Message], completion: @escaping (Result<String, Error>) -> Void) {
        streamChat(messages: messages, onDelta: { _ in }, completion: completion)
    }

    // MARK: - Task presets

    private static let codeSystemPrompt = """
    你是一位资深软件工程师，正在一个代码编辑器里协助用户。
    要求：
    1. 回答使用简体中文，代码与技术名词保留英文。
    2. 需要修改代码时，输出完整的可替换代码块，不要只给片段或省略号。
    3. 代码块必须标注语言，例如 ```java。
    4. 不要重复用户已有的代码，除非它需要被修改。
    5. 保持简洁，先给结论再给解释。
    """

    private static let shellSystemPrompt = """
    你是一个命令行助手。用户会用自然语言描述他想做的事，你要给出**一条**可以直接在 macOS zsh 里执行的命令。
    要求：
    1. 只输出命令本身，不要解释，不要 Markdown 代码块标记，不要以 $ 开头。
    2. 如果必须多步，用 && 连接成一行。
    3. 命令中不要包含任何需要交互输入的操作。
    4. 如果用户的请求有危险（删除数据、覆盖文件、强制推送等），在命令后另起一行以 # 开头写一句中文风险提示。
    """

    func generateShellCommand(request: String, context: String,
                              completion: @escaping (Result<String, Error>) -> Void) {
        let messages: [Message] = [
            .system(Self.shellSystemPrompt),
            .user("环境信息：\n\(context)\n\n用户请求：\(request)")
        ]
        chat(messages: messages, completion: completion)
    }

    func explainSelection(code: String, languageID: String, filePath: String,
                          completion: @escaping (Result<String, Error>) -> Void) {
        let messages: [Message] = [
            .system(Self.codeSystemPrompt),
            .user("请解释这段 \(languageID) 代码的作用、关键流程和潜在问题。文件：\(filePath)\n\n```\(languageID)\n\(code)\n```")
        ]
        chat(messages: messages, completion: completion)
    }

    func refactorSelection(code: String, languageID: String, instruction: String,
                           completion: @escaping (Result<String, Error>) -> Void) {
        let messages: [Message] = [
            .system(Self.codeSystemPrompt),
            .user("""
            请按要求改写下面的 \(languageID) 代码。要求：\(instruction)

            只输出改写后的完整代码块。

            ```\(languageID)
            \(code)
            ```
            """)
        ]
        chat(messages: messages, completion: completion)
    }

    func findBugs(code: String, languageID: String,
                  completion: @escaping (Result<String, Error>) -> Void) {
        let messages: [Message] = [
            .system(Self.codeSystemPrompt),
            .user("请审查下面的 \(languageID) 代码，指出 bug、边界问题与安全隐患，按严重程度排序。\n\n```\(languageID)\n\(code)\n```")
        ]
        chat(messages: messages, completion: completion)
    }

    func writeTests(code: String, languageID: String, frameworkHint: String,
                    completion: @escaping (Result<String, Error>) -> Void) {
        let messages: [Message] = [
            .system(Self.codeSystemPrompt),
            .user("请为下面的 \(languageID) 代码编写单元测试，测试框架优先使用 \(frameworkHint)。只输出测试代码。\n\n```\(languageID)\n\(code)\n```")
        ]
        chat(messages: messages, completion: completion)
    }

    func generateCommitMessage(diff: String, recentStyle: String,
                               completion: @escaping (Result<String, Error>) -> Void) {
        let messages: [Message] = [
            .system("""
            你负责撰写 Git 提交信息。要求：
            1. 使用 Conventional Commits 风格（feat/fix/refactor/docs/test/chore/perf/style/build/ci）。
            2. 第一行不超过 60 个字符，使用中文描述。
            3. 如有必要，空一行后写 1-3 条要点，每条以 - 开头。
            4. 只输出提交信息本身，不要任何额外说明或代码块标记。
            """),
            .user("仓库近期提交风格参考：\n\(recentStyle)\n\n本次改动 diff：\n\(diff)")
        ]
        chat(messages: messages, completion: completion)
    }

    func reviewDiff(diff: String, completion: @escaping (Result<String, Error>) -> Void) {
        let messages: [Message] = [
            .system(Self.codeSystemPrompt),
            .user("请审查这次改动，指出问题、风险与改进建议，按重要性排序。\n\n\(diff)")
        ]
        chat(messages: messages, completion: completion)
    }

    func ask(question: String, context: String,
             history: [Message],
             onDelta: @escaping (String) -> Void,
             completion: @escaping (Result<String, Error>) -> Void) {
        var messages: [Message] = [.system(Self.codeSystemPrompt)]
        messages.append(.user("当前工作区上下文：\n\(context)"))
        messages.append(.assistant("收到，我已经了解当前上下文。"))
        messages.append(contentsOf: history)
        messages.append(.user(question))
        streamChat(messages: messages, onDelta: onDelta, completion: completion)
    }
}
