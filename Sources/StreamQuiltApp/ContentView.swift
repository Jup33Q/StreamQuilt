import SwiftUI

struct ContentView: View {
    @ObservedObject var model: StreamQuiltModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusBar
            previewSection
            playbackBox
            audioStyleBox
            renderBox
            deviceBox
            if !model.lastError.isEmpty {
                Text(model.lastError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(16)
        .frame(minWidth: 480)
        .background(WindowAutosave(name: "StreamQuiltMainWindow"))
    }

    // MARK: - Top status bar (FPS / throughput / workers + emotion + live prompt)

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(String(format: "%.0f FPS · %.1f tiles/s · tile %.2f Hz · workers %d/%d",
                            model.fps, model.tilesPerSec, model.tileHz,
                            model.workersReady, model.workers))
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if !model.emotionLabel.isEmpty {
                    Text("🎭 \(model.emotionLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if !model.livePrompt.isEmpty {
                Text("Live: \(model.livePrompt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        ZStack {
            QuiltPreviewView(model: model)
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if model.pipelineLoading {
                ProgressView("Loading CoreML models…")
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Playback

    private var playbackBox: some View {
        GroupBox("Playback") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if model.audioSource == .music {
                        Button(action: { model.previousTrack() }) {
                            Image(systemName: "backward.fill")
                        }
                        Button(action: { model.togglePlayPause() }) {
                            Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        }
                        Button(action: { model.nextTrack() }) {
                            Image(systemName: "forward.fill")
                        }
                        Text(model.nowPlaying.isEmpty
                             ? "Music not playing"
                             : model.nowPlaying + (model.bpm > 0 ? " · \(model.bpm) BPM" : ""))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text(model.audioSource == .mic ? "Mic input" : "Audio linkage off")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                if model.audioSource == .music && !model.lyricLine.isEmpty {
                    Text("“\(model.lyricLine)”")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    ProgressView(value: model.lineProgress)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Audio & Style

    private var audioStyleBox: some View {
        GroupBox("Audio & Style") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Audio", selection: $model.audioSource) {
                        ForEach(AudioSourceKind.allCases) { k in
                            Text(k.label).tag(k)
                        }
                    }
                    .frame(width: 140)
                    Toggle("Lyric prompts", isOn: $model.lyricPrompt)
                    Spacer()
                    Toggle("Lyric overlay", isOn: $model.lyricOverlay)
                }
                HStack {
                    Text("Raw mix")
                    Slider(value: $model.altMix, in: 0...1)
                        .frame(width: 120)
                    Text("Beat hue")
                    Slider(value: $model.beatHue, in: 0...0.25)
                        .frame(width: 120)
                    Text("Beat glow")
                    Slider(value: $model.beatGlow, in: 0...1)
                        .frame(width: 120)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Render (Apply respawns the worker pool)

    private var renderBox: some View {
        GroupBox("Render") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Strength")
                    Slider(value: $model.strength, in: 0...1)
                    Text(String(format: "%.2f", model.strength))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                HStack {
                    Picker("Render size", selection: $model.renderSize) {
                        Text("320").tag(320)
                        Text("384").tag(384)
                        Text("512").tag(512)
                    }
                    .frame(width: 170)
                    Stepper("Workers: \(model.workers)", value: $model.workers, in: 1...4)
                    Picker("Grid", selection: $model.grid) {
                        Text("7×8 (56)").tag("7x8")
                        Text("11×6 (66)").tag("11x6")
                    }
                    .frame(width: 120)
                }
                if model.renderConfigDirty {
                    HStack {
                        Spacer()
                        Button("Apply render settings") { model.applyRenderConfig() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.pipelineLoading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Device

    private var deviceBox: some View {
        GroupBox("Device") {
            HStack {
                Toggle("Device fullscreen", isOn: $model.deviceFullscreen)
                    .disabled(!model.deviceAvailable && !model.deviceFullscreen)
                Toggle("Calibration test", isOn: $model.testPattern)
                Toggle("Bypass interlace", isOn: $model.bypassLenticular)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Sets an autosave name on the hosting window so its frame persists
/// across launches (S3).
private struct WindowAutosave: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.setFrameAutosaveName(name) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
