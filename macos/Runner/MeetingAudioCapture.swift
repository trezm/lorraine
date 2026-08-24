import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(macOS 15.0, *)
final class MeetingAudioCapture: NSObject, SCStreamOutput {
  /// RMS level (full scale = 1) a buffer must reach to count as someone
  /// speaking. Normal speech sits well above this; room tone sits well below.
  private static let speechRMSThreshold: Float = 0.02

  private let systemQueue = DispatchQueue(label: "com.lorraine.capture.system")
  private let microphoneQueue = DispatchQueue(label: "com.lorraine.capture.microphone")
  private var stream: SCStream?
  private var systemWriter: AudioTrackWriter?
  private var microphoneWriter: AudioTrackWriter?
  private var finalURL: URL?
  private let activityLock = NSLock()
  private var lastAudioAt = Date()

  /// Seconds since either track last carried sound above the speech
  /// threshold. Measured from the start of the recording until then.
  func secondsSinceAudio() -> Double {
    activityLock.withLock { Date().timeIntervalSince(lastAudioAt) }
  }

  func start(outputPath: String) async throws {
    guard stream == nil else { throw CaptureError.alreadyRecording }
    let outputURL = URL(fileURLWithPath: outputPath)
    let directory = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: outputURL)

    let systemURL = directory.appendingPathComponent("\(outputURL.deletingPathExtension().lastPathComponent)-system.m4a")
    let microphoneURL = directory.appendingPathComponent("\(outputURL.deletingPathExtension().lastPathComponent)-microphone.m4a")
    try? FileManager.default.removeItem(at: systemURL)
    try? FileManager.default.removeItem(at: microphoneURL)

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else { throw CaptureError.noDisplay }
    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = 48_000
    configuration.channelCount = 2
    configuration.captureMicrophone = true

    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
    systemWriter = try AudioTrackWriter(url: systemURL)
    microphoneWriter = try AudioTrackWriter(url: microphoneURL)
    finalURL = outputURL
    activityLock.withLock { lastAudioAt = Date() }
    self.stream = stream
    try await stream.startCapture()
  }

  func stop() async throws -> String {
    guard let stream, let finalURL else { throw CaptureError.notRecording }
    try await stream.stopCapture()
    self.stream = nil

    let systemURL = try await systemWriter?.finish()
    let microphoneURL = try await microphoneWriter?.finish()
    systemWriter = nil
    microphoneWriter = nil

    let inputs = [systemURL, microphoneURL].compactMap { $0 }
    guard !inputs.isEmpty else { throw CaptureError.noAudio }
    try await Self.mix(inputs: inputs, output: finalURL)
    for input in inputs { try? FileManager.default.removeItem(at: input) }
    self.finalURL = nil
    return finalURL.path
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
    guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    switch outputType {
    case .audio:
      noteActivity(in: sampleBuffer)
      systemWriter?.append(sampleBuffer)
    case .microphone:
      noteActivity(in: sampleBuffer)
      microphoneWriter?.append(sampleBuffer)
    default:
      break
    }
  }

  private func noteActivity(in sample: CMSampleBuffer) {
    guard let format = CMSampleBufferGetFormatDescription(sample),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM
    else { return }
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    var energy: Float = 0
    var count = 0
    try? sample.withAudioBufferList { bufferList, _ in
      for buffer in bufferList {
        guard let data = buffer.mData else { continue }
        // Every 4th sample is plenty of resolution for a speech gate.
        if isFloat, asbd.mBitsPerChannel == 32 {
          let values = data.assumingMemoryBound(to: Float32.self)
          for index in stride(from: 0, to: Int(buffer.mDataByteSize) / 4, by: 4) {
            energy += values[index] * values[index]
            count += 1
          }
        } else if !isFloat, asbd.mBitsPerChannel == 16 {
          let values = data.assumingMemoryBound(to: Int16.self)
          for index in stride(from: 0, to: Int(buffer.mDataByteSize) / 2, by: 4) {
            let value = Float(values[index]) / Float(Int16.max)
            energy += value * value
            count += 1
          }
        }
      }
    }
    guard count > 0, (energy / Float(count)).squareRoot() >= Self.speechRMSThreshold else { return }
    activityLock.withLock { lastAudioAt = Date() }
  }

  private static func mix(inputs: [URL], output: URL) async throws {
    try? FileManager.default.removeItem(at: output)
    if inputs.count == 1 {
      try FileManager.default.copyItem(at: inputs[0], to: output)
      return
    }

    let composition = AVMutableComposition()
    var parameters: [AVMutableAudioMixInputParameters] = []
    for url in inputs {
      let asset = AVURLAsset(url: url)
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      let duration = try await asset.load(.duration)
      guard let source = tracks.first,
            let target = composition.addMutableTrack(
              withMediaType: .audio,
              preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
      try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
      let input = AVMutableAudioMixInputParameters(track: target)
      input.setVolume(0.82, at: .zero)
      parameters.append(input)
    }

    guard !parameters.isEmpty,
          let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
    else { throw CaptureError.couldNotMix }
    let mix = AVMutableAudioMix()
    mix.inputParameters = parameters
    exporter.audioMix = mix
    try await exporter.export(to: output, as: .m4a)
  }
}

@available(macOS 15.0, *)
private final class AudioTrackWriter {
  private let writer: AVAssetWriter
  private var input: AVAssetWriterInput?
  private var wroteSample = false
  private let lock = NSLock()

  init(url: URL) throws {
    writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
  }

  func append(_ sample: CMSampleBuffer) {
    lock.lock()
    defer { lock.unlock() }
    if input == nil {
      guard let format = CMSampleBufferGetFormatDescription(sample),
            let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)
      else { return }
      let channels = max(1, Int(basic.pointee.mChannelsPerFrame))
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
      ]
      let newInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
      newInput.expectsMediaDataInRealTime = true
      guard writer.canAdd(newInput) else { return }
      writer.add(newInput)
      input = newInput
      guard writer.startWriting() else { return }
      writer.startSession(atSourceTime: sample.presentationTimeStamp)
    }
    guard let input, input.isReadyForMoreMediaData else { return }
    wroteSample = input.append(sample) || wroteSample
  }

  func finish() async throws -> URL? {
    let hasAudio = lock.withLock {
      input?.markAsFinished()
      return wroteSample
    }
    guard hasAudio else {
      writer.cancelWriting()
      return nil
    }
    await withCheckedContinuation { continuation in
      writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else {
      throw writer.error ?? CaptureError.couldNotWrite
    }
    return writer.outputURL
  }
}

enum CaptureError: LocalizedError {
  case alreadyRecording, notRecording, noDisplay, noAudio, couldNotWrite, couldNotMix

  var errorDescription: String? {
    switch self {
    case .alreadyRecording: return "A recording is already in progress."
    case .notRecording: return "No recording is in progress."
    case .noDisplay: return "No display is available for system audio capture."
    case .noAudio: return "No microphone or system audio was captured. Check permissions."
    case .couldNotWrite: return "The audio file could not be written."
    case .couldNotMix: return "The microphone and system audio could not be mixed."
    }
  }
}
