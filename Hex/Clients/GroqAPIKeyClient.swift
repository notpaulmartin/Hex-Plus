import Dependencies
import DependenciesMacros
import Foundation
import Security

private enum GroqCredential {
  static let service = "com.notpaul.HexPlus.groq"
  static let account = "api-key"
}

enum GroqAPIKeyError: LocalizedError {
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case let .keychain(status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
      return "Unable to access the Groq API key: \(message)"
    }
  }
}

@DependencyClient
struct GroqAPIKeyClient {
  var load: @Sendable () throws -> String = { "" }
  var save: @Sendable (String) throws -> Void
}

extension GroqAPIKeyClient: DependencyKey {
  static var liveValue: Self {
    Self(
      load: {
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: GroqCredential.service,
          kSecAttrAccount as String: GroqCredential.account,
          kSecReturnData as String: true,
          kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw GroqAPIKeyError.keychain(status) }
        guard let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
      },
      save: { apiKey in
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: GroqCredential.service,
          kSecAttrAccount as String: GroqCredential.account,
        ]
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          let status = SecItemDelete(query as CFDictionary)
          guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GroqAPIKeyError.keychain(status)
          }
          return
        }

        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(
          query as CFDictionary,
          [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
          throw GroqAPIKeyError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
          // Another save may have inserted the item after our update check. Retry the
          // update so concurrent callers converge on a valid value instead of failing.
          let retryStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
          )
          guard retryStatus == errSecSuccess else {
            throw GroqAPIKeyError.keychain(retryStatus)
          }
          return
        }
        guard addStatus == errSecSuccess else { throw GroqAPIKeyError.keychain(addStatus) }
      }
    )
  }
}

extension DependencyValues {
  var groqAPIKey: GroqAPIKeyClient {
    get { self[GroqAPIKeyClient.self] }
    set { self[GroqAPIKeyClient.self] = newValue }
  }
}
