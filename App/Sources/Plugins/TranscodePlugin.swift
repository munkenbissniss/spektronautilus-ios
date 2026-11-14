import Foundation
import AVFoundation
import CoreMedia

/// Converting a video with the phone's own video chips (AVFoundation + VideoToolbox) instead of ffmpeg.wasm in the page:
/// several times faster, cooler, and the video is read from disk, not held in the page's memory.
/// It does the plain jobs (convert to H.264/HEVC mp4, resize, frame rate, trim, rotate by the clip's own orientation).
/// Anything with filters or loops still goes through ffmpeg.wasm; the page decides.
final class TranscodePlugin: Plugin, @unchecked Sendable {
    private weak var bridge: Bridge?
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var cancelled = false
    private let lock = NSLock()

    init(bridge: Bridge) { self.bridge = bridge }

    func call(_ method: String, _ args: [String: Any], done: @escaping (Any?) -> Void, fail: @escaping (String) -> Void) {
        switch method {
        case "probe":
            guard let name = args["file"] as? String, let u = Files.url(name) else { return fail("Bad file") }
            Task { do { done(try await Self.probe(u)) } catch { fail(error.localizedDescription) } }
        case "convert":
            guard let name = args["file"] as? String, let inURL = Files.url(name), let out = args["out"] as? String, let outURL = Files.url(out) else { return fail("Bad file") }
            lock.lock(); cancelled = false; lock.unlock()
            Task { do { try await self.convert(inURL, outURL, args); done(["size": (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?.intValue ?? 0]) }
                   catch { fail(error.localizedDescription) } }
        case "cancel":
            lock.lock(); cancelled = true; lock.unlock()
            reader?.cancelReading(); writer?.cancelWriting(); done(true)
        default: fail("Unknown method transcode.\(method)")
        }
    }

    // MARK: what is in the file?
    static func probe(_ url: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw err("No picture found in this file") }
        let size = try await vt.load(.naturalSize), t = try await vt.load(.preferredTransform)
        let r = CGRect(origin: .zero, size: size).applying(t)
        let dur = try await asset.load(.duration).seconds
        let fps = try await vt.load(.nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var codec = "h264"
        if let d = try await vt.load(.formatDescriptions).first {
            let sub = CMFormatDescriptionGetMediaSubType(d)
            switch sub { case kCMVideoCodecType_HEVC: codec = "hevc"; case kCMVideoCodecType_H264: codec = "h264"; default: codec = fourCC(sub) }
        }
        return ["width": Int(abs(r.width).rounded()), "height": Int(abs(r.height).rounded()), "duration": dur.isFinite ? dur : 0,
                "fps": Double(fps), "hasAudio": !audio.isEmpty, "codec": codec]
    }

    // MARK: converting
    /// args: width, height (final size, even numbers), fit ("fit" keeps the whole picture with black bars, anything else fills), fps (0 = keep),
    ///       codec ("h264" | "hevc"), bpp (bits per pixel per frame, quality), keepAudio, start, duration (seconds, 0 = to the end), gop
    private func convert(_ inURL: URL, _ outURL: URL, _ a: [String: Any]) async throws {
        let asset = AVURLAsset(url: inURL)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw Self.err("No picture found in this file") }
        let nat = try await vt.load(.naturalSize), pt = try await vt.load(.preferredTransform)
        let upright = CGRect(origin: .zero, size: nat).applying(pt)
        let sw = abs(upright.width), sh = abs(upright.height)
        let total = try await asset.load(.duration)

        func num(_ k: String, _ d: Double) -> Double { (a[k] as? NSNumber)?.doubleValue ?? d }
        let tw = max(2, Int(num("width", Double(sw))) / 2 * 2), th = max(2, Int(num("height", Double(sh))) / 2 * 2)
        var fps = num("fps", 0); if fps <= 0 { fps = Double(try await vt.load(.nominalFrameRate)) }; if fps <= 0 { fps = 30 }
        let start = max(0, num("start", 0)); var dur = num("duration", 0)
        let left = total.seconds - start; if dur <= 0 || dur > left { dur = left }
        if dur <= 0 { throw Self.err("The start time is after the end of this clip") }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: dur, preferredTimescale: 600))

        // size and orientation: one transform per frame, done on the graphics chip
        let fill = (a["fit"] as? String) != "fit"
        let s = fill ? max(Double(tw) / sw, Double(th) / sh) : min(Double(tw) / sw, Double(th) / sh)
        var t = pt.concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
        t = t.concatenating(CGAffineTransform(scaleX: s, y: s))
        t = t.concatenating(CGAffineTransform(translationX: (Double(tw) - sw * s) / 2, y: (Double(th) - sh * s) / 2))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vt); layer.setTransform(t, at: .zero)
        let inst = AVMutableVideoCompositionInstruction(); inst.timeRange = CMTimeRange(start: .zero, duration: total); inst.layerInstructions = [layer]; inst.backgroundColor = UIColorBlack
        let comp = AVMutableVideoComposition(); comp.instructions = [inst]; comp.renderSize = CGSize(width: tw, height: th)
        comp.frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))

        let reader = try AVAssetReader(asset: asset); reader.timeRange = range
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vt], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        vOut.videoComposition = comp; vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw Self.err("This video cannot be read") }; reader.add(vOut)

        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4); writer.shouldOptimizeForNetworkUse = true
        let hevc = (a["codec"] as? String) == "hevc", bpp = num("bpp", 0.2), gop = Int(num("gop", 30))
        var props: [String: Any] = [AVVideoAverageBitRateKey: Int(Double(tw * th) * fps * bpp), AVVideoMaxKeyFrameIntervalKey: max(1, gop), AVVideoExpectedSourceFrameRateKey: fps]
        if !hevc { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                                                                         AVVideoWidthKey: tw, AVVideoHeightKey: th, AVVideoCompressionPropertiesKey: props,
                                                                         AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                                                                     AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                                                                     AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw Self.err("This video cannot be written") }; writer.add(vIn)

        var aOut: AVAssetReaderAudioOutput?, aIn: AVAssetWriterInput?
        if (a["keepAudio"] as? Bool) == true, let at = try await asset.loadTracks(withMediaType: .audio).first {
            let o = AVAssetReaderAudioOutput(track: at, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000, AVEncoderBitRateKey: 192_000])
            i.expectsMediaDataInRealTime = false
            if reader.canAdd(o), writer.canAdd(i) { reader.add(o); writer.add(i); aOut = o; aIn = i }
        }

        self.reader = reader; self.writer = writer
        guard reader.startReading() else { throw reader.error ?? Self.err("Could not start reading") }
        guard writer.startWriting() else { throw writer.error ?? Self.err("Could not start writing") }
        writer.startSession(atSourceTime: range.start)

        // the video and the sound are written side by side, each when the writer is ready for more
        let group = DispatchGroup(), q = DispatchQueue(label: "spk.transcode.v"), qa = DispatchQueue(label: "spk.transcode.a")
        var lastP = 0.0
        group.enter()
        vIn.requestMediaDataWhenReady(on: q) { [weak self] in
            while vIn.isReadyForMoreMediaData {
                if let sb = vOut.copyNextSampleBuffer() {
                    vIn.append(sb)
                    let p = min(1, max(0, (CMSampleBufferGetPresentationTimeStamp(sb).seconds - start) / dur))
                    if p - lastP >= 0.01 { lastP = p; self?.bridge?.emit("transcode.progress", ["p": p]) }
                } else { vIn.markAsFinished(); group.leave(); return }
            }
        }
        if let aOut = aOut, let aIn = aIn {
            group.enter()
            aIn.requestMediaDataWhenReady(on: qa) {
                while aIn.isReadyForMoreMediaData {
                    if let sb = aOut.copyNextSampleBuffer() { aIn.append(sb) } else { aIn.markAsFinished(); group.leave(); return }
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { c.resume() } }

        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled || reader.status == .cancelled { writer.cancelWriting(); try? FileManager.default.removeItem(at: outURL); throw Self.err("Stopped") }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? Self.err("Reading failed") }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Self.err("Writing failed") }
        self.reader = nil; self.writer = nil
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "spk", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
    private static func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)], encoding: .ascii)?.trimmingCharacters(in: .whitespaces).lowercased() ?? "unknown"
    }
}

private let UIColorBlack = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
