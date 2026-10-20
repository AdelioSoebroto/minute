# Minute

A macOS app that records a meeting (online or in the room), writes the minutes on your Mac, and hands you a finished Word and PDF in **your own template**. Nothing leaves the Mac: audio capture, transcription (whisper.cpp), drafting (a local model through Ollama) and OCR all run locally.

**Record → Transcript → Minutes → Export.**

## Using it

Minute is a regular app (Dock icon, `~/Applications/Minute.app`) with a menu bar icon for quick start and stop.

- **Record.** Hold the red button (0.8 s to start, 1.5 s to stop, so a stray click can't start or end a meeting). *Online* captures the meeting audio (Teams, Zoom, Meet, anything playing) plus your mic as two tracks; *Onsite* captures the mic. Menu: **File > Start Recording… (⇧⌘R)** asks first.
- **Floating control.** When Teams, Zoom, Meet, Webex, Slack, Discord or FaceTime starts using your microphone, a small pill appears at the edge of the screen with hold-to-record. While recording it shows the timer, level and hold-to-stop, and says "Meeting ended?" when the call ends. It floats over full-screen meetings, remembers where you put it, and is hidden from screen sharing. Turn it off in Settings.
- **Transcript.** After recording, the transcript opens for checking before any minutes are written: timestamps (click to play from that line), You/Others labels (click a label to name a speaker, or rename every line from them), search, copy, edit words, remove lines (⌘Z brings them back). "Skip this step next time" goes straight on.
- **Minutes.** The page looks exactly like the document (your logo, table, fonts); click anywhere to edit. Tidy up fixes spacing, punctuation and wording and can run automatically.
- **Export.** One click fills your template and exports `.docx` and `.pdf`, named `MOM_<Document name>_<yyyymmdd>`.
- **All Meetings.** Every past meeting with the transcript on the left and the editable minutes on the right, autosaved. Rewrite minutes from the corrected transcript, Tidy up, Export again, Ask a question about the meeting, search across everything.

## Context beyond the audio

- **Shared screens.** In an online recording Minute reads the text on the meeting window every 20 seconds (on-device OCR via Vision, only the meeting's own window, never the rest of your screen) and keeps changes in `screens.json`. The transcript shows "On screen · 00:12:30" moments, and the minutes writer gets them to spell names, products and numbers right and to understand "yang ini". Pictures are kept only if you turn that on. Needs Screen Recording permission (optional).
- **Calendar.** If an event is running when you start, its title and invitees go to `meeting.json` and help name the meeting and spell names (read only, optional).
- **Indonesian names.** `pipeline/lexicon_id.txt` ships about 400 brands, restaurants, shops, apps, banks, places and office terms; the local model fixes only words that are clearly misheard versions of them ("TZ" about a tea drink becomes Teazzi). Words you correct are learned (`~/.mom/corrections.txt`), terms that recur across meetings are added automatically, and you can add your own in Settings > Names & terms.

## First run

Welcome → **Get Minute ready** (`mom --doctor` lists what's missing and installs it on click: whisper.cpp, ffmpeg, Ollama via Homebrew, the Whisper model, the writing model, `python-docx`; Word is optional for PDFs) → where to save (this Mac, iCloud, OneDrive and so on, movable later with the whole library) → your template (drop a Word file and Minute learns where everything goes, or start from a clean one with your logo) → **Allow access once** (microphone, meeting audio, folder, notifications, Word, optional screen and calendar) → a four-page tour. Replay it from Help.

macOS remembers a permission by the app's signature, and an ad-hoc signature changes on every build. Run `./setup-signing.sh` once before building so permissions survive updates.

## Adapts to the Mac

`mom --hardware` picks the model by memory: 15 GB and up runs `qwen3:8b` (Standard), less runs `qwen3:4b` (Light). Every tier runs the same passes (draft, fact-check, deadlines, tidy). Every run also adapts to power: on battery or Low Power Mode it works more gently, it pauses while macOS throttles, runs at low priority, gives the model only the context it needs, and unloads it afterwards.

## Reliability

- **Crash recovery.** A recording that was running when the app or Mac stopped is offered for recovery at next launch (audio is written continuously).
- **Cancel and retry.** Processing can be cancelled (it kills whisper and ffmpeg too); failures offer Try Again and Copy Diagnostics (private details removed).
- **Disk guard.** Warns under 2 GB free and stops safely under 200 MB.
- **Queue.** Back-to-back meetings wait for the previous job ("Waiting for the previous job to finish").
- Device changes mid-meeting continue in a new segment; speaker echo is removed; Whisper's invented text on quiet audio is filtered; the minutes are fact-checked against the transcript and never come back with an empty topic list.
- Works offline. Only the one-time model downloads need a connection.

## Quality checks

```bash
./build.sh test            # pipeline tests + app logic tests
python3 tests/bench.py     # accuracy benchmark on the real local model (names, dates, owners, topic count)
```

`tests/bench.py` runs fixed transcripts through the minutes writer and scores whether the facts that must appear do, and that names never said don't. Run it before and after changing a prompt or model. CI runs the tests and the build on every push (`.github/workflows/ci.yml`).

## Install

```bash
./setup-signing.sh         # once: stable local signing identity
./build.sh deploy          # build, install ~/Applications/Minute.app and the pipeline into ~/.mom/bin
./release.sh               # zip for other Macs (Developer ID signing and notarization via SIGN_ID / NOTARY_PROFILE)
```

Requirements: Apple silicon, macOS 14.2 or later, Xcode Command Line Tools. Everything else is installed from the app's setup page.

## Releases

Versions follow SemVer: `VERSION` holds the number, the build number is the commit count, and `CHANGELOG.md` says what is **new**, **improved** and **fixed** in each release. The app shows the current notes once after an update (Help > What's New).

```bash
# 1. bump VERSION and add a "## [x.y.z] - date" section to CHANGELOG.md, commit
./release.sh               # refuses without release notes or with uncommitted changes; tests, builds, signs, zips, tags
git push origin vX.Y.Z     # CI builds it again and publishes the GitHub release with the notes
```

CI (`.github/workflows/ci.yml`) lints the property lists, runs every test, builds with Hardened Runtime and checks the signature and version on every push. The test suite fails when the current `VERSION` has no changelog section.

Built in for stability: atomic saves and `MoM.previous.json` snapshots, crash recovery for recordings, a notice (and local crash and macOS diagnostic reports in `~/.mom/crashes`) when Minute closed unexpectedly, Hardened Runtime with minimal entitlements, and `minute://start|stop|flag/<kind>|open` links for Shortcuts (start and stop always ask first).

## Layout

```
Sources/App.swift            app, menu bar panel, recording flow and Recorder
Sources/Hover.swift          meeting detection (Core Audio) and the floating control
Sources/ScreenContext.swift  window OCR for shared screens (ScreenCaptureKit + Vision)
Sources/CalendarContext.swift
Sources/Workspace.swift      past meeting: transcript beside minutes
Sources/TranscriptStep.swift transcript list and step
Sources/Library.swift        page preview and meetings library
Sources/Setup.swift, Onboarding.swift, Template.swift   first run, settings, tour, template learning
Sources/Capture.swift        system-audio tap and microphone
Sources/Safety.swift, TLine.swift, Glass.swift
Resources/id.lproj           Indonesian interface
pipeline/mom, lexicon_id.txt transcription, drafting, template learning, export
tests/                       pipeline tests, app logic tests, benchmark
```

## Design

Liquid Glass on macOS 26 with system-material fallback on 14.2 to 25 (`Sources/Glass.swift`), San Francisco, dark mode, VoiceOver labels, Reduce Motion, and English plus Indonesian.

## Privacy

Recording a meeting needs the participants' consent and may be restricted by company policy. Minute never uploads audio, text or screen content; keep the generated folders as confidential as the meetings themselves.
