<p align="center">
  <img src="icon/icon-1024.png" width="128" alt="UltraWhisper icon">
</p>

<h1 align="center">UltraWhisper</h1>

<p align="center">Push-to-talk dictation for macOS. Everything runs on your Mac.</p>

---

Press a hotkey, talk, press it again. UltraWhisper turns your voice into text
on this Mac - no cloud, no account, no telemetry - and your clipboard comes
back the way it was.

## Hotkeys

| Press | What happens |
|---|---|
| `⌘ ⌥ Space` | Start recording. Press again to stop and paste. |
| `⌘ ⌥ ⇧ Space` | Same, but an LLM tidies punctuation and filler words first. |
| `Esc` while recording | Asks "Discard recording?" - Return throws it away, Esc keeps going. |

Change the keys in `~/.config/ultrawhisper/config.json`, then pick
**Reload Config** from the menu bar icon.

## Install

Needs the Xcode command line tools (`swiftc`). No Homebrew.

```sh
./build.sh                        # installs /Applications/UltraWhisper.app
open -a UltraWhisper              # first launch downloads Parakeet CoreML
```

Transcription is NVIDIA Parakeet TDT v3 running locally through FluidAudio on
the Apple Neural Engine. Audio stays in RAM and is never written to disk. If
Parakeet is not ready, the app can fall back to whisper.cpp
(`brew install whisper-cpp` and `./download-model.sh base.en`).

## First run

Grant the two permissions macOS asks for: **Accessibility** (hear the hotkey,
press ⌘V for you) and **Microphone**. Always launch with `open -a UltraWhisper`
or from Finder - launched from a terminal, the mic permission lands on the
terminal instead.

## Where things go

| Thing | Where |
|---|---|
| Transcripts | `~/Dictation/YYYY-MM.md`, one line per take |
| Settings | `~/.config/ultrawhisper/config.json` |
| Cleanup-mode LLM | `~/.config/ultrawhisper/.env` - local Ollama or xAI Grok |
| Vocabulary | `~/.config/ultrawhisper/vocabulary.txt` - words Parakeet should favor (off by default) |
| Replacements | `~/.config/ultrawhisper/replacements.txt` - `heard -> wanted`, whole words |

Replacements take effect after **Reload Config**. They are plain find-and-replace,
case-insensitive on the left, exact on the right, so `vortex cfd -> VortexCFD`
does not need an LLM. `vocabulary.txt` is unused for now.

The menu bar icon keeps your last 10 takes - click one to copy it.

## Start at login

```sh
cp com.maxoleary.ultrawhisper.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.maxoleary.ultrawhisper.plist
```
