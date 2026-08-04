import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import UserNotifications

private let systemNotificationLogger = HexLog.app

@DependencyClient
struct SystemNotificationClient {
  var notify: @Sendable (_ title: String, _ body: String) async -> Void
}

extension SystemNotificationClient: DependencyKey {
  static var liveValue: Self {
    Self { title, body in
      let center = UNUserNotificationCenter.current()

      do {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
          guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            systemNotificationLogger.notice("System notification permission was not granted")
            return
          }
        case .denied:
          systemNotificationLogger.notice("System notifications are disabled for Hex")
          return
        case .authorized, .provisional, .ephemeral:
          break
        @unknown default:
          return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
          identifier: "com.notpaul.HexPlus.\(UUID().uuidString)",
          content: content,
          trigger: nil
        )
        try await center.add(request)
      } catch {
        systemNotificationLogger.error(
          "Failed to send system notification: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }
}

extension DependencyValues {
  var systemNotification: SystemNotificationClient {
    get { self[SystemNotificationClient.self] }
    set { self[SystemNotificationClient.self] = newValue }
  }
}
