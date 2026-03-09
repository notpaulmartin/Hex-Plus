import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let llmPostProcessingLogger = HexLog.transcription

struct LLMPostProcessingConfiguration: Sendable {
  var promptPrefix: String
  var provider: LLMProvider
  var model: String
  var apiKey: String
  var baseURL: String
}

enum LLMPostProcessingError: LocalizedError {
  case missingAPIKey
  case invalidEndpoint
  case invalidResponse
  case emptyResponse
  case requestFailed(Int, String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "LLM API key is missing."
    case .invalidEndpoint:
      return "LLM endpoint URL is invalid."
    case .invalidResponse:
      return "LLM response format is invalid."
    case .emptyResponse:
      return "LLM response did not contain output text."
    case let .requestFailed(status, message):
      return "LLM request failed (\(status)): \(message)"
    }
  }
}

@DependencyClient
struct LLMPostProcessingClient {
  var process: @Sendable (String, LLMPostProcessingConfiguration) async throws -> String
}

extension LLMPostProcessingClient: DependencyKey {
  static var liveValue: Self {
    Self(
      process: { text, configuration in
        switch configuration.provider {
        case .openAICompatible:
          let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !apiKey.isEmpty else {
            throw LLMPostProcessingError.missingAPIKey
          }

          guard let endpoint = normalizedOpenAICompatibleEndpoint(from: configuration.baseURL) else {
            throw LLMPostProcessingError.invalidEndpoint
          }

          let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
          let promptPrefix = configuration.promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
          let prompt = promptPrefix.isEmpty
            ? text
            : "\(promptPrefix)\n\nTranscript:\n```\n\(text)\n```"
          let requestBody = OpenAIChatCompletionsRequest(
            model: model,
            messages: [
              .init(role: "user", content: prompt),
            ],
            temperature: 0
          )

          var request = URLRequest(url: endpoint)
          request.httpMethod = "POST"
          request.timeoutInterval = 45
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
          request.httpBody = try JSONEncoder().encode(requestBody)

          llmPostProcessingLogger.info("Running LLM post-processing with model \(model, privacy: .public)")

          let (data, response) = try await URLSession.shared.data(for: request)
          guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMPostProcessingError.invalidResponse
          }

          guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data).error.message)
              ?? String(data: data, encoding: .utf8)
              ?? "Unknown error"
            throw LLMPostProcessingError.requestFailed(httpResponse.statusCode, message)
          }

          let parsed = try JSONDecoder().decode(OpenAIChatCompletionsResponse.self, from: data)
          guard let content = parsed.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw LLMPostProcessingError.invalidResponse
          }
          guard !content.isEmpty else {
            throw LLMPostProcessingError.emptyResponse
          }
          return content
        }
      }
    )
  }
}

extension DependencyValues {
  var llmPostProcessing: LLMPostProcessingClient {
    get { self[LLMPostProcessingClient.self] }
    set { self[LLMPostProcessingClient.self] = newValue }
  }
}

private func normalizedOpenAICompatibleEndpoint(from rawValue: String) -> URL? {
  let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    return nil
  }

  guard var url = URL(string: trimmed) else {
    return nil
  }

  let normalizedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  if normalizedPath.hasSuffix("chat/completions") {
    return url
  }

  url.append(path: "chat")
  url.append(path: "completions")
  return url
}

private struct OpenAIChatCompletionsRequest: Encodable {
  struct Message: Encodable {
    let role: String
    let content: String
  }

  let model: String
  let messages: [Message]
  let temperature: Int
}

private struct OpenAIChatCompletionsResponse: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String?
    }

    let message: Message
  }

  let choices: [Choice]
}

private struct OpenAIErrorResponse: Decodable {
  struct APIError: Decodable {
    let message: String
  }

  let error: APIError
}
