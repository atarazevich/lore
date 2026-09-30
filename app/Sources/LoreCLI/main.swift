// The `lore` command. Two things, neither of them done here: `lore transcribe
// <audio file>` prints the file's transcript (#254) and `lore say "<text>"`
// hands an agent's reply to lore to read aloud (#257). The running app does the
// work — under its own permissions, so a file only lore may read (Full Disk
// Access) works from a terminal that has no such grant — and this process only
// carries the request there and the answer back.
//
// Design: docs/features/cli-transcribe.md, docs/features/agents-speak-through-lore.md.
import AppKit
import Darwin
import LoreCLIKit

/// The app's bundle identifier — also the defaults domain its setup flag lives in.
let appBundleID = "com.lore.app"

/// How long lore gets to open its socket, counted from lore's own launch.
/// A cold launch this command started gets the long wait. A lore that was
/// already running gets the short one — enough for a launch another `lore`
/// started a moment ago — so a lore that has been up for a while is answered
/// for at once.
let launchTimeout: TimeInterval = 30
let runningGrace: TimeInterval = 10

/// lore opens its socket only once setup is done, so an unfinished setup is
/// named once lore has been up this long rather than at the end of the
/// timeout. Long enough for a launch to migrate an older install's flags into
/// the one this reads.
let setupGrace: TimeInterval = 3

/// How long a reply waits for lore to take it (#257), in whole seconds. Short
/// on purpose: an agent is holding its terminal open for this, and
/// `/usr/bin/say` is a good enough answer. lore answers one request at a time,
/// so a `lore transcribe` in front of a reply can reach this.
let replyTimeout = 2

/// The longest herdr gets to name the chat. It answers in about a fifth of a
/// second; past this the name comes from somewhere else.
let herdrTimeout: TimeInterval = 2

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    warn(message)
    exit(code)
}

/// When the running lore launched, or nil when none is running. The class
/// method asks LaunchServices on every call, so it is current in a process that
/// never runs a run loop (checked against an app launched and quit mid-poll);
/// the instances it returns are snapshots and are not kept.
func runningAppLaunchDate() -> Date? {
    NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID)
        .first.map { $0.launchDate ?? .distantPast }
}

/// Opens lore without asking to bring it forward: the bundle this command lives
/// in when there is one, whichever copy LaunchServices knows otherwise.
func launchApp() -> Bool {
    // ~/.local/bin/lore → …/Lore.app/Contents/Helpers/lore
    let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", appBundleID]
    guard (try? open.run()) != nil else { return false }
    open.waitUntilExit()
    return open.terminationStatus == 0
}

/// Synchronized on every call: lore can write the flag while this waits.
func setupIsComplete() -> Bool {
    CFPreferencesAppSynchronize(appBundleID as CFString)
    return CFPreferencesCopyAppValue(CLIWire.setupCompletedKey as CFString, appBundleID as CFString) as? Bool == true
}

func connectLaunchingIfNeeded(socketPath: String) -> Int32 {
    if let fd = CLISocket.connect(to: socketPath) { return fd }
    let commandStart = Date()
    let launchedHere = runningAppLaunchDate() == nil
    if launchedHere {
        guard launchApp() else { fail("lore didn't start — open lore and try again.") }
    }
    while true {
        if let fd = CLISocket.connect(to: socketPath) { return fd }
        let launched = runningAppLaunchDate()
        let upFor = Date().timeIntervalSince(launched ?? commandStart)
        if launched != nil, upFor > setupGrace, !setupIsComplete() {
            fail("lore isn't set up yet — finish setup in lore, then try again.")
        }
        if upFor >= (launchedHere ? launchTimeout : runningGrace) {
            guard launched != nil else { fail("lore didn't start — open lore and try again.") }
            fail("lore is open but isn't answering — quit lore, open it again, then try again.")
        }
        usleep(100_000)
    }
}

// MARK: - transcribe (#254)

/// Prints what lore heard in the file, and opens lore when it is closed: a
/// transcript is the whole point of the call, so it is worth a launch.
func transcribe(typedPath: String) -> Never {
    let noAnswer = "lore stopped before the transcript was ready — try again."

    // Resolved here: the app does not share this process's working directory.
    let request = CLIRequest.transcribe(path: URL(fileURLWithPath: typedPath).standardizedFileURL.path)

    // The connection stays open until the answer: closing it (Ctrl-C ends this
    // process) is what tells lore to stop.
    let fd = connectLaunchingIfNeeded(socketPath: CLIWire.socketPath)
    guard let line = try? CLIWire.encode(request), CLISocket.writeAll(fd, line) else { fail(noAnswer) }
    let answer = CLISocket.readToEnd(fd)
    close(fd)

    switch try? CLIWire.decode(CLIResponse.self, from: answer) {
    case .transcript(let text, let complete):
        print(text)
        if !complete { warn(CLIResponse.incompleteMessage(file: typedPath)) }
        exit(0)
    case .failed(let reason, let complete):
        warn(reason.message(file: typedPath))
        if !complete { warn(CLIResponse.incompleteMessage(file: typedPath)) }
        exit(1)
    // The reply answers are `lore say`'s; here they are no answer at all.
    case nil, .queued, .notAccepted:
        fail(noAnswer)
    }
}

// MARK: - say (#257)

/// Hands one agent reply to lore, which reads the replies aloud in arrival
/// order with the chat's name first.
///
/// The words are spoken whatever happens: a lore that is closed, not taking
/// replies, or too busy to answer in time leaves them to `/usr/bin/say`, which
/// is what a terminal did before this feature. The exit status is always 0 —
/// the output style that calls this must never see a failure of lore's.
func say(arguments: [String]) -> Never {
    guard case .send(let voice, let typed, let dryRun) = CLISay.parse(arguments) else {
        // A flag this command does not know: `say` gets the line untouched.
        speakHere(arguments: arguments)
    }
    let text = typed ?? standardInputText()
    guard !text.isEmpty else { exit(0) }
    let environment = ProcessInfo.processInfo.environment
    let session = claudeSession(environment: environment)
    let place = CLISay.place(
        environment: environment,
        session: session,
        sessions: { ClaudeSessionFile.all(in: ClaudeSessionFile.directory(home: NSHomeDirectory())) },
        processes: SystemProcessTable()
    )
    let reply = CLISay.request(
        text: text,
        voice: voice,
        environment: environment,
        cwd: FileManager.default.currentDirectoryPath,
        place: place,
        herdr: herdrFacts(place),
        session: session
    )
    if dryRun {
        // What would go on the wire, and nothing sent or spoken.
        if let line = try? CLIWire.encode(reply) { FileHandle.standardOutput.write(line) }
        exit(0)
    }
    guard let spoken = CLISay.spokenHere(afterAnswer: send(reply), sent: reply, typed: text) else {
        exit(0)
    }
    speakHere(arguments: spoken)
}

/// One exchange with a lore that is already running, and nil when there is
/// none or it did not answer. Never launches lore: a reply is worth hearing
/// now, not after a cold launch, and nothing is lost by not waiting.
func send(_ reply: CLISayRequest) -> CLIResponse? {
    guard let fd = CLISocket.connect(to: CLIWire.socketPath) else { return nil }
    defer { close(fd) }
    CLISocket.setTimeouts(fd, seconds: replyTimeout)
    guard let line = try? CLIWire.encode(CLIRequest.say(reply)),
          CLISocket.writeAll(fd, line),
          let answer = CLISocket.readLine(fd, limit: CLIWire.maxRequestBytes)
    else { return nil }
    return try? CLIWire.decode(CLIResponse.self, from: answer)
}

/// The words spoken by this process, the way the terminal spoke them before
/// lore. Waiting for `say` to finish is part of that.
func speakHere(arguments: [String]) -> Never {
    let speech = Process()
    speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    speech.arguments = arguments
    guard (try? speech.run()) != nil else { exit(0) }
    speech.waitUntilExit()
    exit(0)
}

/// The text on standard input, which is where `say` reads it when the command
/// line carries none.
func standardInputText() -> String {
    String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Where this chat is, when it is shown in a herdr pane and herdr answers in
/// time: the workspace and tab labels the owner typed, and the terminal title
/// Claude Code writes for itself (#267). The labels are the player's fallback
/// and what the very first reply of a launch is announced by; the title is the
/// second line's topic.
func herdrFacts(_ place: ChatPlace) -> HerdrPaneFacts? {
    guard let pane = place.herdrPaneID,
          let binary = Herdr.resolveBinary(),
          // A wedged herdr is killed at the timeout, and a refusal exits
          // non-zero with its error body on standard error: an answer is a zero
          // status and a decoded body, never a status alone.
          let run = SystemCommandRunner.runBlocking(
              binary, Herdr.snapshotArguments, herdrTimeout
          ),
          run.status == 0
    else { return nil }
    return CLISay.herdrFacts(
        from: Data(run.output.utf8), pane: pane, tab: place.herdrTabID, workspace: place.herdrWorkspaceID
    )
}

/// This shell's Claude Code session file, when it is in one.
func claudeSession(environment: [String: String]) -> ClaudeSessionFile? {
    guard let path = CLISay.sessionPath(environment: environment, home: NSHomeDirectory()),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path))
    else { return nil }
    return try? JSONDecoder().decode(ClaudeSessionFile.self, from: data)
}

// MARK: - The command line

let usage = """
usage: lore transcribe <audio file>
       lore say [-v <voice>] [--dry-run] <text>
"""

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "transcribe":
    guard arguments.count == 2 else { fail(usage, code: 64) }
    transcribe(typedPath: arguments[1])
case "say":
    say(arguments: Array(arguments.dropFirst()))
default:
    fail(usage, code: 64)
}
