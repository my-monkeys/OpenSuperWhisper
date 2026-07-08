import Foundation

/// Per-app formatting rules applied by the local LLM after transcription. When dictation lands
/// in a given app (matched by frontmost bundle identifier), `instructions` are folded into the
/// LLM system prompt so spoken shorthand is rewritten the way that app expects — e.g. in Slack
/// "at Rob" → "@Rob" and "slash giphy" → "/giphy".
///
/// This is independent of the general "AI Cleanup" prose pass: either can contribute to a single
/// LLM call (see `LLMPostProcessor.assembleSystemPrompt`).
struct AppContextProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleIdentifier: String   // e.g. "com.tinyspeck.slackmacgap"
    var appName: String            // display label, e.g. "Slack"
    var instructions: String       // natural-language formatting rules for the LLM

    init(id: UUID = UUID(), bundleIdentifier: String = "", appName: String = "", instructions: String = "") {
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

    /// The presets seeded into a fresh install (one-time; see `AppPreferences.seedAppContextPresetsIfNeeded`).
    static let defaultPresets: [AppContextProfile] = [slackPreset, terminalPreset]
}
