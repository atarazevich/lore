# Voice

Personal voice intelligence app — transcription, meeting notes, dictation, and life recording.

## Three Modes

### 1. Meeting Notes
Real-time transcription of online calls with two-stream separation (mic + system audio). Live suggestions, fact-checking, and post-meeting summaries. Replaces Granola.

### 2. Dictation
Fast voice-to-text with hotkeys. Text goes directly into active input field or clipboard. Replaces Aqua Voice / WhisprFlow.

### 3. Life Recording
Long-form offline recordings — personal diary, conversations, voice memos. Speaker diarization to separate voices. Inputs from multiple sources: OMI device, phone, Telegram, direct recording. Replaces VoiceBox.

## Tech Stack

- **App**: Lore — Swift/SwiftUI (originally forked from [OpenOats](https://github.com/yazinsai/OpenOats))
- **Local transcription**: Parakeet TDT v3 via FluidAudio (Apple Neural Engine, ~90x realtime)
- **Cleanup**: GPT-5.4-mini post-processing for punctuation and term correction
- **Diarization**: FluidAudio (Pyannote-based offline + LS-EEND streaming) — not yet tested
- **Backend**: Python (planned — API endpoints for OMI, Telegram, batch processing)
- **API fallback**: OpenAI gpt-4o-transcribe for when local isn't available

## Performance (Benchmarked)

| Pipeline | Speed | Quality | Cost |
|----------|-------|---------|------|
| Parakeet v3 + GPT-5.3 cleanup | ~90x realtime transcription + 2-10s cleanup | Excellent (0.95+ semantic similarity to API) | ~$0.003/file |
| gpt-4o-transcribe + GPT-5.3 cleanup | ~5x realtime | Slightly higher on long files | ~$0.04/file |
| Parakeet v3 raw (no cleanup) | ~90x realtime | Good for short segments, degrades on long | Free |

## Project Structure

```
voice/
├── app/                    # Lore — Swift/SwiftUI app
├── backend/                # Python backend (planned)
├── scripts/                # Standalone utility scripts
├── experiments/
│   ├── benchmarks/         # Benchmark scripts and golden standards
│   ├── fluid-test/         # FluidAudio/Parakeet test harness
│   └── results/            # Experiment output data
└── docs/
    └── decisions.md        # Architecture and product decisions
```
