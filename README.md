<p align="center">
  <img src="icon/icon-1024.png" width="128" alt="UltraWhisper icon">
</p>

<h1 align="center">UltraWhisper</h1>

<p align="center">Push-to-talk dictation for macOS. Everything runs on your Mac.</p>

---

Press a hotkey, talk, press it again. UltraWhisper turns your voice into text
right on your Mac — no cloud, no account, no telemetry — and your clipboard
comes back the way it was.

## Hotkeys

| Press | What happens |
|---|---|
| `⌘ ⌥ Space` | Start recording. Press again to stop and paste. |
| `⌘ ⌥ ⇧ Space` | Same, but an LLM tidies punctuation and filler words first. |
| `Esc` while recording | Asks "Discard recording?" — Return throws it away, Esc keeps going. |

Change the keys in `~/.config/ultrawhisper/config.json`, then pick
**Reload Config** from the menu bar icon.

## Install

```sh
brew install ffmpeg whisper-cpp
./download-model.sh               # main engine: Parakeet v3 (~650 MB)
./download-model.sh base.en       # small fallback model
./build.sh                        # installs /Applications/UltraWhisper.app
open -a UltraWhisper
```

Transcription is NVIDIA Parakeet TDT v3 running locally. If its files are
missing, the app quietly falls back to whisper.cpp.

## First run

Grant the two permissions macOS asks for: **Accessibility** (hear the hotkey,
press ⌘V for you) and **Microphone**. Always launch with `open -a UltraWhisper`
or from Finder — launched from a terminal, the mic permission lands on the
terminal instead.

## Where things go

| Thing | Where |
|---|---|
| Transcripts | `~/Dictation/YYYY-MM.md`, one line per take |
| Settings | `~/.config/ultrawhisper/config.json` |
| Cleanup-mode LLM | `~/.config/ultrawhisper/.env` — local Ollama or xAI Grok |
| Audio | a temp file, deleted as soon as transcription finishes |

The menu bar icon keeps your last 10 takes — click one to copy it.

## Start at login

```sh
cp com.maxoleary.ultrawhisper.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.maxoleary.ultrawhisper.plist
```
