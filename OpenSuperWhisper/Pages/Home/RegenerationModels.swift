import Foundation
import OpenSuperWhisperCore

/// The families a regeneration model can belong to, in the order the picker groups them.
enum RegenerationModelFamily: CaseIterable {
    case parakeet, whisper, senseVoice, appleSpeech, remote
}

struct RegenerationModel: Equatable {
    let family: RegenerationModelFamily
    let option: DictationModelOption
}

/// The models a finished recording can be rerun with: only what would actually transcribe it
/// on this Mac right now. `ModelCatalog.allAvailable()` is wider (it lists every id the remote
/// server advertises, chat models included), which is right for deciding whether switching is
/// meaningful and wrong for a menu where choosing a row must not fail.
enum RegenerationModels {
    struct Candidates {
        var parakeet: [DictationModelOption] = []
        var whisper: [DictationModelOption] = []
        var senseVoice: [DictationModelOption] = []
        var appleSpeech: [DictationModelOption] = []
        var remote: [DictationModelOption] = []
        /// A remote server URL is set. Without one the cached model list is a leftover.
        var remoteConfigured = false
    }

    static func usable(_ candidates: Candidates) -> [RegenerationModel] {
        let remote = candidates.remoteConfigured
            ? candidates.remote.filter { RemoteModelFilter.isLikelySpeechToText($0.identifier) }
            : []
        let byFamily: [(RegenerationModelFamily, [DictationModelOption])] = [
            (.parakeet, candidates.parakeet),
            (.whisper, candidates.whisper),
            (.senseVoice, candidates.senseVoice),
            (.appleSpeech, candidates.appleSpeech),
            (.remote, remote),
        ]
        return byFamily.flatMap { family, options in
            options.map { RegenerationModel(family: family, option: $0) }
        }
    }

    static func current() -> [RegenerationModel] {
        let prefs = AppPreferences.shared
        return usable(Candidates(
            parakeet: ModelCatalog.parakeetModels(),
            whisper: ModelCatalog.whisperModels(),
            senseVoice: ModelCatalog.senseVoiceModels(),
            appleSpeech: ModelCatalog.appleSpeechModels(forLanguage: prefs.whisperLanguage),
            remote: ModelCatalog.remoteModels(),
            remoteConfigured: !prefs.remoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ))
    }
}
