import AppKit
import Observation
import SwiftUI

/// A floating teleprompter for your script or speaker notes. It's never part of a recording.
/// It scrolls by itself, and can start and pause along with the recording.
@MainActor @Observable
final class Teleprompter: NSObject, NSWindowDelegate {
    private(set) var isVisible = false
    private(set) var isScrolling = false

    @ObservationIgnored let preferences: Preferences
    /// The text view that does the scrolling (set by `TeleprompterText`).
    @ObservationIgnored weak var scroller: TeleprompterScroller?
    @ObservationIgnored private var panel: NSPanel?
    /// Scrolling was paused by pausing the recording, so resuming it resumes scrolling.
    @ObservationIgnored private var resumesWithRecording = false
    @ObservationIgnored private var lastPhase: RecordingController.Phase = .idle
    /// Where the script was when the current take started, to go back to for the next take.
    @ObservationIgnored private var takeStart: CGFloat?

    static let speedRange = 1.0...10.0
    static let fontSizeRange = 16.0...72.0

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
    }

    /// The panel's window, created up front so its window ID is known before any recording starts.
    var windowID: CGWindowID {
        CGWindowID(makePanelIfNeeded().windowNumber)
    }

    var hasScript: Bool {
        !preferences.speakerNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Showing

    func show() {
        let panel = makePanelIfNeeded()
        if !isVisible {
            panel.orderFrontRegardless()
            isVisible = true
        }
    }

    func hide() {
        pause()
        panel?.orderOut(nil)
        isVisible = false
    }

    func toggleVisibility() {
        isVisible ? hide() : show()
    }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    // MARK: Scrolling

    func toggleScrolling() {
        isScrolling ? pause() : start()
    }

    func start() {
        show()
        guard hasScript else {
            NSSound.beep()
            panel?.makeKey()
            return
        }
        scroll()
    }

    /// Starts scrolling wherever the script is shown.
    func scroll() {
        guard hasScript else { return }
        resumesWithRecording = false
        scroller?.prepareToScroll()
        isScrolling = true
    }

    func pause() {
        resumesWithRecording = false
        isScrolling = false
    }

    /// Back to the beginning of the script.
    func restart() {
        scroller?.scrollToTop()
    }

    /// Called by the scroller when the end of the script is reached.
    func reachedEnd() {
        isScrolling = false
    }

    func changeSpeed(by step: Double) {
        preferences.teleprompterSpeed = (preferences.teleprompterSpeed + step).clamped(to: Self.speedRange)
    }

    func changeFontSize(by step: Double) {
        preferences.teleprompterFontSize = (preferences.teleprompterFontSize + step).clamped(to: Self.fontSizeRange)
    }

    // MARK: Recording

    /// Starts scrolling when a recording starts, and pauses and resumes with it.
    func follow(_ recording: RecordingController) {
        lastPhase = recording.phase
        observeContinuously({ _ = recording.phase }, onChange: { [weak self, weak recording] in
            guard let self, let recording else { return }
            self.recordingPhaseChanged(to: recording.phase)
        })
    }

    private func recordingPhaseChanged(to phase: RecordingController.Phase) {
        let previous = lastPhase
        lastPhase = phase
        guard preferences.teleprompterFollowsRecording, isVisible else { return }
        switch (previous, phase) {
        case (.paused, .recording):
            if resumesWithRecording { start() }
        case (_, .recording):
            takeStart = scroller?.offset
            if hasScript { start() }
        case (.recording, .paused):
            if isScrolling {
                isScrolling = false
                resumesWithRecording = true
            }
        case (_, .finishing), (_, .idle):
            pause()
            // Ready for the next take (or a restarted one) from the same place.
            if let takeStart {
                scroller?.scroll(toOffset: takeStart)
                self.takeStart = nil
            }
        default:
            break
        }
    }

    // MARK: Panel

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 250),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Teleprompter"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 420, height: 160)
        panel.appearance = NSAppearance(named: .darkAqua)
        // Recordings leave it out through their content filter; this keeps other capture tools out too.
        panel.sharingType = .none
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: TeleprompterView(teleprompter: self, preferences: preferences))
        if !panel.setFrameUsingName("OwnRecord.Teleprompter"), let screen = NSScreen.withMouse ?? NSScreen.main {
            // Just under the menu bar, close to the built-in camera, so your eyes stay near it.
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - 8))
        }
        panel.setFrameAutosaveName("OwnRecord.Teleprompter")
        self.panel = panel
        return panel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

/// What the teleprompter asks of its text view.
@MainActor
protocol TeleprompterScroller: AnyObject {
    /// How far the script is scrolled, in points.
    var offset: CGFloat { get }
    /// Called before scrolling starts; jumps back to the top if the end was reached.
    func prepareToScroll()
    func scrollToTop()
    func scroll(toOffset offset: CGFloat)
}
