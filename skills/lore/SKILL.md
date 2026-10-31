---
name: lore
description: Use the `lore` command on a Mac where the lore app is installed to find and read what the user already said (dictations and meetings), pick up the dictations they marked for later, transcribe an audio file on this Mac, or read a reply aloud. Use it when the user refers to something they dictated or discussed in a meeting ("what did I say about…", "the call with…", "my last dictation"), asks you to pick up their marks, hands you an audio file, or asks to hear a reply.
---

# lore

`lore` is the command of the lore app: voice dictation and meeting notes for
macOS. Everything stays on this Mac. `search`, `show` and `marks` read lore's
files and work with the app closed; `marks take` writes one line, the record
that you took a mark, and nothing else.

## Find what the user said: `search`

```
lore search <words> [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--dictations|--meetings] [--marked] [--limit N] [--json]
```

Every word must appear, in any case. Newest first, 20 hits unless `--limit`
says otherwise (`--limit 0` for all). `--until` includes that day. Words are
optional: `lore search --since 2026-10-01 --meetings` lists the meetings since then.

```
$ lore search pricing deck --since 2026-09-01
2026-09-29 16:18  meeting    session_2026-09-29_16-18-22  Pricing review: …send the pricing deck to the team by Friday…
2026-09-12 10:04  dictation  3F2A9C1E-5B7D-4E21-9A0C-6D8E2F1B4C77  Remind me to update the pricing deck before…
```

Use `--json` when you will parse the result: an array of
`{"kind", "id", "date", "title", "snippet"}`, `title` for meetings only.
`--marked` keeps only the dictations marked for later that no agent has taken
yet (below).

## Read it: `show`

```
lore show <id|latest> [--notes] [--raw]
```

`id` is the third column of `search`; `latest` is the newest dictation or
meeting. A dictation prints its text. A meeting prints its title, its time and
its transcript, one paragraph per line as `[HH:mm:ss] Name: text`, with the
speaker names the user gave. `--notes` adds the meeting's notes. `--raw` prints
the words as transcribed, before cleanup.

```
$ lore show latest
$ lore show session_2026-09-29_16-18-22 --notes
```

Search first, then show the hit you need. Quote what the user said rather than
paraphrasing it.

## Pick up what the user marked: `marks`

```
lore marks [--json]
lore marks take <id> --by <your name>
```

The user marks a dictation "for later" with K while dictating, or from its row
in history, when it is context an agent should act on later. `lore marks` lists
the marks no agent has taken yet, newest first, in `search`'s columns. A mark
is listed the moment its dictation is in history, before its words are in:
`--json` adds `markedAt`, `status` (`ready`, `transcribing` or `failed`),
`text` when there are words, and `audio`, the recording's path, while it is
kept.

When you act on a mark, sign for it with `lore marks take <id> --by <name>`,
using a short name the user will recognise (`launch-team`). The dictation's
row then reads "Taken by <name> · <time>" and it leaves `lore marks`. Every
take is recorded: if another agent took it first, the command says who and
still records yours. A mark still being transcribed can't be taken yet (exit
75); take it once its words are in. Marks never expire, and the user may mark
a taken dictation again, which lists it again.

```
$ lore marks
2026-10-27 14:02  dictation  3F2A9C1E-5B7D-4E21-9A0C-6D8E2F1B4C77  This is good context for the iPad work…
$ lore show 3F2A9C1E-5B7D-4E21-9A0C-6D8E2F1B4C77
$ lore marks take 3F2A9C1E-5B7D-4E21-9A0C-6D8E2F1B4C77 --by launch-team
Taken by launch-team.
```

## Transcribe a file: `transcribe`

```
lore transcribe <audio file>
```

Prints the transcript of an audio file (m4a, wav, mp3, a Voice Memos
recording) with lore's on-device speech model. Nothing is saved. Opens lore if
it is closed.

## Speak a reply: `say`

```
lore say "<text>"
echo "<text>" | lore say
```

Reads the text aloud through lore, queued after other agents' replies and
announced by this chat's name. Use it only when the user asked to hear
replies, and keep it to a sentence or two. It always exits 0, and speaks with
macOS `say` when lore is not running.

## `lore` not found

The app links `lore` into `/opt/homebrew/bin`, `/usr/local/bin` or
`~/.local/bin` when it starts. If the command is missing, ask the user to open
lore once.
