# Minute

A quiet menu-bar app for macOS that records a meeting, writes the minutes on-device, and hands you a finished Word + PDF document.

**Record → Review → Export.** Nothing leaves your Mac: audio capture, transcription (whisper.cpp) and drafting (a local LLM via Ollama) all run locally.

## Using it

Minute is a regular app (Dock icon, `~/Applications/Minute.app`). Its main window has a **Record** card at the top of the sidebar, then every past meeting; pick one to read its minutes or transcript, ask questions about it, edit and re-export, or open the Word/PDF. The menu bar icon is a shortcut for quick start/stop. Quitting while recording or writing minutes asks for confirmation.

## Setup and storage

On first launch Minute walks you through setup: where to save (this Mac, iCloud Drive, OneDrive / Google Drive / Dropbox if present, or any folder), the one-time macOS access prompts (Microphone, meeting audio, and the folder itself), and an optional "delete recordings after export" privacy setting. Change the location any time in **Settings (⌘,)**: the **whole library moves**, not just new meetings, so documents never end up split across two places (name clashes get a `-2` suffix, and if anything fails the location is left unchanged). The pipeline reads the same location from `~/.mom/config.json`.

## How it works

1. **Record.** Hold the red button in the menu bar for a second to start. *Online* mode captures the meeting audio (Teams, Zoom, Meet, anything playing on the Mac) plus your mic as two separate tracks. *Onsite* mode captures the mic only. Holding (0.8 s to start, 1.5 s to stop) means you can't start or stop by accident; Quit is disabled while recording and the Mac stays awake.
2. **Review.** When you stop, Minute transcribes English and Bahasa Indonesia (mixed is fine) and drafts the minutes. The window slides to a review step that shows the page exactly as the Word document will look (logo, table, fonts); click anywhere on it to edit. **Tidy up** fixes spacing, punctuation and wording with the on-device model (undoable), and can run automatically on export. A transcript panel sits beside the page to check against.
3. **Export.** One click fills your own Word template and exports a `.docx` and a `.pdf`.

**All meetings** (menu bar) opens the library: every past meeting with its minutes (the page preview) and transcript, searchable across both, with Open Word / PDF, re-edit and re-export, and Move to Bin.

Output lands in `~/Documents/MoM/<date_time>/`: `mic.caf`, `system.caf`, `transcript.md`, `MoM.json`, and the exports named `MOM_<Document name>_<yyyymmdd>.docx` / `.pdf` (for example `MOM_Update SSL Ondeck_20261020.pdf`; the name comes from the agenda, the date is the meeting date).

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

## Templates and hardware

- **Any template.** In setup (or Settings) drop in a Word template. `mom --learn-template file.docx` has the local model read it, work out which cell holds the agenda, date, time, each participant group and where the topics list goes, and stores that in `~/.mom/template.json`. Minutes are then written into the user's own file, so the layout stays theirs. If the model is unavailable, label matching finds the agenda/date/time cells.
- **No template?** `mom --make-template [--logo image] [--org name]` builds a clean, neutral page. Drop in a logo (or give an organisation name); with neither, the page has no logo. Replace the logo any time in Settings.
- **Hardware tier.** `mom --hardware` reads the chip and memory. 15 GB and up: Standard (`qwen3:8b`). Less: Light (`qwen3:4b`, shorter passes). Every tier runs the same passes (draft, fact-check, deadlines, tidy); only throttling or Low Power Mode shortens them. The model downloads once, on request, in setup.

## Transcript step

Recording is now four steps: **Record, Transcript, Minutes, Export**. After the recording is transcribed on the Mac, the transcript opens for checking before any minutes are written: timestamps (click to play the audio from that line), You/Others labels, search, copy, edit any word, remove lines. "Write minutes" then drafts from the corrected text (`mom --draft folder`); "Skip this step next time" goes straight on. Whisper's invented text on quiet audio (credit lines, "thanks for watching") is filtered, and minutes never come back with an empty topic list (a fallback pass lists what was said even for talks with no decisions).

## Past meetings and names

- **Past meetings** open with the transcript on the left and the minutes on the right, both editable and saved automatically a moment after each change. Remove a misheard line, fix a word, press **Rewrite minutes** to redraft from the corrected transcript, **Tidy up**, or **Export again**. Narrow windows switch to one pane (Both / Minutes / Transcript).
- **Indonesian names.** `pipeline/lexicon_id.txt` ships about 400 brands, restaurants, shops, apps, banks, places, institutions and office terms. After transcription the local model swaps only words that are clearly misheard versions of those names (judged by sound and context: "TZ" about a tea drink becomes Teazzi, "indo maret" becomes Indomaret), and the minutes prompt carries the same list as spelling reference.
- **Learning.** Words you fix in a transcript are remembered in `~/.mom/corrections.txt` and applied to future transcripts. Add your own names in Settings > Names & terms (`~/.mom/terms.txt`; `heard = correct` forces a spelling).
- **Always learning.** After each set of minutes, capitalised words and acronyms that show up in two different meetings are added to the vocabulary automatically (`~/.mom/seen_terms.json` and `glossary.txt`), so Whisper and the minutes writer favour them from then on. Nothing is uploaded and the speech model itself is not retrained.

## First run

A new Mac goes through six pages: **Welcome**, **Get Minute ready**, **Where to save**, **Your template**, **Permissions**, and a four-page **tour** (hold to record with a live practice button, check the transcript, edit the minutes, export and find it later). "Get Minute ready" runs `mom --doctor` and lists what is missing (whisper.cpp and ffmpeg and Ollama via Homebrew, the Whisper model about 570 MB, the writing model 2.6 to 5.2 GB by Mac, `python-docx`, and optionally Microsoft Word for PDF). Each item has a **Get** button and **Get everything** installs them in order; nothing downloads until the user clicks. The tour can be replayed from Settings > Welcome Tour & Setup.

## Permissions are asked once

Setup has one "Allow access once" page for everything macOS can ask: Microphone, Meeting audio, your meetings folder, Notifications and PDF export through Word (a one-time check that also grants Word its folder access). "Allow All" walks through them. macOS remembers a permission by the app's code signature, and an ad-hoc signature changes on every build, so **run `./setup-signing.sh` once** before building: it creates a local "Minute Local" signing identity and `build.sh` signs with it, so permissions survive every update.
