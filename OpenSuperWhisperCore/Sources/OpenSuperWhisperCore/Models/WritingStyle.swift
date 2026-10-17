import Foundation

/// A voice the AI cleanup writes in: Pro for work, Personal for friends, or one the user writes,
/// such as the tone a charity asks its volunteers to use (#160). The instructions go into the
/// cleanup prompt between the general instruction and the app's own rules, so per-app formatting
/// still applies inside a style.
public struct WritingStyle: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var instructions: String

    public init(id: String = UUID().uuidString, name: String, instructions: String) {
        self.id = id
        self.name = name
        self.instructions = instructions
    }

    public static let rawID = "raw"
    public static let proID = "pro"
    public static let personalID = "personal"

    /// No instructions of its own: the cleanup does what the general instruction says, exactly as
    /// before styles existed, which is why it is the default.
    public static let raw = WritingStyle(id: rawID, name: "Raw", instructions: "")

    public static let pro = WritingStyle(id: proID, name: "Pro", instructions: """
        Style: professional. Write complete sentences with careful punctuation and \
        capitalization. Drop slang, filler words and repetitions, and prefer the precise word. \
        Keep the speaker's meaning and every fact, name and number exactly as said.
        """)

    /// Apple's model reads any "like a friend" wording as a text message and drops capitals and
    /// punctuation; the sentence asking to keep them helps the 7B model and costs nothing.
    public static let personal = WritingStyle(id: personalID, name: "Personal", instructions: """
        Style: personal, the way a friend would write a message: warm and relaxed, with \
        contractions and short sentences. Remove hesitations such as "um" and "uh". Sentences \
        still start with a capital letter and end with punctuation. Keep the speaker's meaning \
        and every fact, name and number exactly as said.
        """)

    public static let builtIns = [raw, pro, personal]

    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    /// The style `id` names among the built-ins and `custom`, Raw when it names none, such as a
    /// custom style deleted while an app rule still pointed at it.
    public static func resolve(_ id: String?, custom: [WritingStyle]) -> WritingStyle {
        (builtIns + custom).first { $0.id == id } ?? raw
    }
}
