# Changelog

All notable changes to Minute. The newest version is first. Each release lists what is **new**, what was **improved** and what was **fixed**; the app shows
the current version's notes once after an update (Help > What's New). Format follows [Keep a Changelog](https://keepachangelog.com), versions follow [SemVer](https://semver.org).

## [1.3.0] - 2026-11-20

### New
- **A native Mac layout for meetings**: the title and date sit in the window toolbar. The view switch (Transcript and Minutes / Minutes / Transcript), Share, Export, More and Claude are standard toolbar buttons, and Claude opens as a standard inspector panel on the right. The custom button bar at the bottom is gone; progress and errors show as a thin line under the toolbar.
- **Menu bar commands**: File › Export Word & PDF (⌘E). View › Transcript and Minutes / Minutes / Transcript (⌘1–⌘3) and Show Claude (⌘K). A new **Meeting** menu has Tidy Up Wording, Rewrite Minutes…, Open in Word, Open PDF, Show in Finder (⌥⌘R) and Move to Bin… (⌘⌫).
- **Right-click menus** on transcript lines (Play from Here, Copy Line, Remove Line), topics (Show Where This Was Said, Copy Topic, Remove Topic) and meetings (Open PDF, Open in Word, Show in Finder, Move to Bin).
- **Settings in tabs** like other Mac apps: General, Recording, AI, Template, Storage and This Mac. Each option's explanation now sits under it as a subtitle.

### Improved
- **Recording is one click**, like Voice Memos and QuickTime: a red record button. Stop works like Clear All in Notification Center: the first click turns it into a red "Stop" and the second click stops, so a stray click still can't end a meeting.
- **Haptics follow macOS**: trackpad feedback is no longer played on ordinary clicks or when steps change; macOS keeps haptics for dragging and snapping. The error sound is unchanged.
- Controls appear on hover, as in Mac lists: the play button on a transcript line (like track numbers in Music), and the remove and "show where this was said" buttons on topics. They no longer clutter every row.
- The library's filter is a standard filter button in the sidebar toolbar instead of a cramped four-way switch. Meeting rows show their status (Draft, Exported…).
- Clearer icons: Tidy Up uses a magic wand (no longer the same sparkles as Claude), "show where this was said" uses a quote bubble, and Export uses a document with an up arrow.

### Fixed
- The "show where this was said" button on topics was missing from past meetings; it's back.
- The minutes page no longer gets cut off when the sidebar and Claude are both open: it shrinks to fit, like zoom to fit in Preview. Side by side is only used when the whole page fits.
- Stop asks for a second press with VoiceOver too, not only with the mouse.
- Settings > Template now shows your current template as selected. This Mac shows "Claude (your login)" and the model's name instead of "Claude API" and a model ID.
- The Recording window shows a record button and the Online/Onsite switch when idle, instead of pointing elsewhere.
- VoiceOver reads the Filter, More and Share toolbar menus by name.

## [1.2.1] - 2026-11-20

### Improved
- **Lighter while recording**: the clock and level meters now redraw only themselves. Before, they redrew the whole app (library, open meeting, minutes page) 10 times a second during a meeting.
- **Faster transcript editing**: long transcripts no longer re-read files or search the whole list for every row on each keystroke. Speakers, invitees and playback are worked out once.
- **The library loads in the background**, so a meetings folder in OneDrive or iCloud that has to download can't freeze the window. Several refreshes in a row are merged into one.
- **Fits smaller windows**: the main window can be narrower (1000 pt). When there isn't room for transcript and minutes side by side, the view picker offers only Minutes and Transcript instead of a "Both" that showed one.
- **Keyboard**: ⌘K opens Claude, ⌘E exports, ⌘1/⌘2/⌘3 switch Both/Minutes/Transcript, Delete moves the selected meeting to the Bin (with confirmation), and Esc closes the Claude panel.
- Claude panel: the text field is ready to type in when it opens, it scrolls to "Thinking…", and its examples are generic.
- Clearer empty states in the library ("Hold the record button above…"; a filter with no matches says so).

## [1.2.0] - 2026-10-24

### New
- **Claude proofreads every transcript** (with Claude as the engine): misheard words, names, brands, teams and acronyms are corrected from the conversation, your names list, the calendar and the screen, line by line, before the minutes are written. Timestamps and meaning stay, rewrites are refused, and the raw Whisper text is kept as `transcript.raw.md`. A 36-minute meeting takes about a minute.
- **Cleaner mic in online meetings**: Apple voice processing removes the meeting audio echoing from your speakers and background noise (onsite recordings are left untouched so the whole room is heard), and Mic Modes… opens the macOS Voice Isolation choice. Calendar invitees and on-screen names now also guide Whisper.
- **Claude beside every meeting**: open the Claude panel on a past meeting and say what the minutes missed or got wrong ("Pak Aji owns the VA check, due Friday"); it updates the topics and action items, keeps every topic you did not ask to change, and Undo puts the last change back. You can also ask questions about the meeting. Uses Claude Sonnet when Claude is the engine.
- **Claude API as the writing engine** (Settings > AI engine, optional). Minutes, fact-checks, name fixes, tidy-ups and "Ask" can use Claude (Opus 5.5, Sonnet 5.5 or Haiku 5.5) instead of the model on this Mac, so a small or busy Mac doesn't have to run one. The key is kept in the Keychain, "Test Connection" checks it, and if Claude can't be reached Minute falls back to the model on this Mac when there is one. Speech recognition and audio stay on this Mac.
- **"My Claude login" option**: use the Claude Code already signed in on your Mac (your own Claude plan) instead of an API key, so there is no separate bill; meetings count against the plan's usage limits.

### Fixed
- Choosing "Claude API key" without saving a key no longer fails the minutes: Minute uses your Claude login (Claude Code), or the model on this Mac, instead. Any Claude failure mid-run (signed out, no key, offline) now falls back to the model on this Mac when it is installed.
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
