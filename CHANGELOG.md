# Changelog

## v3.11.0 — 2026-11-01

**3.10.5 (#346) Paste again pastes your last words**
- Control-Command-V now pastes your most recent words, skipping a take that came back empty, and waits until you let go of Control so terminals like Ghostty read it as a paste

**3.10.4 (#347) Tests never read an earlier run's diagnostics**
- The test run's diagnostic store now starts empty and sweeps the folders of finished runs, so a reused process id can no longer make a trace-counting test see an earlier run's events and fail.

**3.10.3 (#346) lore's shortcuts work while another app holds secure input**
- Control-Command-V, Read aloud's fn R and fn Q, and the agent reply keys now work while a password field, Terminal's Secure Keyboard Entry or the lock screen holds secure input; when it is off, they work exactly as before
- The health panel's Keyboard shortcuts row now shows only for a key that still can't work then: a recorded talk key like F13, or a shortcut another app already uses

**3.10.2 (#345) A relaunch no longer downloads the speech model again**
- Some relaunches waited 35–48 s before dictation worked: another process loading the speech model had asked for a different version of it and replaced the copy on disk, so the next launch downloaded and compiled it again. Every load now asks for the same model version, and a relaunch loads the model already on disk in about a second

**3.10.1 (#342) Recording shortcuts work while another app holds secure input**
- During a recording, Space, the talk key + Space, Esc and the fn letters are registered as system shortcuts, only the ones the recording uses at that moment, and released when it ends. A password field, Terminal's Secure Keyboard Entry or the lock screen no longer stops them
- The health panel's Keyboard shortcuts row now names only what still stops under secure input: the Read aloud shortcuts, or the agent reply shortcuts with agent replies on. The bubble's lock, pause and cleanup tips show as usual again

## v3.10.0 — 2026-10-31

**3.9.1 (#343) Holding Right Option to talk records again**
- On some Macs, holding Right Option turned the microphone on but never showed the bubble or pasted: lore took every press for a tap. A held talk key now always records, whatever the system's key state says

## v3.9.0 — 2026-10-31

**3.8.46 (#341) The health panel says which app turned lore's shortcuts off**
- When another app holds secure input, the Keyboard shortcuts row says the shortcuts are off, names the app that probably caused it, and says how to turn it off: a password field, Terminal's or iTerm2's Secure Keyboard Entry, or the lock screen. It is amber, not red, and clears itself when secure input goes off
- The bubble holds back its lock, pause and cleanup tips while secure input is on

**3.8.45 (#324) Mark a dictation for later, and agents pick it up**
- Press K while dictating, or Mark for later on a history row, to keep a dictation for an agent. The row reads "Marked for later" until an agent takes it, then "Taken by <agent> · <time>"; Unmark takes the mark off
- Agents list the marks with `lore marks`, with lore open or closed, and sign for one with `lore marks take <id> --by <name>`; `lore search --marked` finds them too
- K no longer sends a dictation to the operator, and its Settings switch is gone

**3.8.44 (#338) lore says when macOS is blocking its shortcuts and paste**
- After a reinstall macOS can keep an old permission, so the switches look on while lore's shortcuts do nothing and its pastes are dropped. lore now says so at once in the menu bar, and Fix permissions clears lore's old entries and asks again
- A paste macOS dropped no longer counts as ok: the bubble says to press Cmd+V, and the words stay on the clipboard

**3.8.43 (#329) A muted iPad microphone shows in the note**
- A phone note from an iPad whose microphone was cut, for example by closing its cover, now shows that stretch on the Mac as "Microphone off" with its times

**3.8.42 (#315) The iPhone can find its pinned models' folders**
- Plumbing for the iPhone app, nothing changes on the Mac: lore's shared code now tells the iPhone where each pinned model is downloaded, so it can check which version is there

**3.8.41 (#311) The iPhone traces its Watch remote**
- The iPhone now records each command the Watch sends its recorder (start, pause, resume or stop) and what became of it: done, waiting for lore to open, refused, or meant for a different recording; and when the Watch comes into reach or goes out of it

**3.8.40 (#336) Restart lore opens lore again**
- Restart lore, offered in the health panel and during setup, now quits and opens lore again; before, it quit and lore stayed closed

**3.8.39 (#193) Only one copy of lore runs at a time**
- A copy of lore started straight from its folder, as test tools do, now steps aside for the one already running instead of running beside it, so a hold of Fn is heard once

**3.8.38 (#243) Delete dictations from history**
- Hover a dictation and click the trash, or right-click it and choose Delete, to remove it with its audio and screenshots
- Right-click and choose Select Multiple… to delete several at once; Select All takes what the search shows
- Settings has a new History card with Delete All
- Every delete asks first, and the files go to the Trash; if one can't be moved, the dictation stays in history and lore says so
- A dictation still being transcribed can't be deleted until it lands
- The history count now reads "dictations" instead of "entries"

**3.8.37 (#313) The iPhone traces its Lock Screen card**
- The iPhone now records when its Lock Screen card appears, whether lore put it back, and why it went away: dismissed, ended by iOS after 8 hours, switched off in lore's settings, Live Activities turned off, or the recording stopped

**3.8.36 (#333) Meeting detection tests no longer wait on the clock**
- Nothing changes for users; meeting detection still waits five seconds before asking, and its tests now give the same result however busy the Mac is

**3.8.35 (#332) Slack huddles are recognised as Slack**
- A Slack huddle is now named Slack in the meeting prompt; lore was looking for Slack under the wrong app name
- The current Webex app and the installed Google Meet web app are recognised too; Around, which has shut down, is no longer listed

**3.8.34 (#214) Meeting detection tests no longer depend on which apps are running**
- Nothing changes for users; a test-only change so meeting detection's tests give the same result on any Mac

**3.8.33 (#185) Measured: separate speech-model copies cost a few tens of MB each**
- Nothing changes for users; the code's notes now give the measured reason the copies stay

**3.8.32 (#330) Meeting audio is never deleted before it is saved**
- "Save audio recording" is now on unless you turn it off; a missing setting no longer means off, which let some meetings lose their audio
- A meeting's recorded audio is kept until its saved recording is in your notes folder and plays back whole; if saving fails, the audio stays in the meeting and lore tries again at the next launch

**3.8.31 (#306) The iPhone traces why Resume is blocked and how a recording is written**
- The iPhone now records why a stopped recording can't resume, how long that lasted, how it ended and when retries gave up, and when a recording's audio writer stops, a new part starts or the parts are joined

**3.8.30 (#328) Meeting speakers go back to the earlier model**
- Telling speakers apart in a meeting, and in `lore transcribe --speakers`, uses the earlier model again: on real meetings it was better, inventing fewer speakers and merging fewer people into one
- If it fails on a file, lore still tries once more before giving up; the newer model's files (about 21 MB) are removed

**3.8.29 (#186) A failed model load no longer leaves other features on deleted files**
- When a meeting's speech model failed to load and lore removed its files to download them again, dictation went on using a copy that no longer matched the files on disk; now every part of lore lets that copy go, and the next dictation or meeting downloads the model once for both
- A dictation already being transcribed at that moment still finishes

**3.8.28 (#327) Spoken replies no longer stay stuck waiting after a dictation ends**
- When a dictation ended at the same moment a reply came in, lore could keep the reply waiting for the microphone until it was relaunched; it now checks again every couple of seconds and lets the reply through once the microphone is free
- A call or recording in another app still keeps replies waiting, as before

**3.8.27 (#310) iPad notes say when the closed cover muted the microphone**
- When closing an iPad's cover cuts its microphone mid-note, the note's transcript now shows "Cover closed" and the time it lasted, instead of a bare "Paused"

**3.8.26 (#328) Meetings hear more of the voices in the room**
- Telling speakers apart in a meeting, and in `lore transcribe --speakers`, now uses a model that catches voices the old one merged into one; where the old one already heard everyone, the result is the same
- If the new model fails on a file, lore tries again and then uses the old one, so a meeting always gets its speakers
- The new model (about 21 MB) downloads in the background after launch, with the old one it falls back to; nothing waits for them, and until both are there lore works as before

**3.8.25 (#276) lore transcribe can say who spoke**
- `lore transcribe --speakers <file>` prints the transcript as turns, one paragraph each: `[mm:ss] Speaker 1: …`, speakers numbered in the order they first speak
- If lore can't tell the speakers apart, you still get the plain transcript, with a note saying so
- Without the flag, `lore transcribe` prints exactly what it did before

**3.8.24 (#313) The phone's note deletions and its "Hard to hear" hint are traced**
- Deleting notes in the coming iPhone app leaves one entry in its diagnostics with how many notes went, and nothing about what they were; its "Hard to hear" hint leaves one entry when it appears and one when it goes, with how long it was up

**3.8.23 (#265) Dictation on a full disk keeps your words and says so**
- When a dictation can't be written to history, for example because the disk is full, its words stay on the row and the row says "Not in history yet". lore saves it by itself once there is space again; there is nothing to click
- The bubble says so the moment it happens: "Pasted, not in history — the disk is full."
- When the speech model takes more than 10 seconds to get ready, the bubble says "Preparing the speech model — about a minute" instead of a "Transcribing" that looks stuck

**3.8.22 (#308) The phone offers to find speakers only when it can**
- The coming iPhone app shows Separate speakers on a note only when that note can be given speakers, and does not keep retrying one that cannot until it is transcribed again

**3.8.21 (#308) A phone note can tell its speakers apart**
- The coming iPhone app can find who spoke in a note after it is transcribed, on the phone itself, and label the lines Speaker 1, Speaker 2… in the order the voices first speak. The phone knows nobody's voice, so no line is ever labelled You. Meetings on the Mac are unchanged: the same speaker pass, the same You and Them, the same labels

**3.8.20 (#322) A long cleanup is never pasted cut off**
- A long dictation, around 15 minutes or more, is now cleaned up or translated in full instead of stopping partway through. If an answer still stops before the end, lore pastes your own words in full instead of a half text, with "Cleanup failed — pasted raw text." for a cleanup and "Translation failed — pasted raw text." for a translation

**3.8.19 (#321) A translation never comes back in the language you spoke**
- A translation that comes back in Russian, or half in Russian, is no longer pasted as the translation. lore asks once more, and if the second answer is still not in the target language it pastes your own words with "Translation failed — pasted raw text." Short takes and English full of Russian names are not affected

**3.8.18 (#313) The iPhone can show text while it records**
- The coming iPhone app can show what is being said, a few seconds behind, while it records. The final text still comes from the full pass after Stop, which uses the speech model the live text already loaded instead of a second copy. The Mac's live meeting transcription now runs on the same shared code and is unchanged for the user

**3.8.17 (#316) A meeting lore is quit in the middle of keeps its timing**
- When lore is force-quit or crashes during a meeting on the Mac, the saved timing for the microphone and the other side's audio no longer occasionally loses one of the two, so the rebuilt transcript is placed at the time it was spoken

**3.8.16 (#314) The diagnostic log is no longer wiped by one entry it can't read**
- An entry written by a newer or different build of lore no longer makes the whole diagnostic log restart empty. The entries this build reads are kept, and the ones it can't read are kept as written, so the build that wrote them can still read them

**3.8.15 (#306) The iPhone app can report a transcription cut short and a title it could not make**
- The coming iPhone app records in its private diagnostic log when iOS stops a transcription before it finishes, so the note is transcribed again, and when it cannot make a note's title. Nothing changes on the Mac

**3.8.14 (#306) A note keeps its real length, and a recording that can't be read is tried again**
- A transcript no longer changes a recording's stored length. On the Mac this fixes imported audio files, which were cut to their last spoken line; live meetings and phone notes already kept their real length
- A recording that can't be opened or decoded is tried again later instead of being remembered as holding no speech, on the Mac and on the phone

**3.8.13 (#306) The iPhone app can tell a transcribed note from one still waiting**
- Whether a meeting already has its final transcript is now readable by the coming iPhone app, so it does not transcribe a note twice after a crash. Nothing changes on the Mac

**3.8.12 (#306) The iPhone can make a meeting's title on the device**
- The Mac's on-device maker of meeting titles and summaries is now shared, so the coming iPhone app can use it. Nothing changes on the Mac
- A phone note whose recording holds no speech is remembered as such, so it is not transcribed again for nothing

**3.8.11 (#306) The iPhone app can record what happens to a recording**
- The coming iPhone app keeps the same private diagnostic log as the Mac when a recording is stopped, resumed or alerted. Nothing changes on the Mac

**3.8.10 (#309) Notes from your iPhone show up in Meetings**
- Turn on "Show notes from iPhone" in Settings › Meetings, and notes you record with the iPhone app appear among your meetings, marked with a small phone, and `lore search` finds them
- Where the phone had to stop recording, for a call, an alarm or music, the transcript says so in one quiet line at that moment
- If macOS doesn't let lore read iCloud Drive, or a note can't be copied over, Settings says so under the switch

**3.8.9 (#308) Choose when lore works out who spoke**
- A new setting, Separate speakers, under Enhance transcript after meeting. It is on by default, so meetings are sorted by speaker as before
- With it off, lore keeps both sides of each meeting's audio, so you can still find the speakers later
- Who spoke? on a meeting works out who said what in that meeting, whenever you ask

**3.8.8 (#306) The coming iPhone app can transcribe its notes with lore's own engine**
- A meeting that ended with no live text keeps its real start time instead of the time it stopped

**3.8.7 (#309) The shared format knows how phone notes arrive**
- The folder and file layout a phone note travels in is now part of lore's shared format, so the coming iPhone app and the Mac agree on it. Nothing changes on the Mac yet

**3.8.6 (#305) The Mac and the coming iPhone app share one core**
- Transcription, speakers, meeting storage and the file format now live in a shared core that also builds for iOS. Nothing changes on the Mac

**3.8.5 (#300) Setup lets you drag lore straight into System Settings**
- Allow on Accessibility or Input Monitoring opens the right page of System Settings, with a small card holding lore just under the list. Drag lore into the list, then turn its switch on
- The card follows the Settings window and steps aside when another app is in front
- A grant shows as done only once lore has read it for real; dropping lore in the list alone changes nothing
- Can't drag? The card says to use the + button under the list
- Apple's own Accessibility popup no longer appears first

**3.8.4 (#301) Agents can find and read what you said**
- `lore search` finds your dictations and meetings by words and dates, newest first; `--json` for scripts
- `lore show` prints one dictation, or a meeting's transcript with the speakers' names; `--notes` adds its notes
- `lore skill` prints a short guide that teaches an agent `say`, `transcribe`, `search` and `show`; `bunx skills add atarazevich/lore` installs it into Claude Code, Codex and other agents
- The `lore` command now goes where your Terminal finds it: `/opt/homebrew/bin` or `/usr/local/bin` when lore can write there, else `~/.local/bin`
- These commands only read. They work while lore is closed

**3.8.3 (#299) A new speech model: Parakeet Ultra**
- lore now transcribes with Parakeet Ultra, a more accurate version of the model it used before, in the same 25 languages and at the same speed
- Speech that mixes Russian and English comes out right much more often: phrases that used to turn into made-up English now keep their words
- After the update, dictation and meetings keep working on the previous model while the new one downloads (about 630 MB) in the background. lore switches when nothing is recording, and removes the previous model the next time it starts
- Without a connection, lore stays on the previous model and tries again on a later launch

**3.8.2 (#296) A reply from a background chat carries the chat's name**
- A chat with no tab of its own is named as Claude Code's agents view names it, a fork included, instead of by its folder
- A chat whose agent moved to another folder keeps the name of the folder it started in

**3.8.1 (#264) The replies player shows every reply in the order it came, with its time**
- One list: the oldest reply at the top, the newest at the bottom, and the player opens scrolled to the bottom
- Every reply shows when it arrived: "now", minutes up to ten, then the clock, "Yesterday", the weekday, or the date. The times update while the player is open
- Each row shows the chat's name and the first line of what it said. A blue dot marks a reply not heard yet, and a speaker takes its place while it is read
- The workspace shows only when two chats in the list have the same name. The app icon and the line with the topic and folder are gone
- The reply being read opens in place with all its words, the time gone and the time left, and one Go to back to its chat. A reply with no chat to go to has no button, and the Go to key (fn J) dims while that reply is in the player
- In the seconds after the last reply, its Go to stays open, and fn J goes to its chat and fn R plays it again

## v3.8.0 — 2026-09-30

lore is ready before your first word, a dictation caught by a restart finishes by itself, and lore closes cleanly when it is ended from outside.

**A reply from a chat started in Claude Code's agents view has a Go to (#293)**
- A reply from a background chat started in Claude Code's agents view (`claude agents`) shows its terminal app, and Go to opens the pane the agents view runs in. Before, such a reply had no Go to
- The reply keeps the chat's own name, not the name of the agents view's tab
- With several agents views open, the one in the folder the chat started in is used; when none or more than one fits, the reply has no Go to rather than a wrong one
- A chat moved to the background from a window that has since been closed is found in the agents view the same way

**lore closes cleanly when it is ended from outside (#292)**
- When lore was ended from Terminal or at shutdown, it could report that it quit unexpectedly. Now it finishes its last steps and closes cleanly

**lore is ready before your first word (#294)**
- Setup now downloads and prepares the speech model while you go through it, so your first dictation doesn't wait for it
- A dictation caught by a restart before its words were ready is transcribed by itself when lore opens again. It lands in your history only; nothing is pasted
- lore removes the half-prepared copies of the speech model that an interrupted start left behind, which could hold several hundred megabytes of disk

## v3.7.0 — 2026-09-30

Meetings say who said what, and both sides of a recording stay in time at their true pitch. lore also no longer quits by itself after a few days open.

**lore no longer quits by itself after a few days open (#291)**
- After being open for a few days, lore could quit by itself, usually just as the microphone started for a dictation or a meeting. Keeping it open for days no longer does that

**A meeting is in the list the moment it ends (#290)**
- When you stop a meeting, it is in the list and open straight away, with its live transcript and "preparing…" while the second pass runs. Before, a long meeting stayed out of the list for minutes while its recording was saved, and looked lost
- With "Save audio recording" on, the recording is saved to the notes folder shortly after, in the background: the transcript first, then the recording, then finding who spoke. Its play button appears when it is there
- If lore is quit before a recording is saved, it is saved the next time lore opens. A recording is in the notes folder whole or not at all

**The replies player says what it is (#289)**
- The player's top bar now carries lore's mark and the command that fills it, `lore say "message"`, with a ? beside it
- The ? opens a card on hover: what the list is, and the one line to add to an agent's instructions, with Copy. A click on the ? keeps the card open until you click elsewhere or press Esc; while it is open, Esc closes the card first
- The × still hides the player. The bar is 6 pt taller; the rows, the keys and the width are as before

**A reply from a background session names the chat it came from (#288)**
- A reply from a Claude Code background session is listed and announced under the herdr tab of the chat you moved it to the background from, and Go to opens that tab. Before, it took the tab of whichever chat had started Claude Code's background service
- When that chat is closed or has moved on to another conversation, the reply shows its folder instead of another chat's name
- Replies from chats in their own tab are named as before, and replies already in the list keep their names

**Updates can arrive between releases (on Macs that opt in)**
- A Mac can take updates between releases from a separate channel; it opts in by hand, and nothing changes for any other Mac

**Meetings say who said what (#269)**
- After a meeting, lore finds who spoke, on your microphone's side and on the other side separately, so several people in one room or on one call are no longer a single voice. It runs on this Mac, after the transcript is ready, and never holds up the next meeting
- While it runs, the meeting's detail line ends with "finding who spoke…"; when it is done the line goes and the speakers are in place
- Your own voice is You. Everyone else is Speaker 1, Speaker 2… numbered by when they first speak, and a number never shifts once given
- Click a speaker's name to name them, or to merge them into You, into another speaker of the meeting or into someone you have named before. People you named are suggested first when their voice sounds alike, but never applied for you
- The names reach the transcript, the summary, Ask Lore, copy and the meeting's notes file. Naming someone makes the summary again with the names in it; a title you set yourself is kept
- The review reads by turns: one speaker's lines run together under their name, and a short reply of three words or fewer from someone else stays inside the turn as "(Name: words.)". Meetings from before this version read by turns too, as You and Them
- Times in the review read as time into the meeting — "12m 57s", "1h 2m" — so they are not mistaken for the clock time in the header. Copy, export and Ask Lore keep clock times
- The line count is gone from the meeting's detail line and the meeting list
- A meeting's default title uses the time the recording started, the same time the detail line shows
- Not yet: lore does not recognise a voice by itself in a later meeting, a merge cannot be undone, and a person's name cannot be changed everywhere at once. Meetings recorded before this version have no speakers to find
- Speech recognition library updated to FluidAudio 0.17.4; transcripts read as they did before

**A meeting keeps one notes file (#280)**
- Renaming a meeting, by hand or by the automatic title, replaces its notes file instead of leaving the old one beside it under the old name. Saving the transcript again, or its notes, rewrites the same file
- A file with the same name that belongs to another meeting, or one you made yourself, is never overwritten
- A title or tags set while a meeting was still recording are kept when it finishes; before, finishing dropped them
- Copies already left behind by earlier versions are not removed, and a meeting saved before this version can leave one old copy on its first rename

**The meeting's second pass keeps speech whole (#273)**
- Speech that runs across the edge of a 30-second block now comes out as one line instead of two, often mid-sentence
- No audio at a block's edge is skipped, and a line keeps a short lead-in, so its first syllable is no longer lost
- An echo — your microphone picking up the other side's words — is removed whichever side starts first. A real exchange with the same words in it is kept; when unsure, lore keeps the line

**A Bluetooth headset in call mode no longer records the other side an octave high (#272)**
- A headset in call mode can deliver the other side's sound at half the rate the Mac announces. lore now measures what actually arrives and corrects it, so the other side is recorded, transcribed and played back at its true pitch and speed, even when the headset switches mode partway through a meeting
- The other side's speech is recognised better in those meetings, because the transcription no longer hears it at double speed
- A headset or output that delivers its announced rate is not touched

**Dictation and live meeting audio no longer lose a sliver every few seconds (#271)**
- A tiny piece of audio, about a hundredth of a second, was dropped every 2.7 seconds in every dictation and in the live transcription of both meeting sides. Nothing is dropped now, so words falling on those moments are no longer clipped

**The two sides of a meeting recording stay in time (#268)**
- Your side and the other side are each placed by when they were captured, so a saved meeting recording no longer drifts into two voices talking over each other at different speeds
- A pause in capture, or the other side dropping out for a while, leaves silence where it happened instead of pulling the rest of the recording out of step

**The replies player shows which chat is talking, even when you put it away (#285)**
- When a reply begins to be read, the player comes up with the chat's name, even if you put it away with `fn` or the ×. When reading ends it stays for ten seconds, then goes away again
- Tap `fn` while a reply is read to put the player away for that reply; the next reply brings it back
- The player never takes the keyboard from the app you are in, and during a dictation or a call it stays away as before

**`fn` is decided once: a quick tap is the player, a hold is a dictation (#279)**
- Let go of `fn` within 0.2 seconds, with no other key, and it is a tap: the replies player comes up or goes away, and nothing else happens. Still holding it at 0.2 seconds, it is a dictation
- Pressing `fn` no longer touches a reply being read. A dictation pauses it once it has started; a tap and `fn R` no longer stop it for a moment first
- A hold let go before any word could be heard is a dictation that came to nothing, as before, and no longer shows or hides the player
- A chord whose `fn` flickers under the other key is no longer taken for a tap
- `esc` while `fn` is still inside those 0.2 seconds cancels the dictation before it starts
- Reading a selection aloud pauses when a dictation starts, not on every press of `fn`
- A call or any other app using the microphone still holds replies, exactly as before
- A tap on a real keyboard now shows and hides the player: the key-down macOS sends for the Globe key when `fn` is let go counted as a second key, so every tap was taken for a chord. Taps in quick succession each count, and a tap is not taken for a dictation when lore reads its release late
- A tap of `fn` no longer flashes the "meeting detected" prompt

**A tap of `fn` shows or hides the replies player, and `fn R` plays and pauses again (#278)**
- Tap `fn` on its own to bring the player up, and tap it again to put it away. A tap is a quick press with no other key and no words in it; anything you say while holding `fn` is a dictation, as always, so a one-word dictation still pastes
- A tap while a reply is being read leaves it being read
- `fn R` pauses the reply being read, and pressing it again carries it on from where it stopped. It no longer opens or closes the player
- A tap brings the player up even when every reply has been heard, muted or not, so the list of past replies is there to go back to
- With no replies, a tap of `fn` does nothing, as before

**`esc` stops a reply being read, wherever the player is (#277)**
- While lore is reading a reply, `esc` pauses it even when the player is put away and another app is in front. The reply stays where it stopped and carries on from there when you play it again
- `esc` right after the chat's name — in the short pause before the reply — now stops the reading too; before, that press was taken and nothing stopped
- A recording and the screenshot tool still take `esc` first, and with nothing being read and the player put away, `esc` goes to the app in front as before

**The replies player moves, says which chat is speaking, and calls a chat what you call it (#267)**
- Press anywhere on the player — or on the waiting capsule — that is not a button and drag it where you want it. It opens there next time, and after a restart. If the screen you left it on is gone, it comes back under the recording bubble
- The chat is now said on its own before the reply, with a clear pause after it, and in a voice that fits the name's own language — an English chat name is no longer read by a Russian voice, and no longer runs into the words
- Clicking a reply in the list plays it without saying which chat it is: you are looking at the row you clicked. Everything that starts a reply away from the screen still says the chat first
- A chat is named by the workspace and tab you typed in herdr — workspace, then tab — over what the chat calls itself: its own topic, its folder and the app it runs in. Renaming a tab changes what the player shows and says the next time it comes up. Outside herdr, the name you gave the chat yourself, else its folder — never a name the agent made up for you
- A chat lore cannot ask about keeps the name it arrived with, and replies already in the list still show and play
- The list is denser: seven chats where five stood, each on two lines, the second running the full width so two tabs of one workspace can be told apart

**"Replies waiting" counts only what will be read (#266)**
- A reply waits until it starts being read: one that was started and left behind — a row clicked while it was playing, a pause reading moved on from — stops being counted, so the capsule no longer says replies are waiting when the player has nothing left to read

**The replies player answers to one key, one click and one × (#263)**
- The player can be put away while a reply carries on being read
- `esc` pauses the reply being read, and pressing it again puts the player away; with nothing being read, one press puts it away. A recording and the screenshot tool still take `esc` first, and every other moment leaves it to the app in front
- Clicking a reply plays it; clicking the one playing pauses it; clicking it again carries on from where it stopped. A reply left and come back to starts again
- The keys at the foot of the player are one quiet line instead of two rows, and the player has a translucent head with an × that puts it away

**Coding chats speak through lore, one at a time (#236)**
- A chat in the terminal can send lore what it just said, and lore reads those replies aloud one after another, the chat's name first, instead of several chats talking over each other
- Every reply stays in a list in the player, so one can be heard again, and the last fifty survive a restart
- Nothing is read while the microphone is in use — a dictation, a recording or a call. A quiet capsule says how many replies wait, and a short sound plays when the microphone is free again
- From any reply, one control goes to its chat: it switches to the chat's app and shows its tab, or opens the chat again in a new tab when it is closed, or starts the app first when it is not running. The app's own icon says which app that is
- Keys on the player: fn R play or pause, fn [ previous, fn ] next, fn J go to the chat, fn M mute, esc stop. While a reply is being read, esc stops it and the app in front does not receive that key
- A chat sends a reply with `lore say "<text>"`, the same `lore` command that prints a file's transcript today; if lore is not running, or the feature is off, the system voice speaks it exactly as before
- Off by default, under Settings as an experimental switch. While it is off nothing of this runs, and fn R and fn Q keep reading selected text

**A development build no longer updates itself (#262)**
- A build made for testing never checks for updates, so it cannot be replaced while it runs; released builds check as before

**Transcribe a file from the command line (#254)**
- `lore transcribe <audio file>` prints the file's transcript. lore itself reads the file and transcribes it with its own local speech model, so a recording only lore is allowed to open — a voice memo, with lore granted Full Disk Access — works from a terminal that has no such permission
- Nothing is added to meetings, notes or dictation history; the transcript only goes to the terminal
- The command opens lore if it isn't running, and says so plainly when lore is open but not answering
- A recording being transcribed steps aside the moment a meeting starts, and Ctrl-C stops the work inside lore
- A file that stops decoding part-way still prints the text up to that point, with one line saying the rest couldn't be read

## v3.6.0 — 2026-09-14

A fix release: nothing new, one crash gone.

**The recording bubble no longer quits the app (#255)**
- lore could quit mid-dictation when macOS briefly had no system font to hand it — most likely just after a restart — because the bubble measured its timer with a font it assumed was always there
- Every place that measures text for layout (the timer, the time column in the bubble's list, the error line, the bubble's height and the Stats pane) now asks for the font in a way that can come back empty, and falls back to the system font's own proportions when it does
- Nothing looks different: the bubble renders pixel for pixel as it did in 3.5.0

## v3.5.0 — 2026-09-04

The features speak for themselves: nothing is taught up front, and each one says one sentence from its own place at the moment you could use it.

**Contextual hints on the dictation bubble (#235)**
- Hold the talk key past ten seconds and the lock says "Space locks recording, hands free", with Space drawn as a keycap; lock for the first time and the closed lock says how it ends
- Go quiet for twenty seconds while locked and the dot offers "Recording — click to pause"; pass two minutes without cleanup and the rail opens with "Fn+V cleans up on paste"
- Talk into a muted or zeroed input for five seconds and the dimmed dot reports "No sound is reaching the microphone", withdrawn the instant sound arrives — a live report, never a guess
- Each hint is the element's own tooltip said once: it leaves by itself after six seconds (hovering holds it), the instant you perform the action, or when you close it with ×, which means never again; otherwise it may return up to three times, on different days, and never twice in one recording
- Someone who already locks, pauses or cleans up never sees the hint at all
- The rail's Space keycap (Lock / Pause / Resume) is gone: the lock glyph and the dot are those controls, and the locked dot's tooltip now names the pause

## v3.4.0 — 2026-09-02

Esc means cancel again — into history, never into the void — and the pause moves onto the key your thumb is already holding.

**Esc cancels into history (#233)**
- Esc ends a dictation without pasting, from a held, a locked, or a paused recording alike: the words, the audio, and whatever rode along land in history, nothing is inserted, and the bubble says "Cancelled — in history" for a moment before it hides
- One press, one cancel: a held Esc is a single cancel, and the talk-key release after it pastes nothing
- The pause moves onto the talk key: while locked, the talk key with Space pauses and the same chord resumes; a held chord no longer flips pause and resume at the key-repeat rate, and no stray spaces reach the document
- The held-key rail gains a Space cap that reads what Space does right now — Lock, Pause, or Resume — and the sidebar dot shows a pause in steady amber instead of a pulsing red

**The paused bubble is the recording bubble (#234)**
- No Cancel pill: click the recording dot to pause, click the pause mark to resume, the way the lock glyph beside it already works; the paused row is the recording row with nothing appended

**Every surface names what Esc does (#228, #230)**
- The dot's tooltip, the lock glyph, the window's locked status row, and the footer cheat sheet all say what Esc actually does — no surface promises discard, stop, or pause where the key does something else

**Attachments count as content (#229)**
- A silent dictation with screenshots or copied items delivers them: the items compose into the prompt and paste instead of failing with "Nothing came through", and a release too short to transcribe keeps the items it collected

## v3.3.0 — 2026-08-31

The after-release polish: the bubble tells the truth in more places, onboarding stops dead-ending, and switching meetings off leaves nothing behind.

**Onboarding unblocks (#226)**
- Onboarding no longer dead-ends when macOS owns the Fn key: the hotkey step offers Fn, Right Option, or a key you record yourself (right-hand modifiers, and F-keys when the F-row is standard), and every surface names the key you chose

**The bubble tells the truth (#224 follow-ups, #225)**
- The open rail hints V too — the letters you see are the keys that work
- While a dictation is processed, the bubble names the real stage: Translating… or Cleaning up… once transcription is done
- Ending a dictation by any path ends the Space lock — the sidebar dot can no longer pulse with no recording

**Meetings off means gone (#227)**
- Switching meetings off leaves nothing to flash: the detection prompt refuses to appear while off, the app keeps one prompt window for its whole life instead of one per toggle, and every show or sweep leaves a trace in the diagnostic ring
## v3.2.0 — 2026-08-31

lore becomes the primary input surface for AI agents: what you say, copy, and screenshot while dictating reaches the agent's prompt — and meetings step back behind a switch until their own polish cycle.

**Rich input for CLI agents (#192, #194, #195, #196, #198, #199, #202, #208)**
- What you copy or screenshot while dictating joins the prompt where you said it
- Screenshots reach web composers and Claude desktop as real files; collected screenshots stay under a size cap
- Cmd+Shift+4 during a dictation goes to the prompt; paperclip off means lore takes no screenshot and nothing rides along
- Copying gets its own Settings section

**The recording bubble (#201, #202, #203, #204, #205, #206, #207, #208, #209, #210, #212, #213)**
- One shape that explains itself: widens on hover from a fixed canvas, armed letters C T K S, a paperclip that carries its count, draggable, tooltips that actually appear
- Esc pauses a dictation instead of destroying it; holding Fn in a locked recording opens the bubble; a short press submits
- Every face of a dictation — processing, done, upgrade, errors, paused — lives in the same bubble idiom

**After-use polish (#211, #216, #217, #218, #219)**
- A quiet microphone is a dimmed dot, not a banner; rows say Click to toggle
- Releasing Fn migrates the bubble instead of conjuring a second one; the paste checkmark pops in place
- Pause moves nothing, and the paused bubble's button is Stop recording — it saves to history and pastes nothing

**Activity (#215, #220, #222)**
- Stats is its own sidebar destination: a per-day heatmap of words, tokens, and time whose counts agree with history
- The tokens estimate explains itself instantly: hover the line for the tooltip, click to pin it; the stat columns read full-height and the pane sits closer to the toolbar

**Meetings step back (#221)**
- One master switch in Settings; off on a fresh install, on for machines that already used lore
- When off, meetings leave the sidebar and menu bar entirely — no detection, no prompts, no background work
- Recordings and notes stay on this Mac; flip the switch and every past meeting returns

**Only real controls (#223, #224)**
- Send to the operator goes behind one switch — off on a fresh install; when off, K leaves the bubble and the key does nothing; dictations already marked keep their mark
- The bubble rail shows the key you press: cleanup reads V, and S leaves — the paperclip is that control

**Durability (#177, #182, #169, #168, #193 — first layer)**
- A dictation killed mid-speech keeps its audio and offers a retry from the first buffer
- A meeting killed mid-recording keeps its audio where the launch sweep already heals it
- One prepared speech model, one owner — no second copy loads during warm-up
- One API-error shape across the app
- A second app launch via Finder/Dock/open activates the running copy instead of racing its Fn tap (direct binary exec still escapes — #193 stays open)
## v3.1.0 — 2026-08-11

Meetings now repair themselves. The transcript-state vocabulary is gone; a meeting shows its text, quietly prepares it, or says one honest sentence — and the app does its own chores.

**Meetings self-heal (#166)**
- The transcript-state UI is gone. A meeting shows its transcript; "Preparing the transcript…" with a live progress track while a job runs; or, only when there is no transcript and no audio to make one from, a single plain sentence. Zero buttons, tooltips, or state icons on the meeting page
- The app repairs transcripts by itself: transcript writes are atomic (a killed process can never corrupt or lose one), interrupted jobs resume at the next launch, failures retry quietly a few times per launch, and opening a meeting with nothing to read starts a fresh attempt while audio exists
- A recording start no longer kills a background pass — the job waits and resumes after the meeting ends
- The #129 speaker-separation question is answered by policy instead of a dialog: per-track audio is always preferred; the single-speaker pass runs only when it is the last option

## v3.0.0 — 2026-08-10

The distribution era changes: lore is now signed with a paid Developer ID, notarized by Apple, and ships as a proper DMG — no more Gatekeeper warnings, and updates arrive without any permission ceremony. Plus six weeks of features: whole-recording transcripts, on-device enrichment, meeting pause/resume, honest health reporting, and a rebuilt first launch.

**A real signed app (#134, #135, #138)**
- Every build is signed with a paid Apple Developer ID, hardened and notarized — macOS opens it without warnings, offline included
- If the app's signing identity ever changes again, a guided migration walks through re-granting permissions instead of failing silently
- API keys move from the login keychain to an owner-only secrets file — no keychain dialog will ever appear again

**Meetings: the transcript is rebuilt from the whole recording (#109, #128, #129, #130)**
- When a meeting ends, the live chunked transcript is replaced by one rebuilt from the full audio — better accuracy, no mid-utterance seams. An indicator shows chunked / rebuilding / whole, and clicking it rebuilds on demand — including for older meetings recorded before this update
- Rebuild timestamps stay correct across capture gaps (pauses, device switches), a rebuild that would collapse speaker labels asks first, and every meeting with saved audio gets a play button

**Meetings: on-device enrichment (#107, #108, #131)**
- After a meeting, Apple's on-device model adds tags and structure to the notes — nothing leaves the Mac for this. The meetings review pane was restyled around it
- Enrichment is the only on-device stage; dictation cleanup stays on OpenAI, where quality is decisively better

**Meetings: pause and resume (#153)**
- A live meeting can be paused and resumed as one session — one transcript, one recording, with the gap filled by silence so audio stays in sync. Paused reads as steady amber everywhere: banner, REC pill, sidebar, menu bar

**Health reporting: no more popups, no more false alarms (#140, #141, #144, #145, #151)**
- The notch health popups are gone. Health now speaks through a quiet amber dot on the menu-bar mark that appears only after a condition has stood for 60 seconds, and vanishes the moment it clears. The health panel remains the full gauge
- The "app signature changed" alarm that fired on every launch of a healthy app is fixed: it fires once per real identity change, is dismissible, and clears itself
- Notch surfaces are now excluded from screen sharing reliably — including after display changes

**Recording reliability (#149)**
- All capture retry loops are bounded by a shared budget — no more infinite 5-second retries flooding diagnostics. Microphone recovery is proven by audio frames actually arriving, not by the device claiming to start. A system-audio failure names itself and deep-links to the right permission pane

**Onboarding rebuilt (#135, #136, #150)**
- First launch is now a single guided window — permissions revealed in sequence with live readings, a real guided dictation, honest consent — and no subsystem (capture, detection, updates) starts until setup completes. A configured machine skips it entirely
- When the app's signing identity changes (new build source), a guided migration walks through re-granting permissions instead of failing silently

**Notes move into the app's own folder (#148)**
- Meeting notes now live in the app's Application Support folder instead of ~/Documents. Existing notes are moved once, automatically; launch never triggers a Documents access dialog again

**Dictation cleanup simplified (#143, #146)**
- One tighter default prompt: no paraphrasing, self-corrections resolved. The Concise preset is gone — Default and Custom remain
- The cleanup prompt in Settings is shown in full, selectable, with a Copy button — what you read is exactly what runs

**Fn+K: send a dictation to the operator (#122)**
- Pressing K during a recording flags that dictation for the Safe Flow dispatcher instead of pasting it

**Smaller things**
- The product is now lowercase "lore" everywhere it speaks for itself, with a new mark (#137)
- Meetings list polling no longer burns CPU while idle (#142)

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
