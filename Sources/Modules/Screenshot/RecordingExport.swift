// requestMediaDataWhenReady 的回调队列里触达 reader/writer 是 AVFoundation 的约定用法，
// 其类型未标 Sendable 属于 SDK 滞后，preconcurrency 导入以消除误报。
@preconcurrency import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// 录制文件的后处理：双音轨混为单轨（视频直通）、MP4 转 GIF。
/// 全部离线处理，典型片段秒级完成。
enum RecordingExport {

    // MARK: - 混音单轨

    /// 把双音轨 MP4 混为单条 AAC 音轨，视频样本直通不转码，原地替换文件。
    /// 单轨/无音轨直接返回 true；失败保留原文件返回 false。
    static func mixAudioTracks(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let audioTracks = try? await asset.loadTracks(withMediaType: .audio) else { return false }
        guard audioTracks.count >= 2 else { return true }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mixing.mp4")
        try? FileManager.default.removeItem(at: tmp)

        do {
            let reader = try AVAssetReader(asset: asset)
            // outputSettings nil = 压缩样本直通。
            let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            // AudioMixOutput 负责把多条音轨解码并叠加为一路 PCM。
            let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
            guard reader.canAdd(videoOut), reader.canAdd(audioOut) else { return false }
            reader.add(videoOut)
            reader.add(audioOut)

            let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
            let videoFormat = try await videoTrack.load(.formatDescriptions).first
            let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                             sourceFormatHint: videoFormat)
            videoIn.expectsMediaDataInRealTime = false
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000
            ])
            audioIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoIn), writer.canAdd(audioIn) else { return false }
            writer.add(videoIn)
            writer.add(audioIn)

            guard reader.startReading(), writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pump(from: videoOut, to: videoIn, label: "mix.video") }
                group.addTask { await pump(from: audioOut, to: audioIn, label: "mix.audio") }
            }

            await writer.finishWriting()
            guard writer.status == .completed, reader.status != .failed else {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
            // 原地替换。
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// 把 reader output 的样本泵进 writer input，直到读尽。
    private static func pump(from output: AVAssetReaderOutput, to input: AVAssetWriterInput,
                             label: String) async {
        let queue = DispatchQueue(label: "com.baobox.app." + label)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        input.append(sample)
                    } else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }

    // MARK: - GIF 导出

    /// MP4 → GIF：固定时间网格采样（≤10fps，长片段自动降帧率控制在 300 帧内），
    /// 宽度缩到 ≤720px，无限循环。成功返回 GIF 路径。
    static func exportGIF(from url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let durationCM = try? await asset.load(.duration),
              let naturalSize = try? await track.load(.naturalSize) else { return nil }
        let duration = durationCM.seconds
        guard duration > 0.05, naturalSize.width > 0 else { return nil }

        var fps = 10.0
        let maxFrames = 300.0
        if duration * fps > maxFrames { fps = maxFrames / duration }
        let frameCount = max(1, Int(duration * fps))
        let interval = 1.0 / fps

        let scale = min(1, 720 / naturalSize.width)
        let outW = max(2, Int(naturalSize.width * scale))
        let outH = max(2, Int(naturalSize.height * scale))

        let gifURL = url.deletingPathExtension().appendingPathExtension("gif")
        try? FileManager.default.removeItem(at: gifURL)
        guard let dest = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString,
                                                         frameCount, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: interval,
                                            kCGImagePropertyGIFDelayTime: interval]
        ] as CFDictionary

        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            // 逐槽位取"时间戳不超过该槽"的最新一帧；源帧稀疏时复用上一帧。
            var lastImage: CGImage?
            var pending: (image: CGImage, pts: Double)?
            var written = 0
            for slot in 0..<frameCount {
                let slotTime = Double(slot) * interval
                while true {
                    if let p = pending {
                        if p.pts <= slotTime {
                            lastImage = p.image
                            pending = nil
                        } else {
                            break
                        }
                    } else if let sample = output.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if let image = downscaledImage(from: sample, width: outW, height: outH) {
                            pending = (image, pts)
                        }
                    } else {
                        break
                    }
                }
                if let image = lastImage {
                    CGImageDestinationAddImage(dest, image, frameProps)
                    written += 1
                } else if let p = pending {
                    // 首槽早于首帧：用首帧补位。
                    CGImageDestinationAddImage(dest, p.image, frameProps)
                    lastImage = p.image
                    pending = nil
                    written += 1
                }
            }
            reader.cancelReading()

            // 声明帧数与实际写入必须一致，否则 finalize 失败；不足则补最后一帧。
            while written < frameCount, let image = lastImage {
                CGImageDestinationAddImage(dest, image, frameProps)
                written += 1
            }
            guard written == frameCount, CGImageDestinationFinalize(dest) else {
                try? FileManager.default.removeItem(at: gifURL)
                return nil
            }
            return gifURL
        } catch {
            try? FileManager.default.removeItem(at: gifURL)
            return nil
        }
    }

    /// BGRA 像素缓冲 → 缩放后的 CGImage。
    private static func downscaledImage(from sample: CMSampleBuffer, width: Int, height: Int) -> CGImage? {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let srcW = CVPixelBufferGetWidth(buffer)
        let srcH = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let srcCtx = CGContext(data: base, width: srcW, height: srcH, bitsPerComponent: 8,
                                     bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: info),
              let srcImage = srcCtx.makeImage() else { return nil }
        if srcW == width && srcH == height { return srcImage }

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
