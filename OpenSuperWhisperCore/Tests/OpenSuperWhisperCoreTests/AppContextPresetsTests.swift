import XCTest
@testable import OpenSuperWhisperCore

/// The built-in profiles (#271): which apps they are for, and what they tell the cleanup model.
final class AppContextPresetsTests: CoreTestCase {

    private func preset(_ bundleID: String) throws -> AppContextProfile {
        try XCTUnwrap(AppContextProfile.defaultPresets.first { $0.bundleIdentifier == bundleID }, bundleID)
    }

    /// The bundle identifiers come from each app's Info.plist or its App Store listing. They are
    /// also what remembers a preset was offered, so a typo here would offer it twice.
    func testThePresetsAreForTheseApps() {
        XCTAssertEqual(AppContextProfile.defaultPresets.map(\.bundleIdentifier), [
            "com.tinyspeck.slackmacgap", "com.apple.Terminal",
            "com.apple.Notes", "com.apple.mail", "com.microsoft.Outlook", "com.apple.MobileSMS",
            "net.whatsapp.WhatsApp", "notion.id", "md.obsidian", "com.apple.Pages", "com.microsoft.Word",
        ])
    }

    func testEveryAppHasOneProfileWithInstructions() {
        let ids = AppContextProfile.defaultPresets.map { $0.bundleIdentifier.lowercased() }
        XCTAssertEqual(Set(ids).count, ids.count)
        for preset in AppContextProfile.defaultPresets {
            XCTAssertFalse(preset.appName.isEmpty, preset.bundleIdentifier)
            XCTAssertFalse(preset.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testTheFirstShippedPresetsAreTheOnesThatLeadTheList() {
        XCTAssertEqual(AppContextProfile.defaultPresets.prefix(2).map(\.bundleIdentifier),
                       AppContextProfile.firstShippedPresets.map(\.bundleIdentifier))
    }

    /// The paste cannot make checkboxes or tables yet, so no prompt may ask a model for them
    /// where the text is not Markdown.
    func testNotesDoesNotPromiseCheckboxesOrTables() throws {
        let notes = try preset("com.apple.Notes").instructions
        XCTAssertTrue(notes.contains("\"- \""))
        XCTAssertFalse(notes.contains("[ ]"))
        XCTAssertTrue(notes.contains("no checkboxes, no tables"))
    }

    func testMessagingAndMailAreNotAskedForMarkdown() throws {
        for id in ["com.apple.mail", "com.microsoft.Outlook", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
                   "com.apple.Pages", "com.microsoft.Word"] {
            let text = try preset(id).instructions
            XCTAssertTrue(text.contains("Markdown"), id)
            XCTAssertFalse(text.contains("[ ]"), id)
            XCTAssertFalse(text.contains("\"# \""), id)
        }
    }

    func testNotionAndObsidianWriteMarkdown() throws {
        for id in ["notion.id", "md.obsidian"] {
            let text = try preset(id).instructions
            XCTAssertTrue(text.contains("\"- [ ] \""), id)
            XCTAssertTrue(text.contains("\"# \""), id)
        }
    }

    func testEveryPresetIsKeptAsShippedInTheEchoReference() {
        for preset in AppContextProfile.defaultPresets {
            let reference = LLMPostProcessor.shippedInstructions(
                generalCleanup: true, generalPrompt: LLMPostProcessor.defaultInstruction, profile: preset,
                closingPrompt: LLMPostProcessor.defaultClosingInstruction, translating: false,
                translationPrompt: LLMPostProcessor.defaultTranslationInstruction)
            XCTAssertTrue(reference.contains(preset.instructions), preset.appName)
        }
    }
}
