import Foundation

/// Wire-shaped payloads for `FakeOpenAIServer.Response.sse(frames:)` — the
/// chat-completions chunk objects real OpenAI-compatible endpoints emit, so a
/// test reads as a script of *what the server says* rather than a wall of JSON.
public enum OpenAIFixtures {

    /// The SSE terminator every OpenAI-compatible endpoint sends last.
    public static let done = "[DONE]"

    /// One `choices[0].delta.content` chunk.
    public static func contentDelta(_ text: String, model: String = "fake-model") -> String {
        chunk(model: model, delta: ["content": text])
    }

    /// One `choices[0].delta.reasoning_content` chunk — DeepSeek's thinking
    /// stream, which callers must be able to distinguish from answer content.
    public static func reasoningDelta(_ text: String, model: String = "fake-model") -> String {
        chunk(model: model, delta: ["reasoning_content": text])
    }

    /// The terminal chunk: empty delta plus a finish reason, optionally with the
    /// usage object (endpoints that report token counts on the last chunk).
    public static func finish(
        reason: String = "stop",
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedTokens: Int? = nil,
        model: String = "fake-model"
    ) -> String {
        var object = chunkObject(model: model, delta: [:])
        var choice = (object["choices"] as! [[String: Any]])[0]
        choice["finish_reason"] = reason
        object["choices"] = [choice]
        if let promptTokens, let completionTokens {
            var usage: [String: Any] = [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ]
            if let cachedTokens {
                usage["prompt_tokens_details"] = ["cached_tokens": cachedTokens]
            }
            object["usage"] = usage
        }
        return encode(object)
    }

    /// A complete non-streaming chat-completion body, for `.json` responses.
    public static func completionBody(
        content: String,
        model: String = "fake-model",
        promptTokens: Int = 10,
        completionTokens: Int = 5
    ) -> String {
        encode([
            "id": "chatcmpl-fake",
            "object": "chat.completion",
            "model": model,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": content],
                "finish_reason": "stop",
            ]],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ],
        ])
    }

    /// An OpenAI-shaped error body (what a real 429/5xx carries).
    public static func errorBody(message: String, type: String = "server_error") -> String {
        encode(["error": ["message": message, "type": type]])
    }

    private static func chunk(model: String, delta: [String: Any]) -> String {
        encode(chunkObject(model: model, delta: delta))
    }

    private static func chunkObject(model: String, delta: [String: Any]) -> [String: Any] {
        [
            "id": "chatcmpl-fake",
            "object": "chat.completion.chunk",
            "model": model,
            "choices": [[
                "index": 0,
                "delta": delta,
            ] as [String: Any]],
        ]
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
