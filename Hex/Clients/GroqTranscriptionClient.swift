import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let groqTranscriptionLogger = HexLog.transcription

struct GroqTranscriptionConfiguration: Sendable {
  var model: GroqTranscriptionModel
  var apiKey: String
  var language: String?
}

enum GroqTranscriptionError: LocalizedError {
  case missingAPIKey
  case invalidResponse
  case emptyResponse
  case requestFailed(Int, String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Add a Groq API key in Transcription Model settings."
    case .invalidResponse:
      return "Groq returned an invalid transcription response."
    case .emptyResponse:
      return "Groq returned an empty transcription."
    case let .requestFailed(status, message):
      return "Groq transcription failed (\(status)): \(message)"
    }
  }
}

@DependencyClient
struct GroqTranscriptionClient {
  var transcribe: @Sendable (URL, GroqTranscriptionConfiguration) async throws -> String
}

extension GroqTranscriptionClient: DependencyKey {
  static var liveValue: Self {
    Self { audioURL, configuration in
      let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !apiKey.isEmpty else { throw GroqTranscriptionError.missingAPIKey }

      let boundary = "HexBoundary-\(UUID().uuidString)"
      let audio = try Data(contentsOf: audioURL)
      var body = Data()
      body.appendMultipartField(name: "model", value: configuration.model.rawValue, boundary: boundary)
      body.appendMultipartField(name: "response_format", value: "json", boundary: boundary)
      if let language = configuration.language?.trimmingCharacters(in: .whitespacesAndNewlines),
         !language.isEmpty
      {
        body.appendMultipartField(name: "language", value: language, boundary: boundary)
      }
      body.appendMultipartFile(
        name: "file",
        filename: audioURL.lastPathComponent,
        mimeType: mimeType(for: audioURL),
        data: audio,
        boundary: boundary
      )
      body.append("--\(boundary)--\r\n")

      var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 90
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      request.httpBody = body

      groqTranscriptionLogger.notice(
        "Uploading audio to Groq model=\(configuration.model.rawValue, privacy: .public) bytes=\(audio.count)"
      )
      let start = Date()
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw GroqTranscriptionError.invalidResponse
      }
      guard (200..<300).contains(httpResponse.statusCode) else {
        let message = (try? JSONDecoder().decode(GroqErrorResponse.self, from: data).error.message)
          ?? String(data: data, encoding: .utf8)
          ?? "Unknown error"
        throw GroqTranscriptionError.requestFailed(httpResponse.statusCode, message)
      }

      let parsed = try JSONDecoder().decode(GroqTranscriptionResponse.self, from: data)
      let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw GroqTranscriptionError.emptyResponse }
      groqTranscriptionLogger.info(
        "Groq transcription completed in \(String(format: "%.2f", Date().timeIntervalSince(start)))s"
      )
      return text
    }
  }
}

extension DependencyValues {
  var groqTranscription: GroqTranscriptionClient {
    get { self[GroqTranscriptionClient.self] }
    set { self[GroqTranscriptionClient.self] = newValue }
  }
}

private struct GroqTranscriptionResponse: Decodable {
  let text: String
}

private struct GroqErrorResponse: Decodable {
  struct APIError: Decodable { let message: String }
  let error: APIError
}

private extension Data {
  mutating func append(_ string: String) {
    append(Data(string.utf8))
  }

  mutating func appendMultipartField(name: String, value: String, boundary: String) {
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
    append("\(value)\r\n")
  }

  mutating func appendMultipartFile(
    name: String,
    filename: String,
    mimeType: String,
    data: Data,
    boundary: String
  ) {
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
    append("Content-Type: \(mimeType)\r\n\r\n")
    append(data)
    append("\r\n")
  }
}

private func mimeType(for url: URL) -> String {
  switch url.pathExtension.lowercased() {
  case "wav": "audio/wav"
  case "m4a": "audio/mp4"
  case "mp3": "audio/mpeg"
  case "flac": "audio/flac"
  case "ogg": "audio/ogg"
  case "webm": "audio/webm"
  default: "application/octet-stream"
  }
}
