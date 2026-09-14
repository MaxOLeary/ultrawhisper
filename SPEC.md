# Whisper speed

Goal:
Tap Option+Space, talk, tap Option+Space again, and the text pastes with no wait that grows with how long you spoke. Two words and a few sentences should feel the same. Superwhisper-class stop-to-paste, still fully local Parakeet.

Out of scope:
- Hold-to-talk, Fn, or key-release-to-paste. Record hotkey is tap to start, tap again to stop and paste.
- Live words on the card (later, after paste is fast)
- Parakeet EOU 120M as the default model (worse accuracy than TDT)
- Cloud STT, LLM cleanup changes, vocabulary/hotwords work
- Sherpa thread-count, wav I/O, or other side-path cuts sold as the speed fix
- **sherpa-onnx / k2-fsa is banned** (PRC origin). Do not keep it as engine or fallback. Replacement is FluidAudio (Fluid Inference, US) running NVIDIA Parakeet TDT on Apple Neural Engine.

Architecture (short):
In-process FluidAudio CoreML (NVIDIA Parakeet TDT v3 on the Apple Neural Engine). Capture grows a live sample stream. A serial segmenter on `whisper.work` closes a chunk on ~2s of trailing silence or a 15s cap and decodes that slice while talking. Second Option+Space finishes the tail, pastes via clipboard + Cmd+V, then `Thread.sleep(0.35)` restores the clipboard. SwiftPM build. No sherpa, no websocket, no Proxy.swift.

Hotkey: tap `recordHotkey` starts, tap again stops and pastes. Do not rewrite `~/.config/whisper/config.json`. Change `Config.defaults.recordHotkey` to `alt+space` for new installs only. Cleanup chord stays as it is. Esc while recording closes the card immediately (no confirm), still transcribes and saves, does not paste.

Stages:
- [x] 1. Decode while talking. Capture grows a live sample stream. A serial segmenter on `whisper.work` closes a chunk on ~2s of trailing silence (with a voiced-audio minimum so noise does not fire) or a 15s cap, whichever first, and decodes that slice. Join segment texts with spaces. Second Option+Space closes the tail (drop a trailing unvoiced bit shorter than ~250ms), waits for the in-flight queue, pastes the joined text, hides the card. If any segment throws or returns empty when the audio was voiced, fall back once to a full-buffer `transcribe(samples)` so a take is never lost. Esc discard still drops the take and cancels queued work.
- [ ] 2. Paste without blocking 350ms. `paste(_:)` still snapshots the clipboard, writes the transcript, posts Cmd+V. Restore the old clipboard on a later timer (start at 350ms, not on the transcription thread). Do not `Thread.sleep` in `paste`. Two-word takes must not wait on restore before the user can type.
- [x] 3. In-process FluidAudio CoreML (Parakeet TDT, Apple Neural Engine). Drop the sherpa websocket server, `Proxy.swift` loopback, and `sandbox-exec`. Same tap-toggle, same segmenter. `build.sh` becomes SwiftPM (or an equivalent that still produces `/Applications/Whisper.app` signed with "Postit Dev"). Whisper fallback stays for when Parakeet files are missing.

Verification (how we will know each stage worked):
- 1. Two-word take still pastes fast. A 4–5 sentence take pastes in well under a second after the second Option+Space. Log shows most decode ms overlapped the recording. Esc discard still works. Failed segment still pastes via full-buffer fallback. No FluidAudio in the binary.
- 2. Text is in the focused app before clipboard restore. Previous clipboard contents come back. No 350ms stall after paste.
- 3. Same Option+Space UX. `asr=` on a short take is lower than sherpa. `pgrep` shows no `sherpa-onnx-offline-websocket-server` while the app is running.

Current stage: 2
