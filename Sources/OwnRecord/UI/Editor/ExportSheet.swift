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
                    if model.exportOptions.format != .gif {
                        Toggle("Also save subtitles as .srt", isOn: $model.exportOptions.includeSubtitleFile)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
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
        VideoExporter.renderSize(canvas: model.canvasSize, ratio: model.recording.edit.layout.aspect.ratio,
                                 options: model.exportOptions)
    }

    private var summary: String {
        "\(Int(outputSize.width)) × \(Int(outputSize.height))  ·  \(TimeFormat.clock(model.recording.trimmedDuration))  ·  \(model.recording.frameRate) fps"
    }

    private func label(for resolution: ExportResolution) -> String {
        var options = model.exportOptions
        options.resolution = resolution
        let size = VideoExporter.renderSize(canvas: model.canvasSize, ratio: model.recording.edit.layout.aspect.ratio,
                                            options: options)
        return "\(resolution.title) (\(Int(size.width)) × \(Int(size.height)))"
    }
}
