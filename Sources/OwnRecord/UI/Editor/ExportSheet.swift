import SwiftUI

struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export").font(.system(size: 17, weight: .semibold))
                Text(summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Picker("Format", selection: $model.exportOptions.format) {
                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if model.exportOptions.format == .gif {
                    Picker("Width", selection: $model.exportOptions.gifWidth) {
                        ForEach([480, 640, 800, 1080], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Picker("Frame rate", selection: $model.exportOptions.gifFrameRate) {
                        ForEach([10, 15, 24], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                } else if model.exportOptions.format == .imovie {
                    if model.hasCameraTrack {
                        Picker("Clips", selection: $model.exportOptions.iMovieClips) {
                            ForEach(IMovieClips.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    Picker("Resolution", selection: $model.exportOptions.resolution) {
                        ForEach(ExportResolution.allCases) { resolution in
                            Text(label(for: resolution)).tag(resolution)
                        }
                    }
                } else {
                    Picker("Codec", selection: $model.exportOptions.codec) {
                        ForEach(ExportCodec.allCases) { codec in
                            Text("\(codec.title) — \(codec.detail)").tag(codec)
                        }
                    }
                    Picker("Resolution", selection: $model.exportOptions.resolution) {
                        ForEach(ExportResolution.allCases) { resolution in
                            Text(label(for: resolution)).tag(resolution)
                        }
                    }
                }

                if model.recording.transcript != nil {
                    Toggle("Burn in subtitles", isOn: $model.recording.edit.subtitles.isEnabled)
                    if model.exportOptions.format != .gif, model.exportOptions.format != .imovie {
                        Toggle("Also save subtitles as .srt", isOn: $model.exportOptions.includeSubtitleFile)
                    }
                }

                if model.exportOptions.format == .imovie {
                    Text(iMovieNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.exportOptions.format == .imovie ? "Export for iMovie…" : "Export…") {
                    dismiss()
                    // Let the sheet close before the save panel opens.
                    DispatchQueue.main.async { model.chooseDestinationAndExport() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
    }

    private var outputSize: CGSize {
        size(for: model.exportOptions)
    }

    /// Only separate clips: they keep the screen's own shape, so show the screen clip's size.
    private var showsScreenClipSize: Bool {
        model.exportOptions.format == .imovie && model.hasCameraTrack && model.exportOptions.iMovieClips == .separate
    }

    private func size(for options: ExportOptions) -> CGSize {
        if showsScreenClipSize {
            return IMovieExporter.screenClipSize(source: model.sourceSize, edit: model.recording.edit, options: options)
        }
        return VideoExporter.renderSize(canvas: model.canvasSize, ratio: model.recording.edit.layout.aspect.ratio,
                                        options: options.movieOptions)
    }

    private var iMovieNote: String {
        let clips = model.hasCameraTrack ? model.exportOptions.iMovieClips : .finished
        let lead = "iMovie can't open project files, so your edit goes over as clips: cuts, blurs, hidden parts and muted parts are already applied."
        switch clips {
        case .finished:
            return lead + " The video looks exactly like the preview; add music, titles and transitions in iMovie."
        case .separate, .both:
            return lead + " The screen clip (with the sound) and the camera clip are the same length, so they line up: put the screen clip in your iMovie project, drag the camera clip above it, and choose Picture in Picture or Side by Side."
                + (clips == .both ? " The finished video is included too." : "")
        }
    }

    private var summary: String {
        "\(showsScreenClipSize ? "Screen " : "")\(Int(outputSize.width)) × \(Int(outputSize.height))  ·  \(TimeFormat.clock(model.editedDuration))  ·  \(model.recording.frameRate) fps"
    }

    private func label(for resolution: ExportResolution) -> String {
        var options = model.exportOptions
        options.resolution = resolution
        let size = size(for: options)
        return "\(resolution.title) (\(Int(size.width)) × \(Int(size.height)))"
    }
}
