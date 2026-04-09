# Changelog

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
