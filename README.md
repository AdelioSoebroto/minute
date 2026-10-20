# Minute

A quiet menu-bar app for macOS that records a meeting, writes the minutes on-device, and hands you a finished Word + PDF document.

**Record → Review → Export.** Nothing leaves your Mac: audio capture, transcription (whisper.cpp) and drafting (a local LLM via Ollama) all run locally.

## How it works

1. **Record.** Hold the red button in the menu bar for a second to start. *Online* mode captures the meeting audio (Teams, Zoom, Meet, anything playing on the Mac) plus your mic as two separate tracks. *Onsite* mode captures the mic only. Holding (0.8 s to start, 1.5 s to stop) means you can't start or stop by accident; Quit is disabled while recording and the Mac stays awake.
2. **Review.** When you stop, Minute transcribes English and Bahasa Indonesia (mixed is fine) and drafts the minutes. The window slides to a review step where you can edit every field and check against the transcript.
3. **Export.** One click fills your own Word template and exports a `.docx` and a `.pdf`.

Output lands in `~/Documents/MoM/<date_time>/`: `mic.caf`, `system.caf`, `transcript.md`, `MoM.json`, `MoM.docx`, `MoM.pdf`.

## Requirements

- Apple silicon Mac, macOS 14.2 or later (system-audio capture uses Core Audio process taps)
- Xcode Command Line Tools (`swiftc`)
- `brew install ffmpeg whisper-cpp ollama`
- A whisper model, e.g. `ggml-large-v3-turbo-q5_0.bin` from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp), in `~/.mom/models/`
- An Ollama model: `ollama pull qwen3:14b`
- Microsoft Word (used to convert the filled template to PDF)
- Python 3 with `python-docx` (`pip3 install python-docx`)

## Install

```bash
./build.sh deploy      # builds, installs Minute.app to ~/Applications and the pipeline to ~/.mom/bin/mom
```

Then copy your own MoM Word template to `~/.mom/template.docx` and open Minute. On first recording macOS asks for **Microphone** and **System Audio Recording** access.

Config (optional) lives in `~/.mom/config.json`:

```json
{ "whisper_model": "~/.mom/models/ggml-large-v3-turbo-q5_0.bin", "llm": "qwen3:14b", "mom_language": "auto" }
```

## Command line

```bash
mom <session-folder | audio-file>   # transcribe and draft MoM.json
mom --export <session-folder>       # MoM.json + template.docx -> MoM.docx + MoM.pdf
```

## The template

`pipeline/mom` fills a specific table layout (agenda, date, time, participants for two groups, then a numbered "Topic Discussed" list). Adapt `export()` in `pipeline/mom` if your template differs. The template itself is not part of this repo.

## Layout

```
Sources/App.swift      SwiftUI menu-bar panel and the Record / Review / Export window
Sources/Capture.swift  system-audio tap and microphone recording
pipeline/mom           transcription, drafting and document export
build.sh               build, sign (ad hoc) and install
```

## Privacy

Recording a meeting needs the participants' consent and may be restricted by company policy. Minute never uploads audio or text; keep the generated folders as confidential as the meetings themselves.
