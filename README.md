<p align="center">
  <img src="icon/icon-1024.png" width="128" alt="UltraWhisper icon">
</p>

<h1 align="center">UltraWhisper</h1>

<p align="center">Push-to-talk dictation for macOS. Everything runs on your Mac.</p>

---

Press a hotkey, talk, press it again. UltraWhisper records your voice, turns it
into text right on your Mac — no cloud, no account, no telemetry — types it
into whatever you were doing, and puts your clipboard back the way it was.

While you talk, a small floating card shows your voice as a live waveform.
When you stop, it shows the text it heard, then fades away.

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
brew install ffmpeg whisper-cpp   # recorder + fallback engine
./download-model.sh               # main engine: Parakeet v3 (~650 MB)
./download-model.sh base.en       # small whisper fallback model
./build.sh                        # builds + installs /Applications/UltraWhisper.app
open -a UltraWhisper
```

Transcription is NVIDIA Parakeet TDT v3 running locally — more accurate than
whisper large-v3, and it answers in about a third of a second. If its files
are missing, the app quietly falls back to whisper.cpp.

## First run

macOS asks for two permissions. Grant both, or nothing works:

1. **Accessibility** — lets the app hear the hotkey anywhere and press ⌘V for you.
2. **Microphone** — appears the first time you record.

Always launch with `open -a UltraWhisper` (or from Finder). Run the binary
straight from a terminal and macOS hands the mic permission to the terminal
instead of the app.

## Where things go

| Thing | Where |
|---|---|
| Transcripts | `~/Dictation/YYYY-MM.md`, one line per take, owner-only files |
| Settings | `~/.config/ultrawhisper/config.json` |
| Cleanup-mode LLM | `~/.config/ultrawhisper/.env` — local Ollama or xAI Grok, never OpenAI/Google/Anthropic |
| Audio | a temp file, deleted the moment transcription finishes |

The menu bar icon keeps your last 10 takes — click one to copy it.

## Start at login

```sh
cp com.maxoleary.ultrawhisper.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.maxoleary.ultrawhisper.plist
```

---

Lives next to [Debrief](https://github.com/MaxOLeary/debrief), the local
meeting-notes app — same rule everywhere: your voice never leaves your Mac.
