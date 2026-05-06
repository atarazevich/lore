# Changelog

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
