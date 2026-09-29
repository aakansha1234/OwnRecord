import AppKit
import SwiftUI

/// Script on top, controls below. Edit the script while it's not scrolling.
struct TeleprompterView: View {
    @Bindable var teleprompter: Teleprompter
    @Bindable var preferences: Preferences

    /// Where the line being read sits, as a fraction of the text area's height.
    static let readingLine = 0.32

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TeleprompterText(teleprompter: teleprompter, text: $preferences.speakerNotes,
                                 fontSize: preferences.teleprompterFontSize, speed: preferences.teleprompterSpeed,
                                 isScrolling: teleprompter.isScrolling)
                    // Lines already read fade out toward the top.
                    .mask(LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                                 .init(color: .black, location: Self.readingLine),
                                                 .init(color: .black, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                GeometryReader { geometry in
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                        .position(x: 9, y: geometry.size.height * Self.readingLine + preferences.teleprompterFontSize * 0.62)
                }
                .allowsHitTesting(false)
                if preferences.speakerNotes.isEmpty {
                    Text("Write or paste your script here. It scrolls while you record, and never appears in the video.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 26)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            Divider()
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .environment(\.colorScheme, .dark)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button {
                teleprompter.toggleScrolling()
            } label: {
                Label(teleprompter.isScrolling ? "Pause" : "Scroll",
                      systemImage: teleprompter.isScrolling ? "pause.fill" : "play.fill")
                    .frame(minWidth: 62)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("\(teleprompter.isScrolling ? "Pause" : "Start") scrolling (⌘↩, or \(HotKeyCenter.toggleTeleprompter.display) from any app)")

            iconButton("arrow.up.to.line", help: "Back to the top") { teleprompter.restart() }

            Divider().frame(height: 16).padding(.horizontal, 4)

            iconButton("tortoise", help: "Slower (←)") { teleprompter.changeSpeed(by: -1) }
                .disabled(preferences.teleprompterSpeed <= Teleprompter.speedRange.lowerBound)
            Text("Speed \(Int(preferences.teleprompterSpeed))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            iconButton("hare", help: "Faster (→)") { teleprompter.changeSpeed(by: 1) }
                .disabled(preferences.teleprompterSpeed >= Teleprompter.speedRange.upperBound)

            Divider().frame(height: 16).padding(.horizontal, 4)

            iconButton("textformat.size.smaller", help: "Smaller text") { teleprompter.changeFontSize(by: -4) }
            iconButton("textformat.size.larger", help: "Larger text") { teleprompter.changeFontSize(by: 4) }

            Spacer(minLength: 8)

            Label("Not recorded", systemImage: "eye.slash")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("The teleprompter never appears in your recordings")
            Menu {
                Toggle("Scroll When Recording Starts", isOn: $preferences.teleprompterFollowsRecording)
                Divider()
                Button("Clear Script") { preferences.speakerNotes = "" }
                    .disabled(preferences.speakerNotes.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Teleprompter options")
        }
        .controlSize(.small)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The script in an AppKit text view, which scrolls smoothly at any speed and is editable while paused.
struct TeleprompterText: NSViewRepresentable {
    let teleprompter: Teleprompter
    @Binding var text: String
    let fontSize: Double
    let speed: Double
    let isScrolling: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(teleprompter: teleprompter)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 lays out the whole script, so lines show in the bottom scroll margin too
        // (TextKit 2 only lays out what's above the content inset).
        let textView = TeleprompterTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Teleprompter script")
        textView.string = text
        textView.delegate = context.coordinator
        textView.teleprompter = teleprompter

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.attach(scrollView: scrollView, textView: textView)
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.speed = speed
        coordinator.apply(fontSize: fontSize)
        if let textView = coordinator.textView, textView.string != text {
            textView.string = text
            coordinator.applyStyle()
        }
        coordinator.setScrolling(isScrolling)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, TeleprompterScroller {
        let teleprompter: Teleprompter
        var text: Binding<String>?
        var speed = 5.0
        private(set) weak var textView: TeleprompterTextView?
        private weak var scrollView: NSScrollView?
        private var fontSize = 0.0
        private static let lineHeightMultiple: CGFloat = 1.12
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval?
        /// Where scrolling has got to, kept unrounded so slow speeds still move.
        private var position: CGFloat = 0

        init(teleprompter: Teleprompter) {
            self.teleprompter = teleprompter
            super.init()
            teleprompter.scroller = self
        }

        func attach(scrollView: NSScrollView, textView: TeleprompterTextView) {
            self.scrollView = scrollView
            self.textView = textView
            NotificationCenter.default.addObserver(self, selector: #selector(sizeChanged), name: NSView.frameDidChangeNotification,
                                                   object: scrollView.contentView)
            let link = textView.displayLink(target: self, selector: #selector(tick(_:)))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        /// The display link keeps its target alive, so it's stopped when the view goes away.
        func detach() {
            displayLink?.invalidate()
            displayLink = nil
        }

        func apply(fontSize: Double) {
            guard fontSize != self.fontSize else { return }
            self.fontSize = fontSize
            applyStyle()
        }

        func applyStyle() {
            guard let textView else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = Self.lineHeightMultiple
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
            textView.typingAttributes = attributes
            textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
            sizeChanged()
        }

        /// The first line starts at the reading line, and the last can scroll up to it.
        @objc func sizeChanged() {
            guard let scrollView, let textView else { return }
            // Autoresizing can shift the text view when the scroll view first grows from zero size.
            if textView.frame.origin != .zero {
                textView.setFrameOrigin(.zero)
                scroll(toOffset: position)
            }
            let height = scrollView.frame.height
            let inset = max(8, height * TeleprompterView.readingLine)
            // The inset pads the top and the bottom equally; scrolling past the end makes up the rest,
            // so the last line can come up to the reading line.
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let lineHeight = (font.ascender - font.descender + font.leading) * Self.lineHeightMultiple
            textView.textContainerInset = NSSize(width: 22, height: inset)
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: max(0, height - 2 * inset - lineHeight), right: 0)
        }

        /// The furthest the script scrolls: its last line at the reading line.
        private var maxOffset: CGFloat {
            guard let scrollView else { return 0 }
            let clip = scrollView.contentView
            return max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height + scrollView.contentInsets.bottom)
        }

        var offset: CGFloat {
            scrollView?.contentView.bounds.origin.y ?? 0
        }

        func scroll(toOffset offset: CGFloat) {
            guard let scrollView else { return }
            position = offset.clamped(to: 0...maxOffset)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: position))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func setScrolling(_ scrolling: Bool) {
            guard let textView, let displayLink else { return }
            textView.isEditable = !scrolling
            textView.isSelectable = !scrolling
            if scrolling {
                // Keeps Space and the arrow keys working (see TeleprompterTextView) when the panel is key.
                textView.window?.makeFirstResponder(textView)
            }
            if scrolling, displayLink.isPaused {
                position = scrollView?.contentView.bounds.origin.y ?? 0
                lastTimestamp = nil
            }
            displayLink.isPaused = !scrolling
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let scrollView, teleprompter.isScrolling else { return }
            let elapsed = lastTimestamp.map { link.timestamp - $0 } ?? 0
            lastTimestamp = link.timestamp
            let clip = scrollView.contentView
            if abs(clip.bounds.origin.y - position) > 2 {
                // Scrolled by hand meanwhile: carry on from there.
                position = clip.bounds.origin.y
            }
            let maxY = maxOffset
            position = min(maxY, position + pointsPerSecond * CGFloat(min(elapsed, 0.1)))
            clip.scroll(to: NSPoint(x: 0, y: position))
            scrollView.reflectScrolledClipView(clip)
            if position >= maxY - 0.5 {
                teleprompter.reachedEnd()
            }
        }

        /// Speed 5 moves one line about every 2.8 seconds, a relaxed speaking pace.
        private var pointsPerSecond: CGFloat {
            CGFloat(fontSize * 1.3 * speed / 14)
        }

        func prepareToScroll() {
            if offset >= maxOffset - 0.5 { scrollToTop() }
        }

        func scrollToTop() {
            scroll(toOffset: 0)
        }

        /// Moves by whole lines (↑ ↓ while scrolling).
        func nudge(lines: Int) {
            scroll(toOffset: offset + CGFloat(lines) * CGFloat(fontSize * 1.3))
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text?.wrappedValue = textView.string
        }
    }
}

/// Keys while scrolling: Space pauses, ← → change speed, ↑ ↓ move a line.
final class TeleprompterTextView: NSTextView {
    weak var teleprompter: Teleprompter?

    override func keyDown(with event: NSEvent) {
        guard !isEditable, let teleprompter,
              let coordinator = delegate as? TeleprompterText.Coordinator else {
            super.keyDown(with: event)
            return
        }
        switch Int(event.keyCode) {
        case 49: teleprompter.toggleScrolling() // Space
        case 123: teleprompter.changeSpeed(by: -1) // ←
        case 124: teleprompter.changeSpeed(by: 1) // →
        case 125: coordinator.nudge(lines: 1) // ↓
        case 126: coordinator.nudge(lines: -1) // ↑
        default: super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
