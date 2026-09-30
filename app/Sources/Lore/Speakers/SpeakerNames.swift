import FluidAudio
import Foundation

/// The people the owner has named (#269): `Application Support/Lore/Voices/names.json`,
/// 0600, beside the owner's voiceprint.
///
/// A person's voiceprint is not stored as one vector: each meeting voice named
/// as them is kept as its own contribution, by meeting and cluster, and the
/// voiceprint is the average of those that have one. A correction moves a
/// voice's contribution to its new owner, and one voice never counts twice —
/// these are what recognition will be calibrated on. A person with no
/// contribution is named nowhere and is pruned at the next write. Nothing
/// here names a voice by itself (`no-false-positives.md`).
struct KnownVoices: Codable, Equatable, Sendable {
    static let fileName = "names.json"
    static let currentVersion = 1

    /// `Lore/Voices/` under the app's folder: the owner's voiceprint and these names.
    static func directory(in lore: URL) -> URL {
        lore.appendingPathComponent("Voices", isDirectory: true)
    }

    var version = Self.currentVersion
    var people: [Person] = []

    struct Person: Codable, Equatable, Sendable, Identifiable {
        let id: String
        var name: String
        var contributions: [Contribution] = []

        /// The average of this person's voices made with `embedder`, weighted
        /// by the speech each rests on; voiceprints from different embedders
        /// do not compare.
        func voiceprint(embedder: String) -> [Float]? {
            var average = VoiceprintAverage()
            for contribution in contributions where contribution.embedder == embedder {
                guard let vector = contribution.vector else { continue }
                average.add(vector, seconds: contribution.seconds)
            }
            return average.vector
        }
    }

    /// One meeting voice named as this person; `vector` is nil when the
    /// voice was never heard alone long enough to make a voiceprint.
    struct Contribution: Codable, Equatable, Sendable {
        let meeting: String
        let cluster: String
        let embedder: String
        let vector: [Float]?
        let seconds: Double
    }

    func person(_ id: String) -> Person? {
        people.first { $0.id == id }
    }

    /// A meeting's namings leave: it was deleted, or its speaker map replaced.
    mutating func forget(meeting: String) {
        for index in people.indices {
            people[index].contributions.removeAll { $0.meeting == meeting }
        }
    }

    /// People named nowhere any more — a name replaced by another, a deleted
    /// meeting — leave too, so they are not suggested forever.
    mutating func prune() {
        people.removeAll { $0.contributions.isEmpty }
    }
}

/// One meeting's naming (#269): `sessions/<id>/speaker-names.json`, 0600.
/// Which voice of the meeting's speaker map is which person, which was merged
/// into another, which is the owner. A voice with no entry is "Speaker N" —
/// or "You", for the microphone's main voice. A person id `names.json` does
/// not know reads as no entry.
///
/// It belongs to one speaker map: `map` is that map's `createdAt`. A new map
/// (a re-transcription re-clusters the voices) leaves these names unread
/// rather than attach them to other voices.
struct SpeakerNames: Codable, Equatable, Sendable {
    static let fileName = "speaker-names.json"
    static let currentVersion = 1

    var version = Self.currentVersion
    let map: Date
    var clusters: [String: Assignment] = [:]

    /// What one voice is. "Merge into You" is recorded here and never touches
    /// the owner's voiceprint.
    enum Assignment: Codable, Equatable, Sendable {
        case you
        case person(id: String)
        /// Merged into another voice of this meeting, and named as it is.
        case merged(into: String)
    }
}

/// Who a line's speaker is, once the map and the names apply. Two lines with
/// one key are one speaker: one name, one colour, one turn.
enum SpeakerKey: Hashable, Sendable {
    case you
    /// The system track, where no speaker map says otherwise.
    case them
    /// A diarized label from before the speaker map, read as it was stored.
    case remote(Int)
    /// A voice nobody has named, by its cluster id.
    case cluster(String)
    case person(String)

    /// A stored label, read as it was stored.
    init(_ speaker: Speaker) {
        switch speaker {
        case .you: self = .you
        case .them: self = .them
        case .remote(let n): self = .remote(n)
        }
    }
}

/// A known person offered for a speaker, most alike first. `similarity` is
/// the cosine of the two voiceprints, nil when they cannot be compared (no
/// voiceprint, or one from another embedder). Data only: never applied.
struct SpeakerSuggestion: Equatable, Sendable {
    let personID: String
    let name: String
    let similarity: Double?
}

/// A meeting's speaker map with its names: how every voice resolves to a
/// speaker, and the naming operations the popover calls. Pure — the
/// repository loads and saves it.
struct MeetingSpeakers: Equatable, Sendable {
    let map: SpeakerMap
    var names: SpeakerNames
    var voices: KnownVoices

    /// `names` made for another map are not read.
    init(map: SpeakerMap, names: SpeakerNames?, voices: KnownVoices) {
        self.map = map
        self.names = names.flatMap { $0.map == map.createdAt ? $0 : nil } ?? SpeakerNames(map: map.createdAt)
        self.voices = voices
        let mic = map.tracks.first { $0.track == .mic }?.clusters ?? []
        let dominant = mic.max {
            $0.speakingSeconds != $1.speakingSeconds ? $0.speakingSeconds < $1.speakingSeconds : $0.id > $1.id
        }?.id
        var numbers: [String: Int] = [:]
        let appearing = map.records.sorted { ($0.timestamp, $0.index) < ($1.timestamp, $1.index) }.compactMap(\.cluster)
        for id in appearing + map.tracks.flatMap({ $0.clusters.map(\.id) }) where id != dominant && numbers[id] == nil {
            numbers[id] = numbers.count + 1
        }
        dominantMicCluster = dominant
        self.numbers = numbers
    }

    /// The microphone's voice with the most speech: the owner, "You".
    let dominantMicCluster: String?
    /// One sequence per meeting, by first appearance, shared by both tracks
    /// (the dominant mic voice has none): "Speaker N" and its colour. Made
    /// from the map alone, so naming or merging never shifts a number.
    let numbers: [String: Int]

    var clusters: [SpeakerMap.Cluster] { map.tracks.flatMap(\.clusters) }

    // MARK: - Resolution

    /// The speaker a voice is, following merges.
    func key(ofCluster id: String) -> SpeakerKey {
        var current = id
        var seen: Set<String> = []
        while seen.insert(current).inserted {
            switch names.clusters[current] {
            case .you:
                return .you
            case .person(let person) where voices.person(person) != nil:
                return .person(person)
            case .merged(let target):
                current = target
            case nil, .person:
                return current == dominantMicCluster ? .you : .cluster(current)
            }
        }
        return .cluster(id)
    }

    /// Every voice of the meeting that is this speaker.
    func members(of key: SpeakerKey) -> [String] {
        clusters.map(\.id).filter { self.key(ofCluster: $0) == key }
    }

    /// The members that are this speaker by their own entry, not by a merge:
    /// what an operation changes, so the voices merged into them follow.
    func roots(of key: SpeakerKey) -> [String] {
        members(of: key).filter {
            if case .merged = names.clusters[$0] { return false }
            return true
        }
    }

    func name(of key: SpeakerKey) -> String {
        switch key {
        case .you: Speaker.you.displayLabel
        case .them: Speaker.them.displayLabel
        case .remote(let n): Speaker.remote(n).displayLabel
        case .cluster(let id): Speaker.remote(numbers[id] ?? 0).displayLabel
        case .person(let id): voices.person(id)?.name ?? Speaker.them.displayLabel
        }
    }

    /// 0 is You; n ≥ 1 is the nth speaker colour. A speaker keeps the colour
    /// of its first-appearing root, so a voice merged into it takes its colour
    /// and nobody else's changes. Stored labels keep their stored colour.
    func colour(of key: SpeakerKey) -> Int {
        key.storedColour ?? roots(of: key).compactMap { numbers[$0] }.min() ?? 0
    }

    /// The speaker's voiceprint from this meeting: its voices' averaged by the
    /// speech each rests on.
    func voiceprint(of key: SpeakerKey) -> [Float]? {
        var average = VoiceprintAverage()
        for cluster in clusters where self.key(ofCluster: cluster.id) == key {
            guard let vector = cluster.voiceprint, cluster.voiceprintSeconds > 0 else { continue }
            average.add(vector, seconds: cluster.voiceprintSeconds)
        }
        return average.vector
    }

    // MARK: - Operations

    /// Sends a speaker — all its voices in this meeting — to another speaker
    /// of this meeting (by any of its voices), someone known, or You. False
    /// when nothing changed: You, a line with no voice, or a target that
    /// already is this speaker.
    @discardableResult
    mutating func assign(_ key: SpeakerKey, to target: SpeakerKey) -> Bool {
        let resolved = if case .cluster(let id) = target { self.key(ofCluster: id) } else { target }
        let roots = movable(key)
        switch resolved {
        case .person(let id) where voices.person(id) == nil: return false
        case .them, .remote: return false
        default: break
        }
        guard !roots.isEmpty, resolved != key else { return false }
        // Into a speaker present in this meeting: merged under its first
        // root, which keeps its colour. Into You, or someone absent: named so.
        let anchor = resolved == .you
            ? nil
            : self.roots(of: resolved).min { (numbers[$0] ?? .max) < (numbers[$1] ?? .max) }
        let assignment: SpeakerNames.Assignment = switch (anchor, resolved) {
        case (let anchor?, _): .merged(into: anchor)
        case (nil, .person(let id)): .person(id: id)
        default: .you
        }
        for id in roots { names.clusters[id] = assignment }
        return true
    }

    /// Names a speaker as someone new. False for an empty name, or a speaker
    /// that cannot be named.
    @discardableResult
    mutating func name(_ key: SpeakerKey, as name: String, id: String = UUID().uuidString) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let roots = movable(key)
        guard !trimmed.isEmpty, !roots.isEmpty else { return false }
        voices.people.append(KnownVoices.Person(id: id, name: trimmed))
        for root in roots { names.clusters[root] = .person(id: id) }
        return true
    }

    /// A new name for someone known, in every meeting they were named in.
    @discardableResult
    mutating func renamePerson(_ id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = voices.people.firstIndex(where: { $0.id == id }),
              voices.people[index].name != trimmed else { return false }
        voices.people[index].name = trimmed
        return true
    }

    /// This meeting's contributions to the known voices, made again from its
    /// naming: one per voice named as a person, none for anything else. Any
    /// earlier contribution of this meeting is replaced, so a correction moves
    /// it and a voice never counts twice.
    mutating func syncContributions(meeting: String) {
        voices.forget(meeting: meeting)
        for cluster in clusters {
            guard case .person(let id) = key(ofCluster: cluster.id),
                  let index = voices.people.firstIndex(where: { $0.id == id }) else { continue }
            let vector = cluster.voiceprintSeconds > 0 ? cluster.voiceprint : nil
            voices.people[index].contributions.append(.init(
                meeting: meeting, cluster: cluster.id, embedder: map.embedder,
                vector: vector, seconds: vector == nil ? 0 : cluster.voiceprintSeconds))
        }
    }

    /// Everyone known except this speaker, most alike first, then by name.
    func suggestions(for key: SpeakerKey) -> [SpeakerSuggestion] {
        let print = voiceprint(of: key)
        return voices.people
            .filter { key != .person($0.id) }
            .map { person in
                SpeakerSuggestion(
                    personID: person.id,
                    name: person.name,
                    similarity: print.flatMap { mine in
                        person.voiceprint(embedder: map.embedder).map { Double(CampPlusEmbedder.cosine(mine, $0)) }
                    }
                )
            }
            .sorted { a, b in
                switch (a.similarity, b.similarity) {
                case let (x?, y?) where x != y: x > y
                case (.some, nil): true
                case (nil, .some): false
                default: a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
    }

    /// The roots an operation may move: a voice the map found, other than You.
    private func movable(_ key: SpeakerKey) -> [String] {
        switch key {
        case .cluster, .person: roots(of: key)
        case .you, .them, .remote: []
        }
    }
}

extension SpeakerKey {
    /// The one colour rule for a label read as it was stored — You 0, Them 1,
    /// Speaker N n — with or without a speaker map; nil for the map's voices.
    var storedColour: Int? {
        switch self {
        case .you: 0
        case .them: 1
        case .remote(let n): n
        case .cluster, .person: nil
        }
    }
}
