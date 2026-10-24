# Changelog

All notable changes to Minute. The newest version is first. Each release lists what is **new**, what was **improved** and what was **fixed**; the app shows
the current version's notes once after an update (Help > What's New). Format follows [Keep a Changelog](https://keepachangelog.com), versions follow [SemVer](https://semver.org).

## [1.2.0] - 2026-10-24

### New
- **Claude API as the writing engine** (Settings > AI engine, optional). Minutes, fact-checks, name fixes, tidy-ups and "Ask" can use Claude (Opus 5.5, Sonnet 5.5 or Haiku 5.5) instead of the model on this Mac, so a small or busy Mac doesn't have to run one. The key is kept in the Keychain, "Test Connection" checks it, and if Claude can't be reached Minute falls back to the model on this Mac when there is one. Speech recognition and audio stay on this Mac.

### Fixed
- **Teams (and any call) recorded the meeting audio as unintelligible, too-fast speech.** When a Bluetooth headset switches to call mode, the audio device's sample rate drops (48 kHz to 16 kHz) under the recording; the meeting audio was saved at one third of its real length and the minutes were written from noise. Minute now watches the audio clock while recording and restarts the capture at the new rate, records which file covers which minutes (`segments.json`), and repairs recordings whose length doesn't match the meeting automatically.
- Processing no longer stops when a tool prints a half-written character, and a model that loops can no longer run forever (output is capped).
- Mic and meeting-audio restarts no longer cancel each other when both happen together.

## [1.1.0] - 2026-10-20

### New
- **Open items**: every action point from every meeting in one list, with owner and due date, overdue in red, tick-off and an owner filter.
- **Flag a moment** while recording (Action, Decision, Important) from the floating control, the recording card, the menu bar or ⌃⌥A / ⌃⌥D / ⌃⌥I in any app. The minutes writer treats what was said just before a flag as a must-include.
- **Pause my microphone while I'm muted** (Settings, online meetings, off by default) for meeting apps that release the mic when you mute.
- **Share menu** on a past meeting: copy as Markdown / plain text, save Markdown or subtitles (.srt), or email the minutes with the PDF.
- **Show where this was said**: a button on every topic scrolls to, highlights and plays the transcript line it came from.
- **Floating control** for Teams, Zoom, Meet, Webex, Slack, Discord and FaceTime, hidden from screen sharing.
- **Shared-screen context**: slides and documents on the meeting window are read on this Mac (OCR) and used to spell names and numbers right.
- **Calendar context**: the running event names the meeting and its invitees help spell names; invitees appear in the speaker menu.
- **Minutes language** setting (language of the meeting, Bahasa Indonesia or English).
- **Back Up Meetings** to a single zip, with or without recordings.
- **Library filters** (All, This week, Drafts, Exported) and search over owners and tasks.
- **minute:// links** for Shortcuts and scripts (start, stop, flag, open), and optional **Open at login** and **Show meetings in Spotlight**.
- **What's New** after updates, this changelog, and a notice if Minute closed unexpectedly last time (crash reports stay on this Mac).

### Improved
- Indonesian interface; first-run welcome, tutorial and one-time permission page; template learning; hardware-aware model choice.
- Minutes accuracy benchmark 81% to 92%; a 58-minute meeting is processed in about a minute.
- Crash recovery for unfinished recordings, cancel and retry, disk guard, queued jobs.
- Minutes are saved atomically and the previous version is kept (`MoM.previous.json`) whenever they are rewritten.
- Hardened Runtime and entitlements are enabled, ready for notarization.

### Fixed
- Whisper inventing text on quiet audio; mistimed transcript lines around silences; empty minutes for talk-style meetings; a crash when `~/.mom` was missing.

## [1.0.0] - 2026-10-19

### New
- Record online (meeting audio + mic) and onsite meetings, transcribe on this Mac (whisper.cpp), write minutes with a local model (Ollama), review and edit, export Word and PDF in your own template.
