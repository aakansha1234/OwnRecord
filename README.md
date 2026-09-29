# OwnRecord

A native macOS screen recorder with a speaker camera overlay, automatic subtitles and a
non-destructive editor. Built with SwiftUI, AppKit, ScreenCaptureKit, AVFoundation, Core Image
and the Speech framework. Requires macOS 15 or later.

## Features

**Capture**
- Record the **entire screen**, a **single window** (thumbnail picker), or a **custom area**
  (draw/move/resize, aspect-ratio locks, size presets, double-click or ⏎ to record).
- **Microphone** (with live level meter) and **system audio**, recorded as separate tracks.
- 30/60 fps, HEVC master files at native Retina resolution.
- Countdown (off/3/5/10 s), **pause/resume**, restart, discard (with confirm), stop.
- Show/hide cursor, **highlight clicks**, **hide desktop icons**.
- OwnRecord's own windows (recorder, camera bubble, controls) are never captured.
- Menu bar item with live timer, and global shortcuts that work from any app:
  **⌥⇧⌘R** start/stop, **⌥⇧⌘P** pause/resume.
- Crash-tolerant recordings (fragmented movie files).

**Camera overlay**
- A live, draggable camera bubble while recording (circle, rounded square or 16:9;
  S/M/L; mirror). Where you leave it is where it appears in the video.
- The camera is recorded as its **own file**, so shape, size, position (corners or anywhere
  by dragging it in the preview, with corner snapping), border, shadow and mirroring can all be
  changed after recording, or hidden entirely.

**Subtitles**
- Transcription with Apple's Speech framework, **on-device** by default (private, offline).
  It covers every audible track (your mic and system audio), normalizes quiet audio, and splits
  long recordings at quiet moments so words are never cut.
- Editable transcript (click a line to jump there), subtitle lane on the timeline.
- Styled, burned-in subtitles (position, size, weight, text/background color). They avoid
  the camera overlay automatically.
- Export **SRT / VTT / TXT**, copy transcript. Optionally generated automatically after each
  recording.

**Editor & export**
- Trim with a filmstrip timeline, frame stepping (← →), Space to play/pause.
- **Split the recording into sections** (S) and edit each one: **delete** it (⌫, press again to
  restore), **hide the screen** (H; the camera then fills the frame), **hide the camera** (C),
  **move the camera** for that section (drag it, or ⌥ + arrow keys between corners), or
  **mute** it (M). Layout changes between sections animate smoothly, and deleted parts are
  skipped seamlessly in playback and export.
- Everything is keyboard-driven and in the **Timeline** and **Playback** menus: ↑ ↓ jump between
  splits, I / O trim to the playhead, ⌘Z / ⇧⌘Z undo and redo every edit, ⌘/ shows all shortcuts.
  Right-click a section on the timeline for more (join, reset, camera position).
- Screen Studio-style framing: **backgrounds** (gradients), padding, rounded corners, shadow.
- **Aspect ratios** for any platform: Auto, 16:9, 9:16 (Reels/TikTok/Shorts), 1:1, 4:3.
- Per-track volume for microphone and system audio.
- Export **MP4 / MOV** (H.264 or HEVC; Original, 4K, 1440p, 1080p, 720p) or **GIF**, with an
  optional `.srt` sidecar. Then Show in Finder, **Copy** (paste straight into Slack/Mail) or Share.

**Library**
- All recordings with edited-look thumbnails, search across **titles and transcripts**,
  rename, reveal, move to Trash. Recordings live in `~/Movies/OwnRecord`, one folder each
  (`screen.mov`, `camera.mov`, `recording.json`, `thumbnail.jpg`). Edits never touch the
  source media.

## Build & run

Only the Xcode Command Line Tools are needed (Swift 6).

```sh
scripts/build-app.sh          # release build → build/OwnRecord.app
open build/OwnRecord.app
```

On first use macOS asks for **Screen Recording**, **Microphone**, **Camera** and
**Speech Recognition** access. After granting Screen Recording, macOS may ask you to quit and
reopen the app.

Builds are ad-hoc signed with a designated requirement pinned to the bundle ID
(`com.ownrecord.OwnRecord`), so macOS keeps the Screen Recording permission across rebuilds.
If you ever switch signing and capture stops working, reset the entry with
`tccutil reset ScreenCapture com.ownrecord.OwnRecord` and grant it again. For distribution, sign
with a real identity: `SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh`.

Good to know:
- macOS 15 periodically asks you to confirm apps that record the screen without the system
  window picker ("…requesting to bypass the system private window picker"). Choose **Allow**.
- In **Window** mode, ScreenCaptureKit only captures system audio from that window's app. Use
  **Screen** or **Area** to capture audio from every app.

## Tests

```sh
swift test                                                   # logic + end-to-end pipeline tests
OWNRECORD_SNAPSHOTS=1 swift test --filter SnapshotTests      # renders UI screenshots to tmp/snapshots
```

The pipeline tests record synthetic screen/camera movies through the real `MovieWriter`,
composite them with the real compositor, and export MP4 and GIF. Scratch files go to `tmp/`
(git-ignored).

## Architecture

```
Sources/OwnRecord
├── App/            entry point, AppModel (composition root), menus, status item, windows
├── Capture/        RecordingController (state machine), ScreenCaptureKit session, camera &
│                   mic capture, MovieWriter (AVAssetWriter), RecordingClock (pause-aware timeline)
├── Rendering/      LayoutEngine (pure geometry), FrameRenderer (Core Image), custom
│                   AVVideoCompositing compositor, CompositionBuilder
├── Transcription/  Speech-framework engine, cue builder, SRT/VTT export
├── Export/         video + GIF export
├── Library/        on-disk recording store, thumbnails
├── Models/         Recording, EditSettings (layout/camera/subtitles/audio), timeline sections
│                   and the source ↔ edited time map, Transcript
├── Support/        preferences, permissions, hot keys, panels, helpers
└── UI/             Home (library), Recorder panel, Overlays (bubble, controls, countdown,
                    area selection), Editor, Settings
```

Screen and camera writers start their sessions at the same host-clock instant, so the two files
are aligned without post-processing. The editor preview and exports share one compositor, so
what you see is what you export.

## Roadmap ideas

- **Auto-zoom on clicks** and smoothed/enlarged cursor (Screen Studio's signature feature).
- Speed changes per section, **remove silences and filler words** from the transcript
  (text-based editing), zoom into a region for a section.
- Animated word-by-word captions; subtitle **translation** (Translation framework).
- AI title, summary and chapters (Apple Foundation Models on macOS 26, or a cloud LLM).
- Camera background blur/replacement (Vision person segmentation), voice noise reduction.
- Keystroke overlay and on-screen drawing during recording.
- Shareable links / cloud upload with comments and view analytics.
- Customizable shortcuts, launch at login, Do Not Disturb during recording, disk-space checks.
- Adopt Apple's `SCContentSharingPicker` as an option, which avoids the periodic macOS 15
  confirmation prompt.
- `SpeechAnalyzer` transcription on macOS 26; embedded soft-subtitle tracks.
