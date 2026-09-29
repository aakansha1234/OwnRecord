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
- **Teleprompter** for your script or speaker notes: a floating window just under the camera
  that scrolls by itself (adjustable speed and text size), starts and pauses with the recording,
  and is never captured. Turn it on in the recorder or with ⌥⌘T; **⌥⇧⌘T** starts or pauses
  scrolling from any app.

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
- Styled, burned-in subtitles (position, size, weight, text/background color, outline around
  the letters, shadow). They avoid the camera overlay automatically. Sections can have a style
  of their own, e.g. to restyle the subtitles from some point on.
- Export **SRT / VTT / TXT**, copy transcript. Optionally generated automatically after each
  recording.

**Editor & export**
- Trim with a filmstrip timeline, frame stepping (← →), Space to play/pause.
- **Split the recording into sections** (S) and edit each one: **delete** it (⌫, press again to
  restore), **hide the screen** (H; the camera then fills the frame), **hide the camera** (C),
  **move, resize or reshape the camera** for that section (drag it, or ⌥ + arrow keys between
  corners), or **mute** it (M). Layout changes between sections animate smoothly, and deleted parts are
  skipped seamlessly in playback and export.
- **Blur or pixelate** passwords, emails and other private details: press B (or ⇧B) and drag
  over the area in the preview, then move or resize it. Blurs belong to a section like the other
  section settings, or apply to all sections at once.
- **Split at silences** (⇧S) finds the pauses in your voice, shows them on a level graph and the
  timeline, and splits around them or removes them in one undoable step (adjustable threshold,
  shortest pause and the margin kept around speech).
- Everything is keyboard-driven and in the **Timeline** and **Playback** menus: ↑ ↓ jump between
  splits, I / O trim to the playhead, ⌘Z / ⇧⌘Z undo and redo every edit, ⌘/ shows all shortcuts.
  Right-click a section on the timeline for more (join, reset, camera position).
- Screen Studio-style framing: **backgrounds** (gradients), padding, rounded corners, shadow.
- **Aspect ratios** for any platform: Auto, 16:9, 9:16 (Reels/TikTok/Shorts), 1:1, 4:3.
- Per-track volume for microphone and system audio.
- Export **MP4 / MOV** (H.264 or HEVC; Original, 4K, 1440p, 1080p, 720p) or **GIF**, with an
  optional `.srt` sidecar. Then Show in Finder, **Copy** (paste straight into Slack/Mail) or Share.
- Export for **iMovie**: the finished video, and/or the screen (with the sound) and camera as
  separate clips, with cuts, blurs, hidden parts and mutes applied and lined up for picture in
  picture. Drag the clips straight from OwnRecord into iMovie.

**Library**
- All recordings with edited-look thumbnails, search across **titles and transcripts**,
  rename, reveal, move to Trash. Recordings live in `~/Movies/OwnRecord`, one folder each
  (`screen.mov`, `camera.mov`, `recording.json`, `thumbnail.jpg`). Edits never touch the
  source media.

**Command line & AI agents**
- The `ownrecord` command records, edits and exports from a terminal, scripts and AI agents such
  as Claude Code: `record` (screen, window or area, with `--duration` and `--wait`), `stop`,
  `list`, `show`, `transcribe`, `transcript`, `cut`, `trim`, `silences`, `blur`, `set` (layout,
  camera, subtitle and audio settings), `frame` (a still to check an edit) and `export` (MP4,
  MOV, GIF, iMovie clips). `--json` on any command gives machine-readable output; `ownrecord help`
  explains everything.
- `ownrecord mcp` is an MCP server, so AI apps such as Claude Desktop, ChatGPT or Cursor can do
  the same: 14 tools to record, list, inspect, transcribe, edit (cuts, trim, blur, layout, camera
  and subtitle settings, also from a point in time) and export, plus `get_frame`, which returns a
  frame as an image the AI can look at. Long exports and transcriptions report progress, and
  deleting or discarding are separate tools so apps can ask first. It speaks MCP 2026-07-28 and
  the earlier `initialize`-based versions.
- Turn it on in **Settings › Command Line & AI Apps** (off by default), where **Install…** puts
  the command in `/usr/local/bin` and **Copy Configuration** copies the MCP server setting for an
  AI app. The app does the work (and is started in the background if needed), so recordings use
  its permissions and show the usual controls, and edits made while a recording is open in the
  editor can be undone there. Only apps running as you can use it.

```sh
ownrecord record --window Simulator --countdown 0 --duration 20 --wait
ownrecord transcript latest              # timed lines, to decide what to cut
ownrecord cut latest 4.2 6.8             # times are in the original recording
ownrecord silences latest --delete
ownrecord blur latest --rect 0.62,0.08,0.3,0.05 --from 12 --to 20
ownrecord frame latest --at 10 -o check.png
ownrecord export latest -o demo.mp4
ownrecord set latest subtitles.outlineWidth=0.12 subtitles.shadow=false --from 30   # restyle from 0:30
```

To use it from Claude Desktop, add this to `claude_desktop_config.json` (Settings › Developer ›
Edit Config), or paste what **Copy Configuration** gives you:

```json
{ "mcpServers": { "ownrecord": { "command": "/Applications/OwnRecord.app/Contents/MacOS/OwnRecord", "args": ["mcp"] } } }
```

In Claude Code: `claude mcp add ownrecord -- ownrecord mcp`.

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
├── Automation/     the `ownrecord` tool (the app's executable under that name) and its MCP
│                   server, the socket server they talk to, and the commands it runs in the app
├── Capture/        RecordingController (state machine), ScreenCaptureKit session, camera &
│                   mic capture, MovieWriter (AVAssetWriter), RecordingClock (pause-aware timeline)
├── Rendering/      LayoutEngine (pure geometry), FrameRenderer (Core Image), custom
│                   AVVideoCompositing compositor, CompositionBuilder
├── Transcription/  Speech-framework engine, cue builder, SRT/VTT export, silence detection
├── Export/         video, GIF and iMovie clip export
├── Library/        on-disk recording store, thumbnails
├── Models/         Recording, EditSettings (layout/camera/subtitles/audio), timeline sections
│                   and the source ↔ edited time map, Transcript
├── Support/        preferences, permissions, hot keys, panels, helpers
└── UI/             Home (library), Recorder panel, Overlays (bubble, controls, countdown,
                    area selection), Editor, Teleprompter, Settings
```

Screen and camera writers start their sessions at the same host-clock instant, so the two files
are aligned without post-processing. The editor preview and exports share one compositor, so
what you see is what you export.

## Roadmap ideas

- **Auto-zoom on clicks** and smoothed/enlarged cursor (Screen Studio's signature feature).
- Speed changes per section, **remove filler words** from the transcript (text-based editing),
  zoom into a region for a section.
- Export projects for Final Cut Pro, DaVinci Resolve and Premiere Pro (FCPXML / XML).
- Animated word-by-word captions; subtitle **translation** (Translation framework).
- AI title, summary and chapters (Apple Foundation Models on macOS 26, or a cloud LLM).
- Camera background blur/replacement (Vision person segmentation), voice noise reduction.
- Keystroke overlay and on-screen drawing during recording.
- Shareable links / cloud upload with comments and view analytics.
- Customizable shortcuts, launch at login, Do Not Disturb during recording, disk-space checks.
- Adopt Apple's `SCContentSharingPicker` as an option, which avoids the periodic macOS 15
  confirmation prompt.
- `SpeechAnalyzer` transcription on macOS 26; embedded soft-subtitle tracks.
