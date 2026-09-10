# lore

lore is voice input for people who drive coding agents. Hold fn, speak, release: the text lands at your cursor. macOS, on-device transcription.

## Install

Download the DMG from <https://updates.dev.cognition.design/download/Lore.dmg> and drag lore to Applications.

Or build it yourself:

```bash
cd app && ./build.sh
```

Requires Xcode and an Apple Development certificate — see [docs/distribution.md](docs/distribution.md).

## Privacy

Transcription runs on your Mac. Text leaves it only when you ask: the English rewrite and the meeting cleanup go to OpenAI with your own key; Read aloud sends the selected text to Speechify with your key; a problem report goes to our server only when you press Send, exactly as previewed. The app checks for updates at launch and every six hours (Settings switch) and downloads its speech model once from Hugging Face. No account, no analytics, no cookies. Everything is stored in `~/Library/Application Support/Lore`. Long form: [docs/legal/privacy.html](docs/legal/privacy.html).

## Recording other people

Recording a conversation is on you: many places require everyone's consent first, and lore leaves that (and the law) in your hands.

## Project layout

| Folder | What's there |
|--------|--------------|
| `app/` | The macOS app — Swift/SwiftUI, build and release scripts |
| `docs/` | Feature specs, design boards, decisions, distribution and legal |
| `experiments/` | Benchmarks and transcription research harnesses |

## License

MIT — see [LICENSE](LICENSE). Third-party notices are in [THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt). The speech model is NVIDIA Parakeet TDT 0.6B v3, licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
