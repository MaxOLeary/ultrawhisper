<p align="center">
  <img src="icon/icon-1024.png" width="128" alt="Whisper icon">
</p>

<h1 align="center">Whisper</h1>

<p align="center">Push-to-talk dictation for macOS. Everything runs on your Mac.</p>

---

Press a hotkey, talk, press it again. Whisper turns your voice into text
on this Mac - no cloud, no account, no telemetry - and your clipboard comes
back the way it was.

## Hotkeys

| Press | What happens |
|---|---|
| `⌘ ⌥ Space` | Start recording. Press again to stop and paste. |
| `⌘ ⌥ ⇧ Space` | Same, but an LLM tidies punctuation and filler words first. |
| `Esc` while recording | Closes the card right away and skips the paste. The take is still transcribed and saved to history and `~/Dictation`. |

Change the keys in `~/.config/whisper/config.json`, then pick
**Reload Config** from the menu bar icon.

## Install

Needs the Xcode command line tools (`swiftc`). No Homebrew.

```sh
./build.sh                        # installs /Applications/Whisper.app
open -a Whisper              # first launch downloads Parakeet CoreML
```

Transcription is NVIDIA Parakeet TDT v3 running locally through FluidAudio on
the Apple Neural Engine. Audio stays in RAM and is never written to disk. If
Parakeet is not ready, the app can fall back to whisper.cpp
(`brew install whisper-cpp` and `./download-model.sh base.en`).

## First run

Grant the two permissions macOS asks for: **Accessibility** (hear the hotkey,
press ⌘V for you) and **Microphone**. Always launch with `open -a Whisper`
or from Finder - launched from a terminal, the mic permission lands on the
terminal instead.

## Where things go

| Thing | Where |
|---|---|
| Transcripts | `~/Dictation/YYYY-MM.md`, one line per take |
| Settings | `~/.config/whisper/config.json` |
| Cleanup-mode LLM | `~/.config/whisper/.env` - local Ollama or xAI Grok |
| Vocabulary | `~/.config/whisper/vocabulary.txt` - words Parakeet should favor (off by default) |
| Replacements | `~/.config/whisper/replacements.txt` - `heard -> wanted`, whole words |

Replacements take effect after **Reload Config**. They are plain find-and-replace,
case-insensitive on the left, exact on the right, so `vortex cfd -> VortexCFD`
does not need an LLM. `vocabulary.txt` is unused for now.

The menu bar icon keeps your last 10 takes - click one to copy it.

## Start at login

```sh
cp com.maxoleary.whisper.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.maxoleary.whisper.plist
```
