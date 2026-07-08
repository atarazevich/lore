# Changelog

## v2.1.0 — 2026-07-08

Diagnostics: the app can now see and report its own health, so a problem on a machine we can't reach becomes something the user can show us in one click. The version line also moves to 2.x.

**See what's wrong, and fix it**
- A health panel (sidebar footer → click) shows the readiness chain — permissions, the Fn key listener, microphone, model, key, meetings — each failing item with a specific remedy and buttons that perform it. Cheap checks re-run on open; expensive ones (mic, model warm-up, OpenAI liveness) show the last real result behind an explicit "Test now" (#83)
- A failing critical check summons itself through the notch prompt instead of waiting to be found; when the Fn key is starved by another app holding secure input, the panel names that app rather than blaming a permission (#83)

**Report a problem**
- "Report a problem" (in the health panel and Settings) sends a short note plus a health snapshot and recent diagnostics to us — with a two-tab preview showing the exact bytes that will leave the machine. No transcripts, recordings, file names, device names, account, or keys, guaranteed by construction (#84)

**Privacy of the diagnostic log itself**
- Replaced the old world-readable `/tmp/lore.log` — which carried dictated text, meeting utterances, and device names — with a typed event stream where personal data cannot fit by construction, plus OS-redacted developer logging. The insecure log file is gone (#82)

**Under the hood**
- The backend a user hits first is warmed at launch; the version now separates the human-facing number from the build identity Sparkle uses to order updates (#81, #85)

## v1.18.0 — 2026-07-07

XMO Stage 1 — the whole app redesigned into one window, plus a rebuilt meeting-detection stack. Large early-adoption release: every feature has landed and been reviewed; polish continues from here.

**New shape**
- Single dark window with a sidebar (Dictation · Meetings · Settings), a design-token system, and Ask Lore — a chat over the live meeting transcript, persisted per meeting and shown read-only in review (#44, #60, #62)
- Meetings: live banner + transcript + stats rail; review with list rail, transcript/chat tabs, in-header rename, readable default names + duration, and timestamps relative to recording start (#57, #58, #61, #63)
- The entire shell header strip is draggable (#71); product name is now Lore (XMO dropped from user-facing strings)

**Meeting auto-detection, rebuilt**
- Detects mic activation by meeting apps (Zoom, Meet, Teams, FaceTime, …) and offers to transcribe via a notch-anchored, Dynamic-Island-style prompt that shows even over fullscreen apps, with a floating-pill fallback on Macs without a notch (#79)
- Fixed detection going deaf after a Bluetooth device reconnects (AirPods A2DP→HFP), a ghost-detector leak on every toggle, and false prompts during your own dictation; full [DETECT] logging for visibility (#75, #76, #77, #78)

**Focus: one model, fewer dead features**
- Parakeet v3 only — model pickers, WhisperKit, and the vocabulary-learning track removed (#53)
- Purged the dead LLM stack (embeddings, NotesEngine) and collapsed cleanup/refinement to OpenAI only; local Ollama/MLX provider options removed (#70, #74)
- Removed live diarization, the no-op echo-cancellation toggle, Suggestions, the transcript pop-out window, and Dictation-master/Auto-submit settings (#54, #55, #56)
- Configurable dictation-audio retention; dictation history rewritten for scale — honest counts, smooth scroll, per-entry storage (#51, #52)

**Reliability**
- Fixed a CoreAudio HAL deadlock on quick stop→start, bus-level mic mute silencing the whole app, the lore:// deep link not starting recordings, ghost recordings from a lifecycle race, and split-brain launch states (#64, #66, #65)
- Deterministic mic mute for dictating over a muted meeting; echo filter now catches short verbatim duplicates; imports never silently delete a session — a failure keeps the row with a retry (#66, #59, #43)
- OpenAI key health check in Settings with visible cleanup/translate failures (#50)

Signed with the free Apple Development account (paid enrollment pending). Sparkle updates install in place; a brand-new install may need right-click → Open once.

## v1.17.0 — 2026-06-09

Deterministic mic selection — no more mid-recording device switching.

- Input device is picked once at recording start via a transport allowlist: built-in and wired mics are used as-is; any wireless input (AirPods, iPhone/Continuity, Bluetooth) redirects to the built-in mic, verified by device UID. The device stays pinned for the entire recording (#39, D-030)
- Fixes empty transcriptions caused by a phantom Continuity device being pinned as "built-in mic" (stale persisted device id + transport-only matching) and the resulting device ping-pong between recordings
- Removed the silent-mic watchdog, the dictation zero-signal fallback walker, and the follow-system-default listener; a dead mic now shows a "No signal from microphone" warning instead of hopping devices
- FluidAudio bumped 0.14.4 → 0.15.2 in app and benchmark tool (#38)

## v1.16.0 — 2026-05-07

Major audio-stack rewrite and Parakeet upgrade.

- AudioBus rewritten on CoreAudio HAL IOProc — silent-mic Bluetooth fallback (AirPods route to built-in mic), settling-delay reconfigure for hardware route changes, supersedes the AVAudioEngine path that drove the v1.15.x crash hotfixes (#31, D-029)
- FluidAudio bumped 0.13.2 → 0.14.4: Cyrillic emission bug fix in Parakeet TDT v3, 2.2-2.8x speedup on long audio via parallel chunk processing, 300ms minimum utterance length (improves short dictation), int4 encoder (#35)
- Vocabulary boosting removed: FluidAudio v0.14 dropped `configureVocabularyBoosting` from the offline `AsrManager`; live decode no longer biases toward mined terms. The `transcriptionCustomVocabulary` setting and word-correction history are unchanged. Re-introducing boost via `SlidingWindowAsrManager` is tracked separately (#34)
- Release script hardened: pre-flight CHANGELOG check, atomic post-release tagging + Info.plist bump

## v1.15.2 — 2026-04-09

Hotfix: AudioBus infinite restart loop from startup config change transients.

- Fix: `engine.start()` and tap installation fire spurious `AVAudioEngineConfigurationChange` notifications. Since each restart succeeded, the failure counter reset to 0, creating an infinite loop (~1 cycle/sec) that caused the mic indicator to blink and eventual crashes. Added 1.5s post-start cooldown to suppress transient config changes.

## v1.15.1 — 2026-04-09

Hotfix: AudioBus crash on Bluetooth device transitions.

- Fix: `handleConfigChange()` used `engine.reset()` then reinstalled the tap — input node in transient state during AirPods connect/disconnect caused ObjC NSException (SIGABRT). Replaced with full teardown + fresh engine; added ObjC exception catcher as safety net.

## v1.15.0 — 2026-04-06

Major release: word correction, audio stability, new icon.

- Word correction in history with automatic vocabulary learning (#28)
- AudioBus crash fix: remove CoreAudio device listener that caused dual restart paths (#27)
- Shared Parakeet backend cache for dictation + meeting (#22)
- Bluetooth mic redirect no longer mutates system default (#21)
- Echo suppression tuning for multilingual speech (#26)
- Audio engine lifecycle: restart in place on config change (#24)
- Parakeet model preload at launch for instant first dictation
- New app icon (blue spiral waveform)

## v1.13.0 — 2026-03-24

First feature-complete release with meeting mode.

- Meeting transcription with sliding window overlap
- Dictation with Fn hold-to-talk and Space lock
- GPT cleanup (Clean/Concise/Custom presets)
- Floating dictation indicator with C/T upgrade buttons
- History with inline editing
- Onboarding flow for permissions and Fn key setup
