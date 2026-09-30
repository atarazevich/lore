import SwiftUI

// MARK: - Identity (#269)

/// A turn and a paragraph are keyed by their first line's record position,
/// which a rename or a merge regrouping the turns around them does not move.
extension TranscriptTurn: Identifiable {
    var id: Int { paragraphs[0].id }
}

extension TranscriptTurn.Paragraph: Identifiable {
    var id: Int { pieces[0].record }
}

extension SpeakerLabel: Identifiable {
    var id: SpeakerKey { key }

    /// You is blue; n is the nth speaker colour — the live view's rule.
    var loreColor: Color {
        (colour == 0 ? Speaker.you : .remote(colour)).loreColor
    }
}

// MARK: - The naming popover's choices

/// What the popover's Return, or a picked row, comes to.
enum SpeakerNaming: Equatable {
    /// Merge into this speaker (board §02–§03: picking a name merges).
    case assign(SpeakerKey)
    /// Someone new, by this name.
    case name(String)
}

enum SpeakerChoices {
    /// You first, then this meeting's other speakers in order of first
    /// appearance, then the people lore knows in the order the voices suggest
    /// them — never the speaker being named, never anyone twice. Someone
    /// known who is not in the meeting is drawn in the colour the merged
    /// speaker keeps.
    static func list(
        for speaker: SpeakerLabel, meeting: [SpeakerLabel], known: [SpeakerSuggestion]
    ) -> [SpeakerLabel] {
        var choices = [SpeakerLabel(key: .you, name: Speaker.you.displayLabel, colour: 0, isNameable: false)]
        var seen: Set<SpeakerKey> = [.you, speaker.key]
        for other in meeting where other.isNameable && seen.insert(other.key).inserted {
            choices.append(other)
        }
        for person in known where seen.insert(.person(person.personID)).inserted {
            choices.append(SpeakerLabel(
                key: .person(person.personID), name: person.name, colour: speaker.colour, isNameable: true))
        }
        return choices
    }

    /// Return in the field; nil changes nothing — an empty field, or the
    /// speaker's own name in any case. A name exactly one row carries
    /// (without case or surrounding spaces) merges into that row; with none,
    /// or several people of that name, it names someone new.
    static func commit(_ text: String, for speaker: SpeakerLabel, choices: [SpeakerLabel]) -> SpeakerNaming? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func same(_ name: String) -> Bool { name.localizedCaseInsensitiveCompare(typed) == .orderedSame }
        guard !typed.isEmpty, !same(speaker.name) else { return nil }
        let rows = choices.filter { same($0.name) }
        return rows.count == 1 ? .assign(rows[0].key) : .name(typed)
    }

    /// The row Return merges into, highlighted in the list as a completion
    /// list marks its choice; nil when Return names someone new or changes
    /// nothing.
    static func returnRow(_ text: String, for speaker: SpeakerLabel, choices: [SpeakerLabel]) -> SpeakerKey? {
        if case .assign(let key) = commit(text, for: speaker, choices: choices) { return key }
        return nil
    }
}

// MARK: - Views

/// The review transcript (#269, board §04): a 54 px time gutter; the
/// speaker's name as a small coloured line above each turn, on the gutter's
/// left edge; later paragraphs carry only their time; 20 pt between turns,
/// 8 pt between paragraphs. Each turn is a pinned section, so the paragraph
/// at the top of the scrolled view always shows its speaker. A meeting
/// without a speaker map reads the same way, its You/Them lines grouped by
/// the same rules (`MeetingTranscript.viewTurns`).
///
/// The live view keeps `TranscriptSpeakerRow`: You/Them, one row per line.
struct ReviewTranscriptTurns: View {
    let transcript: MeetingTranscript
    /// The meeting's start the stamps count from.
    let anchor: Date?
    /// Show original: each line's raw text in place of its cleaned one.
    let original: Bool
    /// The popover's rows for a speaker, built when it opens.
    let choices: (SpeakerLabel) -> [SpeakerLabel]
    let commit: (SpeakerLabel, SpeakerNaming) -> Void
    /// The turn whose name popover is open: every other row steps back to
    /// 0.28. Kept here, under the rows, so opening it redraws no row.
    @State var namingTurn: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            ForEach(transcript.viewTurns) { turn in
                Section {
                    ForEach(turn.paragraphs) { paragraph in
                        ReviewParagraphRow(transcript: transcript, paragraph: paragraph, anchor: anchor, original: original)
                            .equatable()
                            .padding(.top, paragraph.id == turn.id ? 0 : 8)
                            .padding(.bottom, paragraph.id == turn.paragraphs.last?.id && turn.id != transcript.viewTurns.last?.id ? 20 : 0)
                            .opacity(namingTurn == nil ? 1 : 0.28)
                    }
                } header: {
                    SpeakerNameLine(
                        speaker: turn.speaker,
                        isNaming: Binding(
                            get: { namingTurn == turn.id },
                            set: { namingTurn = $0 ? turn.id : (namingTurn == turn.id ? nil : namingTurn) }
                        ),
                        choices: { choices(turn.speaker) },
                        commit: { commit(turn.speaker, $0) }
                    )
                    .opacity(namingTurn == nil || namingTurn == turn.id ? 1 : 0.28)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: namingTurn)
        // A reload or a naming change can take the open turn away with its
        // popover; nothing may stay stepped back behind no popover.
        .onChange(of: transcript) { namingTurn = nil }
    }
}

/// A paragraph: its time into the meeting in the gutter, its text beside it,
/// at most 500 pt wide — about 85 characters of body text a line; a reply
/// inside it in secondary text. Equatable, so an unchanged paragraph is not
/// read again when the popover opens or closes.
struct ReviewParagraphRow: View, Equatable {
    let transcript: MeetingTranscript
    let paragraph: TranscriptTurn.Paragraph
    let anchor: Date?
    let original: Bool

    var body: some View {
        StampedRow(stamp: ElapsedStamp.label(paragraph.time.timeIntervalSince(anchor ?? paragraph.time), style: .intoMeeting)) {
            text
                .font(LoreTheme.Typography.body)
                // About 1.38× on 13 pt, so the 8 pt between paragraphs reads
                // clearly wider than a wrapped line. The live view keeps 4.
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: 500, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The segments in one run of text, one space apart. A reply keeps its
    /// words together (no break inside "(Name: Mm-hmm.)").
    private var text: Text {
        let pieces = transcript.segments(of: paragraph, original: original).map { segment in
            segment.isReply
                ? Text(verbatim: segment.text.replacingOccurrences(of: " ", with: "\u{00A0}"))
                    .foregroundStyle(LoreTheme.TextColor.muted)
                : Text(verbatim: segment.text).foregroundStyle(LoreTheme.TextColor.primary)
        }
        guard let first = pieces.first else { return Text(verbatim: "") }
        return pieces.dropFirst().reduce(first) { $0 + Text(verbatim: " ") + $1 }
    }
}

/// The speaker's name above a turn. A speaker the map found — never You — is
/// a button that opens the naming popover; the fill hugs the name and the
/// text never moves. Pinned at the top of the scrolled view over the lines
/// passing under it, it lies on the pinned-header backdrop, a band as tall as
/// the name line with a hairline under it; at rest it has neither.
struct SpeakerNameLine: View {
    let speaker: SpeakerLabel
    @Binding var isNaming: Bool
    let choices: () -> [SpeakerLabel]
    let commit: (SpeakerNaming) -> Void

    @State private var pinned = false

    var body: some View {
        HStack(spacing: 0) {
            if speaker.isNameable {
                Button {
                    isNaming = true
                } label: {
                    name
                        .padding(.horizontal, 6)
                        .background(
                            isNaming ? LoreTheme.Surface.card3 : .clear,
                            in: RoundedRectangle(cornerRadius: LoreTheme.Radius.button)
                        )
                        .loreHoverFill(cornerRadius: LoreTheme.Radius.button, enabled: !isNaming)
                        .padding(.horizontal, -6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Name speaker")
                .accessibilityValue(speaker.name)
                .popover(isPresented: $isNaming, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
                    SpeakerNamePopover(speaker: speaker, choices: choices()) { naming in
                        isNaming = false
                        if let naming { commit(naming) }
                    }
                }
            } else {
                name
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 1)
        .background(alignment: .top) {
            if pinned {
                LorePinnedBackdrop()
                    .overlay(alignment: .bottom) { LoreDivider() }
                    .padding(.horizontal, -24)
                    .padding(.bottom, -4)
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .scrollView).minY <= 0.5
        } action: { pinned = $0 }
    }

    private var name: some View {
        Text(speaker.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(speaker.loreColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// Naming, correcting and merging in one popover (board §02–§03): the name
/// field in the picker's header slot (Return commits, Esc cancels) and the
/// people to merge into below it. An unnamed speaker opens empty; a named one
/// opens with its name selected, so typing replaces it. The row Return acts
/// on is highlighted — the one a typed name merges into, or the one the
/// arrow keys moved to; typing hands the choice back to the name. Sized to
/// its content.
struct SpeakerNamePopover: View {
    let speaker: SpeakerLabel
    let choices: [SpeakerLabel]
    /// nil: nothing to change.
    let done: (SpeakerNaming?) -> Void

    @State private var text: String
    @State private var selection: TextSelection?
    /// The row the arrow keys moved to; nil: the typed name decides.
    @State private var moved: SpeakerKey?
    @FocusState private var focused: Bool

    static let width: CGFloat = 232

    init(speaker: SpeakerLabel, choices: [SpeakerLabel], done: @escaping (SpeakerNaming?) -> Void) {
        self.speaker = speaker
        self.choices = choices
        self.done = done
        // A voice nobody named opens empty; a name opens selected.
        let initial = if case .person = speaker.key { speaker.name } else { "" }
        _text = State(initialValue: initial)
        _selection = State(initialValue: initial.isEmpty
            ? nil
            : TextSelection(range: initial.startIndex..<initial.endIndex))
    }

    private var highlighted: SpeakerKey? {
        moved ?? SpeakerChoices.returnRow(text, for: speaker, choices: choices)
    }

    var body: some View {
        LorePickerPopover(
            header: { field },
            items: choices,
            width: Self.width,
            isActive: { _ in false },
            isHighlighted: { $0.key == highlighted },
            onSelect: { done(.assign($0.key)) },
            itemLabel: { choice in
                Text(choice.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(choice.loreColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            },
            footer: { EmptyView() }
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var field: some View {
        TextField("Name", text: $text, selection: $selection)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .focused($focused)
            .onSubmit {
                done(moved.map(SpeakerNaming.assign) ?? SpeakerChoices.commit(text, for: speaker, choices: choices))
            }
            .onExitCommand { done(nil) }
            // Plain arrows only: Shift/Cmd/Option/Control+arrow stay the field's
            // own selection and caret moves.
            .onKeyPress(.downArrow, phases: .down) { plain($0) ? move(by: 1) : .ignored }
            .onKeyPress(.upArrow, phases: .down) { plain($0) ? move(by: -1) : .ignored }
            .onChange(of: text) { moved = nil }
            .onAppear { focused = true }
            .padding(EdgeInsets(top: 3, leading: 3, bottom: 7, trailing: 3))
    }

    private func plain(_ press: KeyPress) -> Bool {
        press.modifiers.isDisjoint(with: [.shift, .command, .option, .control])
    }

    /// Down from the field lands on the first row; up from the first row
    /// hands the choice back to the typed name; the last row holds.
    private func move(by step: Int) -> KeyPress.Result {
        let next = (highlighted.flatMap { key in choices.firstIndex { $0.key == key } } ?? -1) + step
        if next < 0 {
            moved = nil
        } else if next < choices.count {
            moved = choices[next].key
        }
        return .handled
    }
}
