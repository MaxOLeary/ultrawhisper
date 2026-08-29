# UltraWhisper

Ultra Whisper: push-to-talk dictation for macOS that runs entirely on your Mac. Hold a hotkey,
talk, let go: ffmpeg records your mic, whisper.cpp transcribes it, the text gets
pasted into whatever has focus, and your old clipboard comes right back.
No accounts, no telemetry, no cloud (unless you opt into cleanup mode).

It lives next to Superwhisper without touching it; different hotkeys, no shared
settings.

## Hotkeys (default)

| Press                 | Does                                                       |
|------------------------|------------------------------------------------------------|
| `Cmd + Opt + Space`    | Press to start recording, press again to stop and paste (Esc cancels) |
| `Cmd + Opt + Shift + Space` | Same, but runs the text through an LLM to fix punctuation and drop filler words first (needs a key in `.env`; otherwise it's a plain paste) |

Change them in `~/.config/ultrawhisper/config.json` (`recordHotkey`, `cleanupHotkey`).
Modifier-only chords work too, e.g. `"ralt"` = tap right Option. Pick
"Reload Config" from the menu after editing.

Heads up: macOS binds `Cmd+Opt+Space` to "Show Finder search window" by
default. UltraWhisper swallows the keypress so Finder shouldn't pop, but if it does,
turn that shortcut off in System Settings > Keyboard > Keyboard Shortcuts >
Spotlight.

## Install

```sh
brew install ffmpeg whisper-cpp        # ffmpeg + whisper-cli
./download-model.sh                    # ~470 MB, ggml-small.en.bin
./build.sh                             # builds, signs, installs /Applications/UltraWhisper.app
open -a UltraWhisper
```

Other models: `./download-model.sh base.en` (faster, rougher) or
`medium.en` / `large-v3-turbo` (slower, better), then point `modelPath` in
`config.json` at the new file. The app also offers to download `small.en`
itself the first time you press the hotkey with no model present.

## Permissions (first run)

The first launch triggers macOS prompts. Grant both, or nothing works:

1. **Accessibility** (System Settings > Privacy & Security > Accessibility):
   lets UltraWhisper see the hotkey globally and press Cmd+V for you. The app
   opens this prompt itself; flip the switch for UltraWhisper and it picks up
   automatically within a couple seconds.
2. **Microphone**: the prompt appears the first time you hold the hotkey.
   If you launched UltraWhisper from a terminal instead of Finder/`open -a`, the
   grant gets credited to the terminal, so use `open -a UltraWhisper`.

If you rebuild, the "Postit Dev" signing cert keeps those grants intact.

## Menu bar

- Icon: gray mic = idle, red mic = recording, orange waveform = transcribing.
- Click it for the last 10 transcripts; clicking one copies it.
- Also: open the Dictation folder, open the config folder, reload config, quit.

## Where things go

- Transcripts: `~/Dictation/YYYY-MM.md`, one timestamped line each.
- Config: `~/.config/ultrawhisper/config.json` (created with defaults on first run).
- API key for cleanup mode: `~/.config/ultrawhisper/.env` (see `.env.example`).
- Audio: a temp wav that's deleted right after transcription, every time.

## Config keys

| Key | Default | Notes |
|-----|---------|-------|
| `modelPath` | `~/.config/ultrawhisper/models/ggml-small.en.bin` | any whisper.cpp ggml model |
| `audioDevice` | `"0"` | avfoundation index or name; list with `ffmpeg -f avfoundation -list_devices true -i ""` |
| `threads` | 4 | whisper threads |
| `minSeconds` | 0.35 | taps shorter than this are ignored |
| `sounds` | true | tink on start, pop on stop |
| `cleanupPrompt` | (see file) | system prompt for cleanup mode |

## Start at login

A LaunchAgent is the intended way (see `com.maxoleary.ultrawhisper.plist`):

```sh
cp com.maxoleary.ultrawhisper.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.maxoleary.ultrawhisper.plist
```

## Out of scope

Per-app presets and custom vocabulary. One good general mode.
