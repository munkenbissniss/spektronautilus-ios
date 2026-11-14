import Foundation
import AVFoundation
import CoreML
import CoreImage
import CoreVideo

/// AI upscaling with a Core ML model (Real-ESRGAN converted with models/convert_realesrgan.py) on the phone's neural engine and graphics chip.
/// EXPERIMENTAL, and no model is shipped in this repository: put Upscale.mlpackage (or .mlmodelc) in App/Resources/Models and build again.
/// The model must take one image of a fixed size (for example 128x128) and return one image k times bigger (k = 2 or 4).
/// Big pictures are cut into overlapping tiles, each tile goes through the model, and the tiles are put together again.
final class UpscalePlugin: Plugin, @unchecked Sendable {
    private weak var bridge: Bridge?
    private var model: MLModel?
    private var inName = "", outName = "", tile = 0, scale = 1
    private var cancelled = false
    private var reader: AVAssetReader?, writer: AVAssetWriter?
    private let ci = CIContext(options: [.cacheIntermediates: false])

    init(bridge: Bridge) { self.bridge = bridge }

    private func load() throws {
        if model != nil { return }
        guard let url = Bundle.main.url(forResource: "Upscale", withExtension: "mlmodelc") else { throw NSError(domain: "spk", code: 2, userInfo: [NSLocalizedDescriptionKey: "No AI model in this build of the app"]) }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
        let m = try MLModel(contentsOf: url, configuration: cfg)
        guard let i = m.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let o = m.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .image }),
              let ic = i.value.imageConstraint, let oc = o.value.imageConstraint, ic.pixelsWide > 0 else {
            throw NSError(domain: "spk", code: 3, userInfo: [NSLocalizedDescriptionKey: "The AI model has the wrong shape (needs one image in, one image out)"])
        }
        inName = i.key; outName = o.key; tile = ic.pixelsWide; scale = max(1, oc.pixelsWide / ic.pixelsWide); model = m
    }

    func call(_ method: String, _ args: [String: Any], done: @escaping (Any?) -> Void, fail: @escaping (String) -> Void) {
        switch method {
        case "status":
            do { try load(); done(["ok": true, "tile": tile, "scale": scale]) }
            catch { done(["ok": false, "why": error.localizedDescription]) }
        case "run":     // { file, out, scale (only the model's own scale is possible), keepAudio }
            guard let name = args["file"] as? String, let inURL = Files.url(name), let out = args["out"] as? String, let outURL = Files.url(out) else { return fail("Bad file") }
            cancelled = false
            Task { do { try self.load(); try await self.run(inURL, outURL); done(["scale": self.scale]) } catch { fail(error.localizedDescription) } }
        case "cancel":
            cancelled = true; reader?.cancelReading(); writer?.cancelWriting(); done(true)
        default: fail("Unknown method upscale.\(method)")
        }
    }

    private func run(_ inURL: URL, _ outURL: URL) async throws {
        guard let model = model else { return }
        let asset = AVURLAsset(url: inURL)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "spk", code: 4, userInfo: [NSLocalizedDescriptionKey: "No picture found in this file"]) }
        let nat = try await vt.load(.naturalSize), pt = try await vt.load(.preferredTransform)
        let up = CGRect(origin: .zero, size: nat).applying(pt)
        let w = Int(abs(up.width)) / 2 * 2, h = Int(abs(up.height)) / 2 * 2, ow = w * scale, oh = h * scale
        let dur = try await asset.load(.duration).seconds, fps = max(1, Double(try await vt.load(.nominalFrameRate)))

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(vOut)
        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: ow, AVVideoHeightKey: oh,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(ow * oh) * fps * 0.15)]])
        vIn.transform = pt                                                         // keep the clip's own orientation
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: ow, kCVPixelBufferHeightKey as String: oh])
        writer.add(vIn)
        self.reader = reader; self.writer = writer
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? NSError(domain: "spk", code: 5) }
        writer.startSession(atSourceTime: .zero)

        let overlap = max(4, tile / 16), step = tile - 2 * overlap
        var tileBuf: CVPixelBuffer?; CVPixelBufferCreate(nil, tile, tile, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &tileBuf)
        guard let input = tileBuf else { return }
        var frameNo = 0
        while let sb = vOut.copyNextSampleBuffer() {
            if cancelled { reader.cancelReading(); writer.cancelWriting(); try? FileManager.default.removeItem(at: outURL); throw NSError(domain: "spk", code: 6, userInfo: [NSLocalizedDescriptionKey: "Stopped"]) }
            guard let px = CMSampleBufferGetImageBuffer(sb) else { continue }
            let src = CIImage(cvPixelBuffer: px).clampedToExtent()
            var canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: ow, height: oh))
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    // the tile that covers [x-overlap, x+step+overlap): cut it out, run the model, keep only the middle of the answer
                    let r = CGRect(x: x - overlap, y: y - overlap, width: tile, height: tile)
                    ci.render(src.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY)), to: input)
                    let features = try MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(pixelBuffer: input)])
                    let result = try model.prediction(from: features)
                    if let ob = result.featureValue(for: outName)?.imageBufferValue {
                        let o = CIImage(cvPixelBuffer: ob)
                        let keep = CGRect(x: overlap * scale, y: overlap * scale, width: min(step, w - x) * scale, height: min(step, h - y) * scale)
                        canvas = o.cropped(to: keep).transformed(by: CGAffineTransform(translationX: CGFloat(x * scale) - keep.minX, y: CGFloat(y * scale) - keep.minY)).composited(over: canvas)
                    }
                    x += step
                }
                y += step
            }
            var outBuf: CVPixelBuffer?
            while !vIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "spk", code: 7) }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
            guard let ob = outBuf else { throw NSError(domain: "spk", code: 8) }
            ci.render(canvas, to: ob)
            adaptor.append(ob, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sb))
            frameNo += 1
            if frameNo % 3 == 0 { bridge?.emit("upscale.progress", ["p": min(1, CMSampleBufferGetPresentationTimeStamp(sb).seconds / max(0.1, dur))]) }
        }
        vIn.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "spk", code: 9) }
        self.reader = nil; self.writer = nil
    }
}
