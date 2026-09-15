import Cocoa
import FlutterMacOS
import UserNotifications

/// Bridges the Flutter "still meeting?" watchdog prompt to Notification Center,
/// so the check-in reaches the user while Lorraine sits behind the meeting app.
///
/// The notification carries "Keep recording" and "Stop and save" buttons that
/// answer the prompt without switching apps; clicking the banner itself brings
/// Lorraine to the front so the in-app countdown is visible.
final class MeetingNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let recordingAlertCategory = "com.lorraine.meeting.recording-alert"
  static let keepAction = "keep"
  static let stopAction = "stop"

  private let channel: FlutterMethodChannel
  private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    let keep = UNNotificationAction(
      identifier: Self.keepAction,
      title: "Keep recording",
      options: []
    )
    let stop = UNNotificationAction(
      identifier: Self.stopAction,
      title: "Stop and save",
      options: [.destructive]
    )
    let category = UNNotificationCategory(
      identifier: Self.recordingAlertCategory,
      actions: [keep, stop],
      intentIdentifiers: [],
      options: []
    )
    center.setNotificationCategories([category])
    center.delegate = self
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermission":
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "show":
      guard let arguments = call.arguments as? [String: Any],
            let identifier = arguments["id"] as? String,
            let title = arguments["title"] as? String,
            let body = arguments["body"] as? String
      else {
        result(FlutterError(code: "bad_arguments", message: "show requires id, title, and body.", details: nil))
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      content.categoryIdentifier = Self.recordingAlertCategory
      let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
      // Delivery fails when notifications are denied or not yet decided; the
      // Dart side treats `false` as "fall back to the in-app chime".
      center.add(request) { error in
        DispatchQueue.main.async { result(error == nil) }
      }
    case "clear":
      guard let arguments = call.arguments as? [String: Any],
            let identifier = arguments["id"] as? String
      else {
        result(FlutterError(code: "bad_arguments", message: "clear requires id.", details: nil))
        return
      }
      center.removePendingNotificationRequests(withIdentifiers: [identifier])
      center.removeDeliveredNotifications(withIdentifiers: [identifier])
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Show the banner even when Lorraine is frontmost; it is the same prompt
    // the in-app overlay shows and it lingers in Notification Center.
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    switch response.actionIdentifier {
    case Self.keepAction:
      channel.invokeMethod("recordingAlertAction", arguments: ["action": Self.keepAction])
    case Self.stopAction:
      channel.invokeMethod("recordingAlertAction", arguments: ["action": Self.stopAction])
    default:
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
    completionHandler()
  }
}
