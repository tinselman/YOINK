import AVFoundation
import AppKit
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No capturable display was found."
        case .writeFailed(let m): return "The recording could not be written: \(m)"
        }
    }
}

/// Captures a display (optionally cropped to a rectangle) plus stereo system audio
/// and writes a QuickTime .mov.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var stopping = false
    private var outputURL: URL?

    private let queue = DispatchQueue(label: "com.robynmiller.screencap.capture")

    var onFailure: ((Error) -> Void)?

    /// - Parameter region: area to record in AppKit screen coordinates, or nil for the whole display.
    func start(region: NSRect?, url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Pick the display holding the region (or the main display).
        let anchor = region?.center ?? (NSScreen.main?.frame.center ?? .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }

        // Never capture our own overlays, dimming or controls.
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = screen?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()

        if let region {
            // sourceRect is in points, top-left origin, relative to the display.
            let flipped = Coord.flip(region)
            config.sourceRect = CGRect(x: flipped.minX - display.frame.minX,
                                       y: flipped.minY - display.frame.minY,
                                       width: flipped.width, height: flipped.height)
            config.width = even(region.width * scale)
            config.height = even(region.height * scale)
        } else {
            config.width = even(CGFloat(display.width) * scale)
            config.height = even(CGFloat(display.height) * scale)
        }

        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 8
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        try setUpWriter(url: url, width: config.width, height: config.height)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        outputURL = url
    }

    func stop() async throws -> URL {
        queue.sync { stopping = true }
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        guard let writer, let url = outputURL else { throw RecorderError.writeFailed("no active recording") }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        let status = writer.status
        let error = writer.error
        reset()

        guard status == .completed else {
            throw RecorderError.writeFailed(error?.localizedDescription ?? "unknown error")
        }
        return url
    }

    private func reset() {
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false
        stopping = false
        outputURL = nil
    }

    private func even(_ v: CGFloat) -> Int {
        var n = Int(v.rounded())
        if n % 2 != 0 { n -= 1 }
        return max(n, 2)
    }

    private func setUpWriter(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)

        let bitrate = min(Int(Double(width * height) * 6.0), 60_000_000)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 256_000,
        ])
        audio.expectsMediaDataInRealTime = true

        if w.canAdd(video) { w.add(video) }
        if w.canAdd(audio) { w.add(audio) }
        guard w.startWriting() else {
            throw RecorderError.writeFailed(w.error?.localizedDescription ?? "could not start writing")
        }

        writer = w
        videoInput = video
        audioInput = audio
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping, CMSampleBufferDataIsReady(sampleBuffer), let writer, writer.status == .writing else { return }

        switch type {
        case .screen:
            guard isCompleteFrame(sampleBuffer) else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                sessionStarted = true
            }
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio:
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        default:
            break
        }
    }

    private func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
