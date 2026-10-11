import SwiftUI
import OpenSuperWhisperCore

/// Settings → Text & AI: what happens to the text between the voice and the app. Recognition
/// hints, cleanup (hesitations, AI formatting and its engine), and how the text is inserted.
///
/// The language moved to Dictation, the dictionary to its own page, and the per-app insertion
/// rules to Style → Per app; this rubric links to the last one.
struct TextAndAIRubric: View {
    @ObservedObject var viewModel: SettingsViewModel

    static let searchEntries: [SettingsSearchEntry] = [
        entry("Instructions for the model", advanced: true,
              keywords: "initial prompt vocabulary prompt.md instructions pour le modèle vocabulaire invite"),
        entry("Use the text around the cursor", advanced: true,
              keywords: "context field surrounding texte autour du curseur contexte champ"),
        entry("Chinese, Japanese and Korean spacing", advanced: true,
              keywords: "asian autocorrect CJK espacement chinois japonais coréen"),
        entry("Remove hesitations", keywords: "filler words um uh hésitations euh hum retirer"),
        entry("Custom hesitations", advanced: true, keywords: "regex pattern filler hésitations personnalisées"),
        entry("Automatic spaces and capitals", keywords: "capitalization espaces majuscules automatiques"),
        entry("Format with AI", keywords: "LLM cleanup clean up mise en forme IA nettoyage"),
        entry("AI engine", keywords: "backend Qwen Ollama remote server built-in moteur IA serveur"),
        entry("Opening instruction", advanced: true, keywords: "prompt system instruction d'ouverture"),
        entry("When translating", advanced: true, keywords: "translation prompt traduction"),
        entry("Closing instruction", advanced: true, keywords: "prompt guardrail instruction de fin"),
        entry("If the AI fails, paste the raw text", advanced: true,
              keywords: "fallback raw si l'IA échoue texte brut"),
        entry("Default style", keywords: "style Pro par défaut"),
        entry("Paste automatically", keywords: "auto-paste insert coller automatiquement"),
        entry("Method", advanced: true, keywords: "paste typing keystrokes méthode coller simuler la frappe"),
        entry("Typing pace", advanced: true, keywords: "keystroke delay rythme de frappe"),
        entry("Also keep it on the clipboard", keywords: "copy clipboard presse-papiers copier garder"),
        entry("Give the clipboard back after", advanced: true,
              keywords: "restore clipboard delay restaurer le presse-papiers délai"),
        entry("Warn when no field is focused", keywords: "notify paste target prévenir champ actif notification"),
        entry("“press enter” sends", advanced: true, keywords: "submit return enter envoie entrée"),
        entry("Space between dictations", advanced: true, keywords: "space sentence espace entre deux dictées"),
        entry("Suppress blank output", advanced: true,
              keywords: "blank audio no speech suppress blanc silence"),
        entry("Add timestamps", advanced: true, keywords: "timestamps time horodatage"),
        entry("Per-app exceptions", advanced: true,
              keywords: "insertion by app per app exceptions par app application"),
    ]

    private static func entry(_ title: String, advanced: Bool = false, keywords: String) -> SettingsSearchEntry {
        SettingsSearchEntry(title: title, rubric: .textAndAI, advanced: advanced, keywords: keywords)
    }

    var body: some View {
        RubricPage(.textAndAI, intro: "What happens to the text between your voice and the app: cleanup, formatting, insertion.") {
            TextAIRecognitionGroup(viewModel: viewModel)
            TextAICleanupGroup(viewModel: viewModel)
            TextAIInsertionGroup(viewModel: viewModel)
        }
    }
}
