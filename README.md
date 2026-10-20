# Minute

A quiet menu-bar app for macOS that records a meeting, writes the minutes on-device, and hands you a finished Word + PDF document.

**Record → Review → Export.** Nothing leaves your Mac: audio capture, transcription (whisper.cpp) and drafting (a local LLM via Ollama) all run locally.

## Using it

Minute is a regular app (Dock icon, `~/Applications/Minute.app`). Its main window has a **Record** card at the top of the sidebar, then every past meeting; pick one to read its minutes or transcript, ask questions about it, edit and re-export, or open the Word/PDF. The menu bar icon is a shortcut for quick start/stop. Quitting while recording or writing minutes asks for confirmation.

## How it works

1. **Record.** Hold the red button in the menu bar for a second to start. *Online* mode captures the meeting audio (Teams, Zoom, Meet, anything playing on the Mac) plus your mic as two separate tracks. *Onsite* mode captures the mic only. Holding (0.8 s to start, 1.5 s to stop) means you can't start or stop by accident; Quit is disabled while recording and the Mac stays awake.
2. **Review.** When you stop, Minute transcribes English and Bahasa Indonesia (mixed is fine) and drafts the minutes. The window slides to a review step that shows the page exactly as the Word document will look (logo, table, fonts); click anywhere on it to edit. **Tidy up** fixes spacing, punctuation and wording with the on-device model (undoable), and can run automatically on export. A transcript panel sits beside the page to check against.
3. **Export.** One click fills your own Word template and exports a `.docx` and a `.pdf`.

**All meetings** (menu bar) opens the library: every past meeting with its minutes (the page preview) and transcript, searchable across both, with Open Word / PDF, re-edit and re-export, and Move to Bin.

Output lands in `~/Documents/MoM/<date_time>/`: `mic.caf`, `system.caf`, `transcript.md`, `MoM.json`, `MoM.docx`, `MoM.pdf`.

## Requirements

- Apple silicon Mac, macOS 14.2 or later (system-audio capture uses Core Audio process taps)
- Xcode Command Line Tools (`swiftc`)
- `brew install ffmpeg whisper-cpp ollama`
- A whisper model, e.g. `ggml-large-v3-turbo-q5_0.bin` from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp), in `~/.mom/models/`
- An Ollama model: `ollama pull qwen3:8b`
- Microsoft Word (used to convert the filled template to PDF)
- Python 3 with `python-docx` (`pip3 install python-docx`)

## Install

```bash
./build.sh deploy      # builds, installs Minute.app to ~/Applications and the pipeline to ~/.mom/bin/mom
```

Then copy your own MoM Word template to `~/.mom/template.docx` and open Minute. On first recording macOS asks for **Microphone** and **System Audio Recording** access.

Config (optional) lives in `~/.mom/config.json`:

```json
{ "whisper_model": "~/.mom/models/ggml-large-v3-turbo-q5_0.bin", "llm": "qwen3:8b", "mom_language": "auto" }
```

## Icon

The default icon is the dark navy tile (`icon/Minute.icns`); the light alternative is `icon/Minute-light.icns`. Build with it using `ICON=light ./build.sh deploy`.

## Command line

```bash
mom <session-folder | audio-file>   # transcribe and draft MoM.json
mom --tidy <session-folder>         # clean up spacing, punctuation and wording in MoM.json
mom --export <session-folder>       # MoM.json + template.docx -> MoM.docx + MoM.pdf
```

## The template

`pipeline/mom` fills a specific table layout (agenda, date, time, participants for two groups, then a numbered "Topic Discussed" list). Adapt `export()` in `pipeline/mom` if your template differs. The template itself is not part of this repo.

## Layout

```
Sources/App.swift      SwiftUI menu-bar panel and the Record / Review / Export window
Sources/Library.swift  page preview, transcript view and the meetings library
Sources/Capture.swift  system-audio tap and microphone recording
pipeline/mom           transcription, drafting and document export
build.sh               build, sign (ad hoc) and install
```

## Reliability

- Works with or without internet: capture, transcription, drafting, tidying and the library all run locally (Ollama is addressed on 127.0.0.1 and ignores any VPN or proxy). Only the one-time model downloads need a connection.
- If headphones are plugged in or the audio device changes mid-meeting, recording continues in a new segment and the pipeline stitches the segments together.
- A warning appears if no meeting audio is heard 25 seconds into an Online recording (usually a missing System Audio Recording permission).
- When the meeting plays through speakers, the mic's echo of the meeting is removed from the transcript.
- The minutes are drafted, then fact-checked against the transcript before you see them. Names and company terms you finalise are remembered (`~/.mom/glossary.txt`) and fed back to the transcriber and drafter; your last exported minutes set the wording style.
- Audio is written to disk continuously; if anything fails after recording, the audio is kept and **Draft minutes** in the library retries. Each meeting folder has a `mom.log`.
- Tests: `python3 tests/test_pipeline.py`

## Design

Built on Liquid Glass: the step bar, buttons, source chips and the record button are glass, and content scrolls beneath floating controls. Everything goes through `Sources/Glass.swift`, which uses the Liquid Glass APIs on macOS 26 and later and falls back to system materials on macOS 14.2-25, so the app picks up newer system styling without per-version code. It only uses standard SwiftUI controls and system fonts (San Francisco), and honours Reduce Motion, VoiceOver and dark mode.

## Stays cool and quiet

The pipeline sizes its work to the Mac every time it runs (`device_profile()` in `pipeline/mom`): RAM, power source and battery level, Low Power Mode and macOS thermal throttling pick **full** (on power), **balanced** (on battery) or **eco** (low battery, Low Power Mode or throttling: greedy transcription, no fact-check pass). It runs at low priority, gives the language model only as much context as the transcript needs (the main cost in RAM), keeps one model loaded with a q8 cache, pauses if macOS is throttling, and unloads the model the moment it is done. The default model is `qwen3:8b` (about 5 GB).

## Privacy

Recording a meeting needs the participants' consent and may be restricted by company policy. Minute never uploads audio or text; keep the generated folders as confidential as the meetings themselves.
