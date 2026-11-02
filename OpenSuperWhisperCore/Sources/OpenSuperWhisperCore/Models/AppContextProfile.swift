import Foundation

/// Per-app formatting rules applied by the local LLM after transcription. When dictation lands
/// in a given app (matched by frontmost bundle identifier), `instructions` are folded into the
/// LLM system prompt so spoken shorthand is rewritten the way that app expects — e.g. in Slack
/// "at Rob" → "@Rob" and "slash giphy" → "/giphy".
///
/// This is independent of the general "AI Cleanup" prose pass: either can contribute to a single
/// LLM call (see `LLMPostProcessor.assembleSystemPrompt`).
public struct AppContextProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var bundleIdentifier: String   // e.g. "com.tinyspeck.slackmacgap"
    public var appName: String            // display label, e.g. "Slack"
    public var instructions: String       // natural-language formatting rules for the LLM

    public init(id: UUID = UUID(), bundleIdentifier: String = "", appName: String = "", instructions: String = "") {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.instructions = instructions
    }
}

extension AppContextProfile {
    /// Seeded once so new users get a working example they can tweak or delete.
    static let slackPreset = AppContextProfile(
        bundleIdentifier: "com.tinyspeck.slackmacgap",
        appName: "Slack",
        instructions: """
        Convert spoken Slack shorthand into the symbols Slack expects:
        - A spoken mention like "at Rob" becomes "@Rob" (no space after the @).
        - A spoken slash-command like "slash giphy" becomes "/giphy".
        Only rewrite these when they are clearly meant as a mention or command. Leave all other \
        words exactly as written — do not add, remove, or rephrase anything else.
        """)

    /// Terminal preset: turn spoken programming shorthand into the exact symbols/identifiers a
    /// developer means. Seeded for Apple's Terminal; users on iTerm/Warp/Ghostty can re-pick the app.
    static let terminalPreset = AppContextProfile(
        bundleIdentifier: "com.apple.Terminal",
        appName: "Terminal",
        instructions: """
        Convert spoken programming shorthand into the exact symbols and identifiers a developer \
        means. Output only the converted text — no explanation, no surrounding quotes, no trailing period.

        Spoken word to symbol (when used as a symbol):
        slash → /   backslash → \\   dash or hyphen → -   dot or period → .   underscore → _
        colon → :   double colon → ::   semicolon → ;   comma → ,   pipe → |   ampersand → &
        at → @   hash or pound → #   dollar → $   percent → %   caret → ^   star or asterisk → *
        tilde → ~   backtick → `   equals → =   plus → +   question mark → ?   bang → !
        open/close paren → ( )   open/close brace → { }   open/close bracket → [ ]
        less than → <   greater than → >   double dash → --

        Identifiers and ticket keys:
        - Letters and digits that form an identifier join with NO spaces; uppercase project keys.
          "ENG dash one zero five one six" → ENG-10516 ;  "PROJ dash four two" → PROJ-42
        - A run of spoken digits becomes concatenated numerals: "three zero zero zero" → 3000
        - "dash dash help" → --help ;  "dash l" → -l

        Rules:
        - No spaces around / . - _ : in paths, identifiers, or flags: "src slash main dot swift" → src/main.swift
        - Keep commands and flags lowercase unless letters are clearly an uppercase key (a ticket prefix).
        - Do not capitalize the start or add ending punctuation — this is a command line, not prose.
        - If a word is clearly an English word, not a symbol, leave it. When in doubt in a terminal, prefer the symbol.

        Examples:
        "cd src slash app" → cd src/app
        "git checkout dash b feature slash login" → git checkout -b feature/login
        "ENG dash one zero five one six" → ENG-10516
        "npm run dash dash watch" → npm run --watch
        "cat readme dot md" → cat readme.md
        """)

    static let notesPreset = AppContextProfile(
        bundleIdentifier: "com.apple.Notes",
        appName: "Notes",
        instructions: """
        Write the dictation as a note. A title that is dictated goes on its own line, with no \
        period. When the speaker enumerates things to do, to buy or to remember, write one item \
        per line starting with "- ". Otherwise keep short paragraphs. Do not use Markdown \
        symbols (no #, no **, no checkboxes, no tables) and do not add, remove or rephrase \
        anything else.
        """)

    static let mailPreset = AppContextProfile(
        bundleIdentifier: "com.apple.mail",
        appName: "Mail",
        instructions: emailInstructions)

    static let outlookPreset = AppContextProfile(
        bundleIdentifier: "com.microsoft.Outlook",
        appName: "Microsoft Outlook",
        instructions: emailInstructions)

    private static let emailInstructions = """
        Write the dictation as an email. Put the greeting ("Hello Anna,") on its own line, then \
        the body in short paragraphs separated by a blank line, then the sign-off ("Best \
        regards,") and the name each on their own line. Keep the speaker's words and tone. No \
        Markdown symbols.
        """

    static let messagesPreset = AppContextProfile(
        bundleIdentifier: "com.apple.MobileSMS",
        appName: "Messages",
        instructions: chatInstructions)

    static let whatsAppPreset = AppContextProfile(
        bundleIdentifier: "net.whatsapp.WhatsApp",
        appName: "WhatsApp",
        instructions: chatInstructions)

    private static let chatInstructions = """
        Write the dictation as a chat message: short sentences, casual tone kept as spoken, no \
        greeting or sign-off added. No formatting of any kind: no Markdown, no bullets, no \
        headings. Do not add, remove or rephrase anything else.
        """

    static let notionPreset = AppContextProfile(
        bundleIdentifier: "notion.id",
        appName: "Notion",
        instructions: markdownNotesInstructions)

    static let obsidianPreset = AppContextProfile(
        bundleIdentifier: "md.obsidian",
        appName: "Obsidian",
        instructions: markdownNotesInstructions)

    private static let markdownNotesInstructions = """
        Write the dictation as Markdown. A spoken to-do list becomes "- [ ] " lines, one task per \
        line. Any other enumeration becomes "- " lines, or "1. " lines when the speaker \
        numbered it. A title that is dictated becomes a "# " heading on its own line. Keep \
        everything else as plain paragraphs and do not add, remove or rephrase anything.
        """

    static let pagesPreset = AppContextProfile(
        bundleIdentifier: "com.apple.Pages",
        appName: "Pages",
        instructions: documentInstructions)

    static let wordPreset = AppContextProfile(
        bundleIdentifier: "com.microsoft.Word",
        appName: "Microsoft Word",
        instructions: documentInstructions)

    private static let documentInstructions = """
        Write the dictation as document text: clean paragraphs with full sentences and correct \
        punctuation. When the speaker enumerates items, write one per line starting with "- ". A \
        title that is dictated goes on its own line, with no period. Do not use Markdown symbols \
        (no #, no **, no tables) and do not add, remove or rephrase anything else.
        """

    /// The built-in profiles, in the order they are offered. A fresh install gets them all; an
    /// existing install gets the ones it was not offered yet (see
    /// `AppPreferences.seedAppContextPresetsIfNeeded`). Append new ones at the end and never
    /// reuse a bundle identifier: it is what remembers a preset was already offered.
    public static let defaultPresets: [AppContextProfile] = [
        slackPreset, terminalPreset,
        notesPreset, mailPreset, outlookPreset, messagesPreset, whatsAppPreset,
        notionPreset, obsidianPreset, pagesPreset, wordPreset,
    ]

    /// The two presets every install seeded before the list grew. An install that has seeded and
    /// recorded nothing else was offered exactly these.
    public static let firstShippedPresets: [AppContextProfile] = [slackPreset, terminalPreset]
}
