import FluidAudio
import Foundation
import LoreFormat

// The voiceprint side of the speaker names (#269): what needs the embedder,
// which the `lore` command does not link. The names themselves are in
// LoreFormat, so the app and the command read a meeting's speakers alike (#301).

extension KnownVoices.Person {
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

/// A known person offered for a speaker, most alike first. `similarity` is
/// the cosine of the two voiceprints, nil when they cannot be compared (no
/// voiceprint, or one from another embedder). Data only: never applied.
public struct SpeakerSuggestion: Equatable, Sendable {
    public let personID: String
    public let name: String
    let similarity: Double?
}

extension MeetingSpeakers {
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

    /// Everyone known except this speaker, most alike first, then by name.
    public func suggestions(for key: SpeakerKey) -> [SpeakerSuggestion] {
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
}
