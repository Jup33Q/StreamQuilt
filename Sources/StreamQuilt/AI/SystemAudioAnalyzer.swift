import Accelerate
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures application audio output via ScreenCaptureKit (macOS 13+) and
/// feeds the shared AudioDSP chain — real spectrum/beat/pitch straight from
/// the playback output, no mic, no DRM file access (the OS mix is captured,
/// not the protected PCM).
///
/// Targets Music.app when it is running; falls back to the whole-system mix
/// otherwise. Video is minimized to a 2x2 / 1 fps stream (a display filter is
/// required to get audio at all) — GPU overhead is negligible.
///
/// TCC: needs "Screen & System Audio Recording" permission, which a bare CLI
/// binary cannot hold reliably — run from the .app bundle (scripts/build_app.sh).
/// Denied/missing permission prints a hint and degrades to silent groove.
public final class SystemAudioAnalyzer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let dsp = AudioDSP()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "streamquilt.sysaudio")
    private var scratch: [Float] = []
    private var ablStorage: [UInt8] = []
    private var warnedFormat = false
    private var loggedFirstBuffer = false

    public override init() { super.init() }

    /// Latest analysis (same shape as the mic path).
    public var current: AudioDSP.Output { dsp.current }

    public private(set) var isRunning = false

    public func start() {
        guard !isRunning, stream == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            print("[audio] screen/system-audio recording permission missing — requesting…")
            CGRequestScreenCaptureAccess()
            print("[audio] grant the permission to the .app (scripts/build_app.sh), " +
                  "then restart — falling back to silent groove")
            return
        }
        Task { await self.configureAndStart() }
    }

    public func stop() {
        guard let s = stream else { return }
        stream = nil
        isRunning = false
        Task { try? await s.stopCapture() }
    }

    private func configureAndStart() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                print("[audio] no display available for the capture filter")
                return
            }
            let filter: SCContentFilter
            if let music = content.applications.first(where: {
                $0.bundleIdentifier == "com.apple.Music"
            }) {
                filter = SCContentFilter(display: display, including: [music],
                                         exceptingWindows: [])
                print("[audio] targeting Music.app output")
            } else {
                filter = SCContentFilter(display: display, excludingApplications: [],
                                         exceptingWindows: [])
                print("[audio] Music.app not running — capturing the system mix")
            }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 1
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            isRunning = true
            print("[audio] system capture running")
        } catch {
            print("[audio] system capture failed: \(error.localizedDescription)")
        }
    }

    // MARK: SCStreamOutput

    // The protocol witness is `stream(_:didOutputSampleBuffer:of:)` — NOT
    // `streamOutput(...)`: SCStreamOutput's methods are @optional, so a
    // mis-named implementation compiles fine and is simply never called.
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let asbd = CMSampleBufferGetFormatDescription(sampleBuffer)?
                .audioStreamBasicDescription else { return }
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else {
            if !warnedFormat {
                warnedFormat = true
                print("[audio] unexpected sample format (flags \(asbd.mFormatFlags), " +
                      "\(asbd.mBitsPerChannel) bits) — expected float32, skipping buffers")
            }
            return
        }
        var needed = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil) == noErr, needed > 0 else { return }
        if ablStorage.count < needed { ablStorage = [UInt8](repeating: 0, count: needed) }
        var blockBuffer: CMBlockBuffer?
        let ok = ablStorage.withUnsafeMutableBytes { raw -> Bool in
            let ablPtr = raw.baseAddress!.assumingMemoryBound(to: AudioBufferList.self)
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: ablPtr,
                bufferListSize: needed, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0,
                blockBufferOut: &blockBuffer) == noErr else { return false }
            let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard let buf = buffers.first, let data = buf.mData else { return false }
            let p = data.assumingMemoryBound(to: Float.self)
            let ch = max(1, Int(buf.mNumberChannels))
            let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / ch
            guard frames > 0 else { return false }
            if !loggedFirstBuffer {
                var rms: Float = 0
                vDSP_rmsqv(p, 1, &rms, vDSP_Length(min(frames * ch, 4096)))
                print("[audio] first buffer: \(buffers.count) buffer(s), \(ch) ch, " +
                      "\(frames) frames @\(Int(asbd.mSampleRate)) Hz, rms \(rms)")
                loggedFirstBuffer = true
            }
            let sr = Float(asbd.mSampleRate)
            if ch == 1 {
                dsp.feed(p, count: frames, sampleRate: sr)
            } else {
                // interleaved: take channel 0 with a stride gather
                if scratch.count < frames { scratch = [Float](repeating: 0, count: frames) }
                scratch.withUnsafeMutableBufferPointer { s in
                    for i in 0..<frames { s[i] = p[i * ch] }
                    dsp.feed(s.baseAddress!, count: frames, sampleRate: sr)
                }
            }
            return true
        }
        if !ok { return }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[audio] system capture stopped: \(error.localizedDescription)")
        isRunning = false
    }
}
