import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var audioCapture: Any?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let audioChannel = FlutterMethodChannel(
      name: "com.lorraine.meeting/audio_capture",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    audioChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "isSupported":
        if #available(macOS 15.0, *) { result(true) } else { result(false) }
      case "start":
        guard #available(macOS 15.0, *),
              let arguments = call.arguments as? [String: Any],
              let outputPath = arguments["outputPath"] as? String
        else {
          result(FlutterError(code: "unsupported", message: "System and microphone capture requires macOS 15 or newer.", details: nil))
          return
        }
        let capture = MeetingAudioCapture()
        self.audioCapture = capture
        Task {
          do {
            try await capture.start(outputPath: outputPath)
            result(nil)
          } catch {
            self.audioCapture = nil
            result(FlutterError(code: "capture_start", message: error.localizedDescription, details: nil))
          }
        }
      case "stop":
        guard #available(macOS 15.0, *), let capture = self.audioCapture as? MeetingAudioCapture else {
          result(FlutterError(code: "not_recording", message: "No recording is in progress.", details: nil))
          return
        }
        Task {
          do {
            let path = try await capture.stop()
            self.audioCapture = nil
            result(path)
          } catch {
            result(FlutterError(code: "capture_stop", message: error.localizedDescription, details: nil))
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
