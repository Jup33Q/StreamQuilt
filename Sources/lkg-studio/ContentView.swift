import SwiftUI

struct ContentView: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptSection
            renderConfigSection
            previewSection
            statusSection
            transportSection
            togglesSection
        }
        .padding(16)
        .frame(minWidth: 480)
        .background(WindowAutosave(name: "LKGStudioMainWindow"))
    }

    // MARK: - Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                TextField("Prompt", text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit { model.applyPrompt() }
                Button("Apply") { model.applyPrompt() }
            }
            if !model.recentPrompts.isEmpty {
                Menu("Recent prompts") {
                    ForEach(model.recentPrompts, id: \.self) { p in
                        Button(p) {
                            model.prompt = p
                            model.applyPrompt()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Render configuration (Apply respawns the worker pool)

    private var renderConfigSection: some View {
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
            HStack {
                Picker("Audio", selection: $model.audioSource) {
                    ForEach(AudioSourceKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .frame(width: 140)
                Toggle("Lyric prompts", isOn: $model.lyricPrompt)
                Spacer()
                if model.renderConfigDirty {
                    Button("Apply render settings") { model.applyRenderConfig() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.pipelineLoading)
                }
            }
            HStack {
                Text("Raw mix")
                Slider(value: $model.altMix, in: 0...1)
                    .frame(width: 120)
                Text("Beat glow")
                Slider(value: $model.beatGlow, in: 0...1)
                    .frame(width: 120)
            }
            .foregroundStyle(.secondary)
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

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%.0f FPS · %.1f tiles/s · tile %.2f Hz · workers %d/%d",
                        model.fps, model.tilesPerSec, model.tileHz,
                        model.workersReady, model.workers))
                .font(.system(.body, design: .monospaced))
            if !model.lastError.isEmpty {
                Text(model.lastError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    // MARK: - Transport / now playing

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            }
        }
    }

    // MARK: - Toggles

    private var togglesSection: some View {
        HStack {
            Toggle("Device fullscreen", isOn: $model.deviceFullscreen)
                .disabled(!model.deviceAvailable && !model.deviceFullscreen)
            Toggle("Calibration test", isOn: $model.testPattern)
            Toggle("Bypass interlace", isOn: $model.bypassLenticular)
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
