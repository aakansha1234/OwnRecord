import SwiftUI

struct InspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(EditorModel.InspectorTab.allCases) { tab in
                    TabButton(tab: tab, selected: model.inspectorTab == tab) {
                        model.inspectorTab = tab
                    }
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch model.inspectorTab {
                    case .layout: LayoutInspector(model: model)
                    case .camera: CameraInspector(model: model)
                    case .blur: BlurInspector(model: model)
                    case .subtitles: SubtitlesInspector(model: model)
                    case .audio: AudioInspector(model: model)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabButton: View {
    let tab: EditorModel.InspectorTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol).font(.system(size: 15))
                Text(tab.title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared components

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(format(value))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

private struct EmptyInspector: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Layout

private struct LayoutInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        CropSection(model: model)

        InspectorSection("Aspect Ratio") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(AspectPreset.allCases) { preset in
                    let selected = model.recording.edit.layout.aspect == preset
                    Button {
                        model.recording.edit.layout.aspect = preset
                    } label: {
                        VStack(spacing: 4) {
                            AspectGlyph(ratio: preset.ratio ?? model.recording.edit.screenCrop(in: model.recordingSize).size.aspectRatio)
                                .frame(width: 26, height: 22)
                            Text(preset.title).font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : .clear))
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(preset.detail)
                }
            }
        }

        InspectorSection("Background") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(BackgroundPreset.allCases) { preset in
                    let selected = model.recording.edit.layout.background == preset
                    Button {
                        model.setBackground(preset)
                    } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LinearGradient(colors: preset.colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay {
                                if preset == .none {
                                    Image(systemName: "nosign").foregroundStyle(.white.opacity(0.6))
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.title)
                    .accessibilityLabel("\(preset.title) background")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }

        InspectorSection("Frame") {
            SliderRow(title: "Padding", value: $model.recording.edit.layout.padding, range: 0...0.2)
            SliderRow(title: "Corner radius", value: $model.recording.edit.layout.cornerRadius, range: 0...0.08)
            SliderRow(title: "Shadow", value: $model.recording.edit.layout.shadow, range: 0...1)
                .disabled(model.recording.edit.layout.padding < 0.001)
        }
    }
}

/// What part of the screen recording the video shows. The crop is chosen in the preview; while
/// choosing, its position and size can be typed in pixels.
private struct CropSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        InspectorSection("Crop") {
            if let pixels = model.cropDraftPixels {
                Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        PixelField(title: "X", value: pixels.minX) { model.setCropDraft(x: $0) }
                        PixelField(title: "Y", value: pixels.minY) { model.setCropDraft(y: $0) }
                    }
                    GridRow {
                        PixelField(title: "W", value: pixels.width) { model.setCropDraft(width: $0) }
                        PixelField(title: "H", value: pixels.height) { model.setCropDraft(height: $0) }
                    }
                }
                note("In pixels of the \(Int(model.recordingSize.width)) × \(Int(model.recordingSize.height)) recording. Drag the crop in the preview to move it, or its handles to resize it: ⇧ keeps the shape, ⌥ resizes around the center.")
            } else {
                let size = model.recordingSize
                let crop = model.recording.edit.crop?.pixelRect(in: size)
                HStack(spacing: 8) {
                    Image(systemName: "crop")
                        .foregroundStyle(crop == nil ? Color.secondary : Color.accentColor)
                    Text(crop.map { "\(Int($0.width)) × \(Int($0.height)) of \(Int(size.width)) × \(Int(size.height))" }
                         ?? "The whole screen")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if crop != nil {
                        Button("Reset") { model.resetCrop() }
                            .help("Show the whole screen recording again")
                    }
                    Button(crop == nil ? "Crop…" : "Edit…") { model.beginCropping() }
                        .help("Choose the part of the screen to show (\(EditorCommand.crop.shortcutLabel ?? ""))")
                        .disabled(model.loadState != .ready)
                }
                .controlSize(.small)
                note("Leave out the menu bar, the Dock or other windows. The background, camera and subtitles are laid out around what's left.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PixelField: View {
    let title: String
    let value: CGFloat
    let set: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)
            TextField(title, value: Binding(get: { Int(value) }, set: { set(CGFloat($0)) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .onSubmit { endTextEditing() }
        }
    }
}

private struct AspectGlyph: View {
    let ratio: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect.aspectFit(CGSize(width: ratio, height: 1), in: CGRect(origin: .zero, size: geometry.size))
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }
}

// MARK: - Camera

private struct CameraInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        if !model.hasCameraTrack {
            EmptyInspector(symbol: "video.slash", title: "No camera in this recording",
                           message: "Choose a camera in the recorder to add a speaker overlay to your next recording.")
        } else {
            let section = model.currentSection
            SwitchRow(title: model.hasMultipleSections ? "Show camera in this section" : "Show camera",
                      isOn: Binding(get: { section.showsCamera },
                                    set: { if $0 != section.showsCamera { model.toggleCamera() } }))
            if model.hasMultipleSections {
                SectionScopeNote(model: model)
            }

            Group {
                InspectorSection(model.hasMultipleSections ? "Shape in this section" : "Shape") {
                    HStack(spacing: 8) {
                        ForEach(CameraShape.allCases) { shape in
                            let selected = model.currentCameraPlacement.shape == shape
                            Button {
                                model.setCameraShape(shape)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: shape.symbol + (selected ? ".fill" : ""))
                                        .font(.system(size: 18))
                                    Text(shape.title).font(.system(size: 10, weight: .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04)))
                                .foregroundStyle(selected ? Color.accentColor : .primary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(shape.title) camera")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
                // A camera that fills the frame has no shape of its own.
                .disabled(!section.showsScreen)

                InspectorSection(model.hasMultipleSections ? "Position in this section" : "Position") {
                    if !section.showsScreen {
                        Text("The screen is hidden in this section, so the camera fills the frame.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Group {
                        HStack(alignment: .top, spacing: 12) {
                            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                                GridRow {
                                    CornerButton(position: .topLeft, model: model)
                                    CornerButton(position: .topRight, model: model)
                                }
                                GridRow {
                                    CornerButton(position: .bottomLeft, model: model)
                                    CornerButton(position: .bottomRight, model: model)
                                }
                            }
                            Text(model.currentCameraPlacement.position == .custom
                                 ? "Custom position. Drag it in the preview, or pick a corner."
                                 : "Or drag the camera anywhere in the preview. ⌥ + arrow keys move it between corners.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SliderRow(title: "Size", value: $model.cameraSize, range: 0.1...0.5)
                    }
                    .disabled(!section.showsScreen)
                    SliderRow(title: "Edge margin", value: $model.recording.edit.camera.margin, range: 0...0.1)
                        .disabled(model.currentCameraPlacement.position == .custom || !section.showsScreen)
                }

                InspectorSection(model.hasMultipleSections ? "Style · all sections" : "Style") {
                    SliderRow(title: "Border", value: $model.recording.edit.camera.borderWidth, range: 0...0.08)
                    ColorPicker("Border color", selection: Binding(
                        get: { model.recording.edit.camera.borderColor.color },
                        set: { model.recording.edit.camera.borderColor = RGBAColor($0) }), supportsOpacity: false)
                        .font(.system(size: 12))
                    Toggle("Drop shadow", isOn: $model.recording.edit.camera.shadow)
                        .font(.system(size: 12))
                    Toggle("Mirror", isOn: $model.recording.edit.camera.mirror)
                        .font(.system(size: 12))
                }
            }
            .disabled(!section.showsCamera)
            .opacity(section.showsCamera ? 1 : 0.5)
        }
    }
}

private struct CornerButton: View {
    let position: CameraPosition
    @Bindable var model: EditorModel

    var body: some View {
        let selected = model.currentCameraPlacement.position == position
        Button {
            model.setCameraCorner(position)
        } label: {
            ZStack(alignment: alignment) {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.secondary.opacity(0.5))
                Circle()
                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(width: 11, height: 11)
                    .padding(4)
            }
            .frame(width: 52, height: 34)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(position.title)
        .accessibilityLabel("Camera \(position.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var alignment: Alignment {
        switch position {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        default: .bottomTrailing
        }
    }
}

/// Explains that camera settings above apply to one section, with a way to apply them everywhere.
private struct SectionScopeNote: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(.secondary)
            Text("Visibility, shape, position and size apply to section \(model.currentSectionIndex + 1) of \(model.sections.count).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        if !model.cameraPlacementIsUniform {
            Button("Apply to All Sections") { model.applyCameraToAllSections() }
                .help("Use this section's camera shape, position and size in every section")
                .controlSize(.small)
        }
    }
}

/// Explains which subtitle style the inspector changes when sections have their own.
private struct SubtitleScopeNote: View {
    @Bindable var model: EditorModel
    let ownStyle: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(.secondary)
            Text(ownStyle
                 ? "Section \(model.currentSectionIndex + 1) of \(model.sections.count) has its own subtitle style."
                 : "This style applies to the sections without one of their own.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        Button("Apply to All Sections") { model.applySubtitleStyleToAllSections() }
            .help("Use this subtitle style in every section")
            .controlSize(.small)
    }
}

// MARK: - Blur

private struct BlurInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        let section = model.currentSection
        Text("Hide passwords, emails, notifications or customer data. Drag over an area in the preview to blur or pixelate it.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            ForEach(RedactionStyle.allCases) { style in
                let command: EditorCommand = style == .blur ? .blurArea : .pixelateArea
                Button {
                    model.beginRedaction(style)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: style.symbol).font(.system(size: 18))
                        Text("\(style.title) Area").font(.system(size: 10, weight: .medium))
                        Text(command.shortcutLabel ?? "")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(model.drawingRedaction == style
                                                                     ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04)))
                    .foregroundStyle(model.drawingRedaction == style ? Color.accentColor : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canRedact || model.loadState != .ready)
                .help("\(style.title) an area (\(command.shortcutLabel ?? ""))")
            }
        }

        InspectorSection(model.hasMultipleSections ? "In this section" : "Areas") {
            if section.isDeleted {
                note("This section is deleted.")
            } else if !section.showsScreen {
                note("The screen is hidden in this section, so there's nothing to blur.")
            } else if model.currentRedactions.isEmpty {
                note(model.hasMultipleSections
                     ? "Nothing is blurred in section \(model.currentSectionIndex + 1) of \(model.sections.count). Areas apply to the section they're added in; use Apply to All Sections to hide something for the whole video."
                     : "Nothing is blurred yet. Areas you add stay in place for the whole video, and follow along when you split it.")
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(model.currentRedactions.enumerated()), id: \.element.id) { index, redaction in
                        RedactionRow(model: model, redaction: redaction, number: index + 1)
                    }
                }
                Text("Drag an area to move it, or its corners to resize. ⌫ deletes the selected area.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RedactionRow: View {
    @Bindable var model: EditorModel
    let redaction: Redaction
    let number: Int

    var body: some View {
        let selected = model.selectedRedaction?.id == redaction.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: redaction.style.symbol)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                Text("\(redaction.style.noun) \(number)")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("Style", selection: Binding(get: { redaction.style },
                                                   set: { model.setRedactionStyle($0, for: redaction.id) })) {
                    ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Button {
                    model.deleteRedaction(redaction.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this area")
                .accessibilityLabel("Delete \(redaction.style.noun) \(number)")
            }
            if model.hasMultipleSections, !model.redactionIsInAllSections(redaction) {
                Button("Apply to All Sections") { model.applyRedactionToAllSections(redaction.id) }
                    .controlSize(.small)
                    .help("Hide this area in every section of the video")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectRedaction(redaction.id) }
    }
}

// MARK: - Subtitles

private struct SubtitlesInspector: View {
    @Bindable var model: EditorModel
    @State private var locales: [TranscriptionEngine.LocaleOption] = []

    var body: some View {
        Group {
            if model.recording.transcript == nil {
                generator
            } else {
                styleSection
                transcriptSection
            }
        }
        .task { locales = TranscriptionEngine.supportedLocales }
    }

    @ViewBuilder
    private var generator: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Generate subtitles")
                .font(.system(size: 14, weight: .semibold))
            Text("Transcribe the recording's audio and add styled, editable subtitles. Export them as SRT/VTT or burn them into the video.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Language", selection: $model.transcriptionLocale) {
                ForEach(locales) { Text($0.name).tag($0.id) }
                if !locales.contains(where: { $0.id == model.transcriptionLocale }) {
                    Text(model.transcriptionLocale).tag(model.transcriptionLocale)
                }
            }
            .font(.system(size: 12))

            let onDevice = TranscriptionEngine.supportsOnDevice(localeIdentifier: model.transcriptionLocale)
            Label(onDevice ? "Runs privately on this Mac" : "Uses Apple's speech servers for this language",
                  systemImage: onDevice ? "lock.shield" : "cloud")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            switch model.transcription {
            case .running(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    HStack {
                        Text("Transcribing… \(Int(progress * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancelTranscription() }
                            .controlSize(.small)
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                generateButton
            case .idle:
                generateButton
            }
        }
    }

    private var generateButton: some View {
        Button {
            model.generateTranscript()
        } label: {
            Label("Generate Subtitles", systemImage: "waveform")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.recording.hasAudio)
        .help(model.recording.hasAudio ? "" : "This recording has no audio.")
    }

    @ViewBuilder
    private var styleSection: some View {
        SwitchRow(title: "Show subtitles in video", isOn: $model.recording.edit.subtitles.isEnabled)

        let ownStyle = model.currentSection.subtitles != nil
        InspectorSection(ownStyle ? "Style in this section" : "Style") {
            if model.hasSectionSubtitleStyles {
                SubtitleScopeNote(model: model, ownStyle: ownStyle)
            }
            Picker("Position", selection: $model.currentSubtitleStyle.position) {
                ForEach(SubtitlePosition.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            SliderRow(title: "Size", value: $model.currentSubtitleStyle.fontScale, range: 0.025...0.09,
                      format: { "\(Int(($0 / 0.048 * 100).rounded()))%" })
            Toggle("Bold", isOn: $model.currentSubtitleStyle.bold)
                .font(.system(size: 12))
            ColorPicker("Text color", selection: Binding(
                get: { model.currentSubtitleStyle.textColor.color },
                set: { model.currentSubtitleStyle.textColor = RGBAColor($0) }), supportsOpacity: false)
                .font(.system(size: 12))
            ColorPicker("Background", selection: Binding(
                get: { model.currentSubtitleStyle.backgroundColor.color },
                set: { model.currentSubtitleStyle.backgroundColor = RGBAColor($0) }), supportsOpacity: true)
                .font(.system(size: 12))
            SliderRow(title: "Outline", value: $model.currentSubtitleStyle.outlineWidth, range: 0...0.16,
                      format: { $0 < 0.005 ? "Off" : "\(Int(($0 * 100).rounded()))%" })
            ColorPicker("Outline color", selection: Binding(
                get: { model.currentSubtitleStyle.outlineColor.color },
                set: { model.currentSubtitleStyle.outlineColor = RGBAColor($0) }), supportsOpacity: false)
                .font(.system(size: 12))
                .disabled(model.currentSubtitleStyle.outlineWidth < 0.005)
            Toggle("Shadow", isOn: $model.currentSubtitleStyle.shadow)
                .font(.system(size: 12))
                .disabled(model.currentSubtitleStyle.backgroundColor.alpha > 0.01)
                .help("A soft shadow behind the text when there's no background")
        }
        .disabled(!model.recording.edit.subtitles.isEnabled)
        .opacity(model.recording.edit.subtitles.isEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var transcriptSection: some View {
        InspectorSection("Transcript") {
            HStack {
                Menu {
                    ForEach(SubtitleFileFormat.allCases) { format in
                        Button(format.title) { model.exportSubtitles(format: format) }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                Button {
                    model.copyTranscript()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Spacer()
                Menu {
                    Button("Regenerate") {
                        model.deleteTranscript()
                        model.generateTranscript()
                    }
                    Button("Delete Transcript", role: .destructive) { model.deleteTranscript() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.small)

            Text("Click a time to jump there. Edit text directly.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.recording.transcript?.cues ?? []) { cue in
                        CueRow(cue: cue, model: model, isCurrent: cue.id == model.currentCueID)
                            .id(cue.id)
                    }
                }
                .onChange(of: model.currentCueID) { _, id in
                    if model.isPlaying, let id {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }
}

private struct CueRow: View {
    let cue: SubtitleCue
    @Bindable var model: EditorModel
    let isCurrent: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(TimeFormat.precise(cue.start)) {
                model.seek(to: cue.start)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            .frame(width: 46, alignment: .leading)

            TextField("", text: Binding(get: { cue.text }, set: { model.updateCue(cue.id, text: $0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .strikethrough(model.isCut(cue), color: .secondary)
                .foregroundStyle(model.isCut(cue) ? .secondary : .primary)
                .help(model.isCut(cue) ? "This part is cut from the video" : "")

            Button {
                model.deleteCue(cue.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(hovering ? 1 : 0)
            .help("Delete this subtitle")
            .accessibilityLabel("Delete subtitle")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color.accentColor.opacity(0.12) : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .onHover { hovering = $0 }
    }
}

// MARK: - Audio

private struct AudioInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        if !model.recording.hasAudio {
            EmptyInspector(symbol: "speaker.slash", title: "No audio in this recording",
                           message: "Turn on a microphone or system audio in the recorder to capture sound.")
        } else {
            InspectorSection("Volume") {
                if model.recording.hasMicrophone {
                    VolumeRow(title: "Microphone", symbol: "mic", value: $model.recording.edit.audio.microphoneVolume)
                }
                if model.recording.hasSystemAudio {
                    VolumeRow(title: "System audio", symbol: "speaker.wave.2", value: $model.recording.edit.audio.systemVolume)
                }
            }
            Text("Microphone and system audio are recorded as separate tracks, so you can balance them after recording.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VolumeRow: View {
    let title: String
    let symbol: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Button {
                value = value > 0 ? 0 : 1
            } label: {
                Image(systemName: value > 0 ? symbol : "speaker.slash")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(value > 0 ? "Mute" : "Unmute")
            .accessibilityLabel(value > 0 ? "Mute \(title)" : "Unmute \(title)")
            SliderRow(title: title, value: $value, range: 0...1)
        }
    }
}
