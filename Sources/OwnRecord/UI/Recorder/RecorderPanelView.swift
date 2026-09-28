import SwiftUI

/// Compact floating panel: choose screen/window/area, camera, microphone and system audio.
struct RecorderPanelView: View {
    @Bindable var recorder: RecorderModel
    let controller: RecordingController
    @Bindable var preferences: Preferences

    var body: some View {
        VStack(spacing: 0) {
            header
            modePicker
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            Divider()
            sourceSection
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            Divider()
            devicesSection
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            footer
                .padding(14)
        }
        .frame(width: 420)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
            Text("New Recording")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            optionsMenu
            Button {
                AppModel.shared.closeRecorder()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Countdown", selection: $preferences.countdown) {
                Text("No Countdown").tag(0)
                Text("3 Seconds").tag(3)
                Text("5 Seconds").tag(5)
                Text("10 Seconds").tag(10)
            }
            Picker("Frame Rate", selection: $preferences.frameRate) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Divider()
            Toggle("Show Cursor", isOn: $preferences.showCursor)
            Toggle("Highlight Clicks", isOn: $preferences.highlightClicks)
            Toggle("Hide Desktop Icons", isOn: $preferences.hideDesktopIcons)
            Divider()
            Button("Settings…") { AppModel.shared.windows.showSettings() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recording options")
        .accessibilityLabel("Recording Options")
    }

    // MARK: Mode

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(CaptureMode.allCases) { mode in
                let selected = recorder.mode == mode
                Button {
                    recorder.mode = mode
                    if mode == .area, recorder.area == nil { AppModel.shared.selectArea() }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .frame(height: 24)
                        Text(mode.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Source

    @ViewBuilder
    private var sourceSection: some View {
        if let error = recorder.sourceError {
            PermissionHint(message: error)
        } else {
            switch recorder.mode {
            case .display: displaySource
            case .window: windowSource
            case .area: areaSource
            }
        }
    }

    private var displaySource: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Display")
            if recorder.displays.count > 1 {
                ForEach(recorder.displays) { display in
                    SelectableRow(selected: recorder.selectedDisplayID == display.id) {
                        recorder.selectedDisplayID = display.id
                    } content: {
                        Image(systemName: "display")
                        Text(display.name)
                        Spacer()
                        Text("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } else if let display = recorder.selectedDisplay {
                HStack {
                    Image(systemName: "display")
                    Text(display.name)
                    Spacer()
                    Text("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 12))
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var windowSource: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Window")
                Spacer()
                Button {
                    Task { await recorder.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh windows")
            }
            if recorder.windows.isEmpty {
                HStack {
                    if recorder.isLoadingSources { ProgressView().controlSize(.small) }
                    Text(recorder.isLoadingSources ? "Finding windows…" : "No windows available")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(recorder.windows) { window in
                            WindowTile(window: window, thumbnail: recorder.windowThumbnails[window.id],
                                       selected: recorder.selectedWindowID == window.id) {
                                recorder.selectedWindowID = window.id
                            }
                        }
                    }
                }
                .frame(height: 250)
            }
        }
    }

    private var areaSource: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Area")
            HStack(spacing: 10) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                if let area = recorder.area {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(area.width)) × \(Int(area.height)) pt")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                        Text(NSScreen.screen(withDisplayID: area.displayID)?.localizedName ?? "Display")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No area selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(recorder.area == nil ? "Select Area…" : "Change…") {
                    AppModel.shared.selectArea()
                }
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        VStack(spacing: 6) {
            DeviceRow(symbol: recorder.cameraID == nil ? "video.slash" : "video", title: "Camera") {
                Picker("Camera", selection: $recorder.cameraID) {
                    Text("No Camera").tag(String?.none)
                    if !recorder.cameras.isEmpty { Divider() }
                    ForEach(recorder.cameras) { camera in
                        Text(camera.name).tag(String?.some(camera.id))
                    }
                }
            }
            if recorder.cameraID != nil {
                HStack(spacing: 8) {
                    Spacer().frame(width: 28)
                    Picker("Shape", selection: $preferences.cameraStyle.shape) {
                        ForEach(CameraShape.allCases) { shape in
                            Image(systemName: shape.symbol).help(shape.title).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                    Picker("Size", selection: $preferences.bubbleSize) {
                        ForEach(BubbleSize.allCases) { size in
                            Text(size.title.prefix(1)).help(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 100)
                    Spacer()
                }
                .padding(.bottom, 4)
            }
            DeviceRow(symbol: recorder.microphoneID == nil ? "mic.slash" : "mic", title: "Microphone") {
                HStack(spacing: 8) {
                    Picker("Microphone", selection: $recorder.microphoneID) {
                        Text("No Microphone").tag(String?.none)
                        if !recorder.microphones.isEmpty { Divider() }
                        ForEach(recorder.microphones) { microphone in
                            Text(microphone.name).tag(String?.some(microphone.id))
                        }
                    }
                    if recorder.microphoneID != nil {
                        LevelMeter(level: controller.microphoneLevel, bars: 8)
                            .frame(width: 40, height: 14)
                    }
                }
            }
            DeviceRow(symbol: recorder.captureSystemAudio ? "speaker.wave.2" : "speaker.slash", title: "System Audio") {
                HStack {
                    Spacer()
                    Toggle("System Audio", isOn: $recorder.captureSystemAudio)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
        }
        .labelsHidden()
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                if recorder.mode == .area, recorder.area == nil {
                    AppModel.shared.selectArea(thenStart: true)
                } else {
                    controller.start()
                }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(.white).frame(width: 10, height: 10)
                    Text(recorder.mode == .area && recorder.area == nil ? "Select Area & Record" : "Start Recording")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(startEnabled ? Color.red : Color.gray.opacity(0.4)))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!startEnabled)
            .keyboardShortcut(.defaultAction)

            HStack(spacing: 4) {
                Text("Start or stop anytime with")
                Text(HotKeyCenter.toggleRecording.display)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)))
                if preferences.countdown > 0 {
                    Text("· \(preferences.countdown)s countdown")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var startEnabled: Bool {
        controller.phase == .idle && (recorder.mode == .area || recorder.canStart) && recorder.sourceError == nil
    }
}

// MARK: - Components

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

private struct DeviceRow<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 88, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 28)
    }
}

private struct SelectableRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct WindowTile: View {
    let window: WindowOption
    let thumbnail: NSImage?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.06))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 70)
                .overlay(alignment: .bottomLeading) {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                            .padding(4)
                    }
                }
                Text(window.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(window.appName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.05) : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(window.appName) — \(window.displayTitle)")
    }

    private var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: window.processID)?.icon
    }
}

private struct PermissionHint: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording permission needed", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") {
                    AppModel.shared.permissions.openSystemSettings(for: .screen)
                }
                Button("Try Again") {
                    Task { await AppModel.shared.recorder.refreshSources() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
