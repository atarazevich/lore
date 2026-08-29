import Foundation

/// What kind of thing rode along with a dictation (#192). A closed set: the
/// clipboard door classifies file-url > image > url > text and nothing else
/// becomes an item.
enum DictationItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case fileURL
    case url
}

/// One thing the user copied — or screenshotted to the clipboard — while a
/// dictation was recording (#192). It carries the second of the speech it
/// belongs to, not the second it was noticed by anything downstream: a row
/// switched on at 0:31 still lands its screenshot at 0:09.
///
/// The same value is both the live item behind the indicator's count and the
/// record persisted on the history entry. `imageData` is the one field that
/// does not survive the entry: by the time the entry is written the bytes are a
/// PNG at `path`, and a second copy inside the JSON would be the same picture
/// twice.
struct DictationItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: DictationItemKind
    /// Seconds into this dictation's audio (t=0 is the pre-buffer's first
    /// sample, which is where the transcript's own timings start too).
    var offset: Double
    /// Copied text, or a URL as the user copied it. Nil for an image or a file.
    var text: String?
    /// Absolute path: the PNG lore wrote for a clipboard image, or the file the
    /// user copied in Finder. Nil for text and URLs.
    var path: String?
    /// Whether it travels with the paste. True from the moment it is collected;
    /// the list's row is the switch.
    var included: Bool
    /// The image's bytes, read at copy time because the next copy overwrites
    /// them. Never encoded — see the type's note.
    var imageData: Data?

    init(
        id: UUID = UUID(),
        kind: DictationItemKind,
        offset: Double,
        text: String? = nil,
        path: String? = nil,
        included: Bool = true,
        imageData: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.offset = offset
        self.text = text
        self.path = path
        self.included = included
        self.imageData = imageData
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, offset, text, path, included
    }

    /// What this item contributes to the prompt, tagged by what it is so that
    /// whoever reads the paste — a model or a person — can tell inserted
    /// material from spoken words. Copied text is fenced across its own lines
    /// because it can be a paragraph; a path or a URL is one line and is not
    /// quoted, the tag being the fence a name with spaces in it needs.
    ///
    /// Nil when the item has nothing to contribute — an image whose file could
    /// not be written names a picture that is not there.
    var pasteText: String? {
        switch kind {
        case .text:
            guard let text, !text.isEmpty else { return nil }
            return "<copied>\n\(text)\n</copied>"
        case .url:
            guard let text, !text.isEmpty else { return nil }
            return "<link>\(text)</link>"
        case .image:
            guard let path, !path.isEmpty else { return nil }
            return "<screenshot>\(path)</screenshot>"
        case .fileURL:
            guard let path, !path.isEmpty else { return nil }
            return "<file>\(path)</file>"
        }
    }

    /// How much this item weighs, for the diagnostic stream: a picture's PNG
    /// bytes, or the UTF-8 length of the words, URL or path it carries. A
    /// number about the content, never the content (#82).
    var byteCount: Int {
        if let imageData { return imageData.count }
        return (text ?? path)?.utf8.count ?? 0
    }
}
