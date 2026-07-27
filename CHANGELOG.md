# Changelog

## v2.6.0 — 2026-07-27

Lore learns to speak: Read Aloud turns any selected text into speech, in the language it's written in. Plus a dictation pipeline fix.

**Read Aloud — select text anywhere, listen (#105)**
- Select text in any app and press Fn+R — Lore reads it aloud. Fn+Q adds texts to a listening queue instead
- Works out of the box for free with the built-in system voices; entering a Speechify API key (Settings → Read aloud) unlocks 950+ natural voices, including ~50 native Russian ones
- The voice follows the text's language: Russian text is read by your Russian voice, English by your English one — detected automatically, configurable per language with in-place previews
- A floating mini-player controls it all: pause, restart, skip to next, 0.5x–3x speed (pitch-preserved and free — the audio is never re-synthesized), and an expandable queue with drag-to-reorder, play-now, and remove
- Long reads start within ~2 seconds and keep streaming while you listen; a configurable length limit (default 20,000 characters) stops an accidental 50-page selection before it costs anything
- Reading and dictation never fight over your audio: holding Fn pauses the reading before the microphone opens, and an accidental short tap resumes it automatically

**Nothing selected? It reads your clipboard (#106)**
- Fn+R with no selection speaks the last thing you copied; the panel marks the source as "clipboard" so a stale clipboard never plays as a mystery

**A new dictation no longer kills the previous transcription (#104)**
- Pressing Fn while the previous dictation was still transcribing used to abort that transcription and lose the text. The pipeline now finishes in the background — both dictations arrive

## v2.5.0 — 2026-07-25

Six fixes from the field: reliability retries, an "Ignore" button that actually ignored nothing, a Space that could leak into your document, and the last honesty gaps in the secure-input diagnostics.

**Flaky network no longer costs you a dictation**
- A transient failure — a timeout, a dropped connection, a momentary 5xx from OpenAI — used to fail the whole dictation on the first try. Transcription now retries each failed chunk up to 3 times, and cleanup/translation retries up to 3 times with a short backoff, but only on errors that retrying can actually fix. A real error (bad key, no quota) still fails immediately and honestly (#103)

**"Ignore this app" now works for apps we don't recognize**
- When a meeting was detected by microphone signal alone — GeForce NOW, a game, any app not on the known meeting-app list — the prompt showed no app name and "Ignore this app" silently did nothing, so the same prompt came back every time. The detection is now attributed to the app in front of you: the prompt names it, and Ignore actually persists (#101)
- A related race: if the microphone flickered between the prompt appearing and you clicking, the buttons could act on a *different* app than the one the prompt named. All three buttons now act on exactly what you saw (#102)

**Space could type a space while locking the recording**
- Pressing Space to lock a recording while another app was focused could both lock *and* type a space into that app, because a second listener that cannot swallow keystrokes was also watching Space. That listener now watches only Ctrl+Cmd+V (re-paste), its one real job; Space is handled solely by the mechanism that can consume it (#95)

**The health panel stops guessing**
- macOS sometimes blames the lock screen for holding secure input when the real holder is some background process — an Apple bug. The panel no longer repeats that wrong name. At the lock screen, secure input is simply normal. Unlocked with no honest name available, it says so and gives the procedure that actually finds the culprit: quit apps one at a time and watch the panel clear (#98)
- Under secure input the shortcut-starvation check physically cannot measure anything — and used to render that as a green "healthy". "No verdict" now looks different from "measured healthy", because confusing the two is what fooled us during the July investigation (#99)

## v2.4.0 — 2026-07-16

v2.3.0 stopped the app blaming the Fn key **when secure input was the cause**. It turned out there are two causes, and the other one still produced the same lie. This finishes it, and puts the diagnostic in the app instead of a terminal.

**The check called "Fn key" could never see the Fn key**
- It has been named "Fn key" since v2.1.0 and it never watched the Fn key at all. Fn hold-to-talk runs on a completely separate mechanism; the check watches the part that carries Space, Esc and the upgrade keys **while another app is focused**. So a real failure of that part — Space stops locking outside the app — got reported as "Fn key not working" while Fn kept working perfectly. The user was right and the app was wrong. It's now called **Keyboard shortcuts**, which is what it actually watches (#97)

**And it wasn't measuring what it claimed either**
- The check timed how long *the Fn key listener* had been quiet and reported that as the state of the shortcut listener. Those are two different things that happen to fail together — so it was watching a second victim and calling it a diagnosis. Worse, pressing Fn reset its timer, meaning **your working Fn key was actively reassuring a check about a part that was broken.** It now times the shortcut listener itself, against whether the Mac is receiving keystrokes at all. That comparison is the only thing that can tell "we're not getting keys" from "you stopped typing for 30 seconds" — and confusing those two is what produced the phantom warnings that came and went (#97)

**The app now tells you which of the two it is, and what actually fixes it**
- When shortcuts are dead, the panel shows what it measured — whether the app is receiving keystrokes, whether the Mac is — and names the cause. Secure input on: another process has locked the keyboard system-wide, and restarting Lore won't help. Secure input off: macOS says the permissions are granted while the app receives nothing, which is a stale grant. In that case **removing Lore's entry from Accessibility and Input Monitoring entirely and adding it back is what clears it — flipping the switch off and on is not the same thing and does not work** (#97)
- Both permission checks read APIs that are known to report granted when they aren't. The app no longer takes their word for it over the evidence of its own listener (#97)

## v2.3.0 — 2026-07-16

When macOS locks the keyboard, the app now says so — and names what did it. v2.1.0 promised this and never delivered it once.

**"Fn key not working" was a lie, and the truth was buried**
- When another process turns on macOS Secure Input, no app receives keystrokes — not Lore, not Raycast, not anything. Fn hold-to-talk keeps working (it rides a different kind of event), so the failure looks like "Space and the upgrade keys are broken" rather than "the keyboard is locked". The app used to respond by flashing **"Fn key not working"** while the health panel simultaneously showed the Fn key as healthy — because the stall detector's verdict depended on whether you'd paused typing for 30 seconds, not on anything about the Fn key. The banner now names the real condition: **"Secure input is on — no app is receiving keys"**, and says restarting Lore won't help, because it won't (#94)
- The health panel and the banner can no longer contradict each other, and the report's "What this means" tab no longer blames the Fn key either (#94)

**Naming the culprit — the feature v2.1.0 said it shipped**
- v2.1.0's changelog claimed "the panel names that app rather than blaming a permission". It never did, on any machine. The lookup read the holder's process ID from the wrong place in the system registry — a level above where macOS actually stores it — so it came back empty every single time, on every version of macOS, since the day it shipped. It now reads the right place and names the holder (#92)
- The process ID macOS reports can point at the wrong app — an Apple bug open since 2019, which we reproduced twice during this fix, once with it blaming Lore for starving Lore's own keyboard. So the app presents the holder as a lead to check, not an accusation. When the holder has no app name (a background daemon), it shows the process ID rather than staying silent (#92)

**The diagnostic that never fired**
- Secure input turning on or off was supposed to be recorded in the event stream since v2.1.0. It never was — not once, on any machine, because it was gated behind the broken lookup above. A problem report therefore couldn't distinguish "the keyboard has been locked for four hours" from "it locked ten seconds ago". It records now, so the next report answers when it started and how long it lasted (#93)

## v2.2.0 — 2026-07-09

Polish and a privacy cleanup on top of the diagnostics release.

**No more notification prompts**
- Removed Notification Center entirely — the macOS "Lore would like to send notifications" permission prompt no longer appears on any machine. Meeting detection prompts through the notch (the Dynamic-Island-style prompt from v2.1.0) with Start transcribing / Not a meeting / Ignore this app (#80)

**Clearer Keep audio setting**
- The "Keep audio" row now states present reality — how many recordings are on disk right now and the space they use — instead of a number that read like a projection of what the retention cap would eventually hold (#89)

**Health panel polish** (shipped in v2.1.0's line, refined here)
- "Test now" shows a spinner while it runs and updates the result; the dead system-audio "Test now" button is gone; the model warm-up wording no longer implies a 1 GB load on every check (#88)

**Menu bar**
- The menu bar popover is restyled to match the app and shows live recording state (Start/Stop, Show Lore, Check for updates, Quit) (#90)

**Better defaults & working auto-update**
- Meeting auto-capture is now ON by default (a new install starts watching for meetings); an explicit choice to turn it off is preserved (#91)
- Automatic update checks actually run now — the app checks on a schedule and does a silent check shortly after launch, so updates arrive without you asking (#91)

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
