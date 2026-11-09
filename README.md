# Screen Recorder

A standalone macOS screen recorder that captures **the audio the apps on screen are actually
producing** — not the microphone, and not a loopback of your speakers.

Built for **macOS Sonoma 14.6** on Apple's own ScreenCaptureKit + AVFoundation, so there is no
kernel extension, no virtual audio driver (no BlackHole/Soundflower/Loopback), and nothing to
install besides the app itself.

---

## Why the audio is different from most recorders

Most "screen + audio" tools either record the microphone, or ask you to install a virtual audio
device and route your output through it — which changes your system volume behaviour, breaks when
you plug in headphones, and mixes in every notification sound.

This app asks the window server for the **audio of the capture itself**. The sound is tapped
where the apps produce it, which means:

* The recording is unaffected by your system volume (you can record at full quality with the
  volume at zero, or with headphones unplugged).
* It is independent of the selected output device.
* Your microphone is never opened — the app does not request microphone permission at all.
* Choosing **Specific apps** records only *that app's* audio. A Safari tab, a game, a video
  call's incoming audio — with every other sound on the Mac left out of the file.

Audio is captured as 48 kHz stereo and written as either transparent AAC (256/320 kbps) or
untouched 32-bit float PCM.

---

## Features

| | |
|---|---|
| **Sources** | A whole display, a single window, or a set of applications |
| **Audio** | System/app audio via ScreenCaptureKit — 48 kHz stereo, AAC 256/320 kbps or lossless 32-bit float PCM |
| **Video codecs** | H.264 (maximum compatibility), HEVC/H.265 (best quality per MB), Apple ProRes 422 (editing master) |
| **Containers** | `.mp4` and `.mov` |
| **Resolution** | Full native Retina pixels — a 1440p display records at 2880×1800, not half size |
| **Frame rates** | 24 / 30 / 48 / 60 / 120 fps |
| **Bitrate** | Derived from pixels × fps with a Balanced / High / Maximum target |
| **Live feedback** | Elapsed time, growing file size, frame count, and a level meter proving audio is arriving |
| **Pause / resume** | The pause gap is removed from the timeline, so there is no frozen hole in the movie |
| **Export** | MP4 (H.264 + AAC), MP4 (HEVC + AAC), MOV re-wrap without re-encoding, or M4A audio only |
| **Resilience** | If the display is unplugged or the captured window closes, everything recorded so far is still saved |

---

## Build and run

Requires macOS 14.6 or later and the Xcode 15 command line tools (`xcode-select --install`).

```bash
./Scripts/build-app.sh
```

```bash
open "dist/Screen Recorder.app"
```

The script compiles a release binary with SwiftPM, assembles `dist/Screen Recorder.app`, and
ad-hoc code-signs it. To sign with your own Developer ID instead:

```bash
./Scripts/build-app.sh --sign "Developer ID Application: Your Name (TEAMID)"
```

### Granting permission (required once)

ScreenCaptureKit needs the Screen Recording privilege, which also covers the system audio tap:

1. Launch the app and press **Request Permission**, or open
   **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. Enable **Screen Recorder**.
3. Quit and reopen the app — macOS only hands the privilege to a freshly launched process.

The privilege is tied to the app's code signature. With an ad-hoc signature, rebuilding changes
that signature and macOS may ask again; signing with a Developer ID (above) makes it stick.

---

## Choosing a format

| Goal | Codec | Container | Audio |
|---|---|---|---|
| Share anywhere — Slack, browsers, phones, TVs | H.264 | `.mp4` | AAC 256 |
| Best quality for the file size, long recordings | HEVC | `.mp4` | AAC 256 |
| Hand off to Final Cut / Premiere / Resolve | ProRes 422 | `.mov` | Lossless PCM |
| Keep the audio bit-for-bit for post-production | any | `.mov` | Lossless PCM |

Uncompressed PCM and ProRes are only legal inside `.mov`; the settings panel keeps the
combination valid automatically, so an impossible choice can never reach the encoder.

Rough sizes for one minute at 1440p60: HEVC/High ≈ 120 MB, H.264/High ≈ 180 MB,
ProRes 422 ≈ 2.5 GB.

---

## How it works

```
ScreenCaptureKit SCStream
  ├── .screen  →  420v or BGRA frames  ─┐
  └── .audio   →  48 kHz float PCM    ─┤
                                        ├── MovieWriter (AVAssetWriter)
                                        │     video track: H.264 / HEVC / ProRes 422
                                        │     audio track: AAC or 32-bit float PCM
                                        └──→ .mov / .mp4 on disk
                                              └── MediaExporter (AVAssetExportSession)
                                                    → MP4 / MOV / M4A
```

| Path | Purpose |
|---|---|
| `Sources/ScreenRecorder/Model/RecordingSettings.swift` | Codecs, containers, bitrate model, AVAssetWriter settings, validation |
| `Sources/ScreenRecorder/Capture/ShareableContentStore.swift` | Enumerates displays/windows/apps; permission state |
| `Sources/ScreenRecorder/Capture/CaptureTarget.swift` | Content filters and native pixel sizing |
| `Sources/ScreenRecorder/Capture/CaptureSession.swift` | The `SCStream` and its screen/audio outputs |
| `Sources/ScreenRecorder/Capture/RecordingEngine.swift` | Recording lifecycle and live statistics |
| `Sources/ScreenRecorder/Writing/MovieWriter.swift` | AVAssetWriter, pause/resume retiming, clean finish |
| `Sources/ScreenRecorder/Writing/AudioSampleConverter.swift` | De-interleaved → interleaved PCM for the lossless path; level metering |
| `Sources/ScreenRecorder/Export/MediaExporter.swift` | Format conversion |
| `Sources/ScreenRecorder/App/` | SwiftUI interface |

Implementation details worth knowing:

* Only frames ScreenCaptureKit marks `.complete` are written — idle and blank frames would
  waste bitrate or write black video.
* The first video frame defines time zero for both tracks; audio arriving before it is dropped,
  so the tracks can never start out of sync.
* Pausing records the gap and subtracts it from every later timestamp, so audio and video stay
  locked together across a pause.
* `excludesCurrentProcessAudio` keeps the app's own sounds out of the recording — no feedback loop.
* 4:2:0 frames are requested for H.264/HEVC (what the hardware encoders consume natively) and
  BGRA for ProRes, which keeps 4:2:2 chroma for crisp coloured text.

---

## Limitations

* macOS 14.6+ only; ScreenCaptureKit's audio tap does not exist on older releases.
* No microphone track. That is deliberate — mixing a mic in is out of scope for this app.
  (On macOS 15+ ScreenCaptureKit gained a separate microphone stream; this app targets 14.6.)
* DRM-protected video (Apple TV+, Netflix in Safari) appears black and silent — the system
  refuses to share it with any capture client.
* HDR capture is recorded as SDR Rec. 709.
