import Foundation

/// The one `LLMProvider` implementation in v1 (SPEC Alt D): OpenAI-compatible
/// chat-completions over URLSession, streaming via SSE, with per-endpoint
/// deviations handled by `profile.quirks` rather than by separate clients.
public struct OpenAICompatibleClient: LLMProvider {
    let profile: EndpointProfile
    let apiKey: String?
    let session: URLSession

    public init(profile: EndpointProfile, apiKey: String?, session: URLSession = .shared) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(request, into: continuation)
                    continuation.finish()
                } catch {
                    let mapped = Self.mappedTransport(error)
                    // Consumer-driven cancellation is not a failed LLM call;
                    // logging it as one would make the diagnostics lie.
                    if !(mapped is CancellationError) {
                        ProviderLog.failed(model: request.model, purpose: request.purpose, error: mapped)
                    }
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func completeReportingUsage<T: Decodable>(
        _ request: CompletionRequest,
        as type: T.Type
    ) async throws -> CompletedCall<T> {
        let urlRequest = try makeURLRequest(request, streaming: false)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.mappedTransport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse("response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw ProviderError.malformedResponse("body is not a chat completion with message content")
        }

        // Validation happens here and nowhere earlier (SPEC §6.3: render
        // partial JSON as it streams, validate only the final object). A
        // truncated payload fails to decode and throws — it never becomes a
        // half-populated `T`.
        do {
            let usage = Self.usage(from: object["usage"] as? [String: Any])
            let value = try JSONDecoder().decode(T.self, from: Data(content.utf8))
            ProviderLog.completed(
                model: request.model,
                purpose: request.purpose,
                streaming: false,
                usage: usage,
                finishReason: (choices.first?["finish_reason"] as? String)
            )
            return CompletedCall(value: value, usage: usage)
        } catch let error as ProviderError {
            throw error
        } catch {
            let failure = ProviderError.decodingFailed(String(describing: error))
            ProviderLog.failed(model: request.model, purpose: request.purpose, error: failure)
            throw failure
        }
    }

    // MARK: - Streaming

    private func runStream(
        _ request: CompletionRequest,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(request, streaming: true)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        try await Self.checkStatus(of: response, bytes: bytes)

        // `finish_reason` and `usage` arrive on different chunks (OpenAI sends
        // usage on a trailing chunk with an empty `choices` array), so both are
        // accumulated and emitted as one terminal `.completed` when the stream
        // ends — exactly once, always after every token.
        var finishReason: String?
        var usage: TokenUsage?
        var sawTerminator = false

        var parser = SSEEventParser()
        for try await byte in bytes {
            guard let rawPayload = parser.consume(byte) else { continue }
            let payload = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { continue } // `data:` keep-alives
            if payload == "[DONE]" {
                sawTerminator = true
                break
            }

            let chunk = try Self.decodeChunk(payload)
            if let reasoning = chunk.reasoning, !reasoning.isEmpty {
                continuation.yield(.reasoning(reasoning))
            }
            if let content = chunk.content, !content.isEmpty {
                continuation.yield(.token(content))
            }
            if let reason = chunk.finishReason { finishReason = reason }
            if let chunkUsage = chunk.usage { usage = chunkUsage }
        }

        // Truncation is detected at the *protocol* level, not by trusting the
        // transport: a chunked body cut off mid-stream (server killed, network
        // dropped) ends URLSession's byte sequence **without an error** — proven
        // by the slice-02 RED run, where a truncated stream produced a clean
        // `.completed`. A caller that believed it would persist half an artifact
        // as though it were whole. An OpenAI-compatible stream is only complete
        // if it ended with `[DONE]` or delivered a `finish_reason`.
        guard sawTerminator || finishReason != nil else {
            throw ProviderError.transport("stream ended before completion (no [DONE] and no finish_reason)")
        }

        ProviderLog.completed(
            model: request.model,
            purpose: request.purpose,
            streaming: true,
            usage: usage,
            finishReason: finishReason
        )
        continuation.yield(.completed(Completion(finishReason: finishReason, usage: usage)))
    }

    private struct Chunk {
        var content: String?
        /// DeepSeek's thinking stream. Kept distinct from `content` so the
        /// panel never renders thinking as the answer, and so continuations can
        /// pass it back (`Quirks.passesBackReasoningContent`).
        var reasoning: String?
        var finishReason: String?
        var usage: TokenUsage?
    }

    private static func decodeChunk(_ payload: String) throws -> Chunk {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw ProviderError.malformedResponse("SSE chunk is not a JSON object: \(payload)")
        }

        // Failures after SSE headers are on the wire arrive in-band as a
        // `data: {"error": …}` event under HTTP 200 (OpenRouter documents
        // this; LiteLLM-style proxies do the same). Swallowing it would let a
        // failed, truncated generation present as a clean completion when the
        // server follows with `[DONE]` — the exact half-artifact failure the
        // completion guard exists to prevent.
        if let errorObject = object["error"] as? [String: Any] {
            let message = errorObject["message"] as? String
            if let code = errorObject["code"] as? Int, code >= 400 {
                throw Self.error(status: code, message: message)
            }
            throw ProviderError.inStreamError(message: message)
        }

        var chunk = Chunk()
        if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
            let delta = choice["delta"] as? [String: Any]
            chunk.content = delta?["content"] as? String
            chunk.reasoning = delta?["reasoning_content"] as? String
            chunk.finishReason = choice["finish_reason"] as? String
        }
        chunk.usage = Self.usage(from: object["usage"] as? [String: Any])
        return chunk
    }

    static func usage(from object: [String: Any]?) -> TokenUsage? {
        guard let object,
              let prompt = object["prompt_tokens"] as? Int,
              let completion = object["completion_tokens"] as? Int
        else { return nil }
        let cached = (object["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        return TokenUsage(promptTokens: prompt, cachedTokens: cached ?? 0, completionTokens: completion)
    }

    // MARK: - Errors

    /// Non-2xx replies carry their explanation in the body, so the body is
    /// drained before the error is built — callers surface these messages in
    /// the UI (PRD edge case: provider outage shows a subtle indicator).
    private static func checkStatus(of response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse("response was not HTTP")
        }
        guard !(200..<300).contains(http.statusCode) else { return }

        var body = Data()
        for try await byte in bytes { body.append(byte) }
        throw error(status: http.statusCode, body: body)
    }

    static func error(status: Int, body: Data) -> ProviderError {
        error(status: status, message: errorMessage(in: body))
    }

    static func error(status: Int, message: String?) -> ProviderError {
        switch status {
        case 429: return .rateLimited(message: message)
        case 500..<600: return .server(status: status, message: message)
        default: return .http(status: status, message: message)
        }
    }

    /// The failures URLSession itself throws (connection refused, DNS, TLS, a
    /// mid-stream RST) must surface typed like every other failure — the
    /// `LLMProvider` contract promises `ProviderError`, and degrade logic
    /// switching on it cannot classify a raw `URLError`. Cancellation is left
    /// untouched: it is the consumer's own doing, not a provider failure.
    static func mappedTransport(_ error: Error) -> Error {
        if error is ProviderError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            return ProviderError.transport(urlError.localizedDescription)
        }
        return error
    }

    /// OpenAI-compatible errors carry `{"error": {"message": …}}`; anything
    /// else falls back to the raw body so the cause isn't swallowed.
    private static func errorMessage(in body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Request construction

    private func makeURLRequest(_ request: CompletionRequest, streaming: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: profile.baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: try body(for: request, streaming: streaming),
            options: [.sortedKeys]
        )
        return urlRequest
    }

    func body(for request: CompletionRequest, streaming: Bool) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map(encoded),
            "stream": streaming,
        ]

        // Without this opt-in, OpenAI and OpenRouter never send the
        // usage-bearing trailing chunk: every streamed call would report
        // `usage == nil`, the metering decorator would book nothing, and the
        // per-meeting cap would be blind to the generation tier (FR-015).
        // DeepSeek volunteers usage by default and accepts the option.
        if streaming {
            body["stream_options"] = ["include_usage": true]
        }

        // DeepSeek V4 selects thinking per request, not via a separate model
        // id; endpoints without the field reject unknown top-level params, so
        // it is quirk-gated. Sent explicitly in both states rather than
        // trusting the endpoint's default.
        if profile.quirks.selectsThinkingViaRequestField {
            body["thinking"] = ["type": request.thinking ? "enabled" : "disabled"]
        }

        // Thinking models on some endpoints (DeepSeek) ignore sampling params
        // outright, and have rejected requests carrying them; the quirk drops
        // them rather than gambling on the endpoint's tolerance.
        let dropsSamplingParams = request.thinking && profile.quirks.ignoresSamplingParamsWhenThinking
        if !dropsSamplingParams, let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if let maxTokens = request.maxTokens { body["max_tokens"] = maxTokens }

        if let format = request.responseFormat {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": format.name,
                    // `strict` is what makes the endpoint enforce the schema
                    // instead of treating it as a suggestion.
                    "strict": true,
                    "schema": try format.schema.objectValue(),
                ] as [String: Any],
            ]
        }
        return body
    }

    /// Thinking endpoints reject a continuation whose assistant turn lost its
    /// `reasoning_content`; endpoints without the quirk reject the *presence*
    /// of the unknown field. One encoder, gated by the quirk.
    private func encoded(_ message: ChatMessage) -> [String: Any] {
        var encoded: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        if profile.quirks.passesBackReasoningContent, let reasoning = message.reasoningContent {
            encoded["reasoning_content"] = reasoning
        }
        return encoded
    }
}
