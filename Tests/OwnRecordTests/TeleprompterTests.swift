import AppKit
@testable import OwnRecord
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct TeleprompterTests {
    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

    @Test func scrollsUntilTheEndAndRestarts() async throws {
        let preferences = Preferences.shared
        let saved = (preferences.speakerNotes, preferences.teleprompterSpeed, preferences.teleprompterFontSize)
        defer {
            (preferences.speakerNotes, preferences.teleprompterSpeed, preferences.teleprompterFontSize) = saved
        }
        preferences.speakerNotes = (1...12).map { "Line \($0) of the script." }.joined(separator: "\n")
        preferences.teleprompterSpeed = 10
        preferences.teleprompterFontSize = 40

        _ = NSApplication.shared
        let teleprompter = Teleprompter(preferences: preferences)
        let hosting = NSHostingView(rootView: TeleprompterView(teleprompter: teleprompter, preferences: preferences))
        hosting.frame = CGRect(x: 0, y: 0, width: 480, height: 240)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let scrollView = try #require(findScrollView(in: hosting))
        #expect(scrollView.contentView.bounds.origin.y == 0)

        // Speed 10 at 40 pt moves about 37 points a second.
        teleprompter.scroll()
        #expect(teleprompter.isScrolling)
        try await Task.sleep(for: .seconds(1))
        let moved = scrollView.contentView.bounds.origin.y
        #expect(moved > 15 && moved < 80, "moved \(moved)")
        teleprompter.pause()
        try await Task.sleep(for: .milliseconds(200))
        let paused = scrollView.contentView.bounds.origin.y
        try await Task.sleep(for: .milliseconds(300))
        #expect(scrollView.contentView.bounds.origin.y == paused)

        // At the end it stops by itself, with the last line at the reading line; scrolling again
        // starts from the top.
        let clip = scrollView.contentView
        let textView = try #require(scrollView.documentView as? NSTextView)
        let end = textView.frame.height - clip.bounds.height + scrollView.contentInsets.bottom
        teleprompter.scroller?.scroll(toOffset: end - 5)
        teleprompter.scroll()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!teleprompter.isScrolling)
        let layout = try #require(textView.layoutManager)
        let lastLine = layout.lineFragmentRect(forGlyphAt: max(0, layout.numberOfGlyphs - 1), effectiveRange: nil)
        let lastLineTop = lastLine.minY + textView.textContainerInset.height - clip.bounds.origin.y
        let readingLine = clip.bounds.height * TeleprompterView.readingLine
        #expect(abs(lastLineTop - readingLine) < 8, "last line at \(lastLineTop), reading line at \(readingLine)")
        teleprompter.scroll()
        #expect(scrollView.contentView.bounds.origin.y < 1)
        teleprompter.pause()
    }
}
