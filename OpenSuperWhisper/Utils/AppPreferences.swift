import Foundation

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { UserDefaults.standard.object(forKey: key) as? T }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()
    private init() {
        migrateOldPreferences()
    }
    
    private func migrateOldPreferences() {
        if let oldPath = UserDefaults.standard.string(forKey: "selectedModelPath"),
           UserDefaults.standard.string(forKey: "selectedWhisperModelPath") == nil {
            UserDefaults.standard.set(oldPath, forKey: "selectedWhisperModelPath")
        }
    }
    
    // Engine settings
    @UserDefault(key: "selectedEngine", defaultValue: "whisper")
    var selectedEngine: String
    
    // Model settings
    var selectedModelPath: String? {
        get {
            if selectedEngine == "whisper" {
                return selectedWhisperModelPath
            }
            return nil
        }
        set {
            if selectedEngine == "whisper" {
                selectedWhisperModelPath = newValue
            }
        }
    }
    
    @OptionalUserDefault(key: "selectedWhisperModelPath")
    var selectedWhisperModelPath: String?
    
    @UserDefault(key: "fluidAudioModelVersion", defaultValue: "v3")
    var fluidAudioModelVersion: String

    @UserDefault(key: "cloudflareEndpoint", defaultValue: "")
    var cloudflareEndpoint: String

    @UserDefault(key: "cloudflareConnectionMode", defaultValue: "worker")
    var cloudflareConnectionMode: String

    @UserDefault(key: "cloudflareAccountID", defaultValue: "")
    var cloudflareAccountID: String

    /// User-approved local settings, separate from the app bundle. Legacy
    /// Keychain entries are preserved and imported only without prompting.
    var cloudflareAuthToken: String {
        get { AuthTokenStore.token }
        set { AuthTokenStore.token = newValue }
    }

    var cloudflareDirectAPIToken: String {
        get { AuthTokenStore.directAPIToken }
        set { AuthTokenStore.directAPIToken = newValue }
    }

    /// Which cloud transcribes: cloudflare, huggingface, or openrouter.
    /// Existing installs have no value and so keep Cloudflare.
    @UserDefault(key: "cloudProvider", defaultValue: "cloudflare")
    var cloudProvider: String

    /// Separate local settings keys per provider. Switching provider must never
    /// overwrite another vendor's key, and no two providers share one.
    var huggingFaceAPIToken: String {
        get { AuthTokenStore.key(for: .huggingface) }
        set { AuthTokenStore.setKey(newValue, for: .huggingface) }
    }

    var openRouterAPIToken: String {
        get { AuthTokenStore.key(for: .openrouter) }
        set { AuthTokenStore.setKey(newValue, for: .openrouter) }
    }

    @UserDefault(key: "cloudflareModel", defaultValue: "nova-3")
    var cloudflareModel: String

    /// A model key only means something to the vendor that publishes it, so
    /// each provider remembers its own choice rather than sharing one.
    @UserDefault(key: "huggingFaceModel", defaultValue: "whisper-large-v3-turbo")
    var huggingFaceModel: String

    @UserDefault(key: "openRouterModel", defaultValue: "whisper-large-v3-turbo")
    var openRouterModel: String

    @UserDefault(key: "huggingFaceCleanupModel", defaultValue: "llama-8b")
    var huggingFaceCleanupModel: String

    @UserDefault(key: "openRouterCleanupModel", defaultValue: "gemini-flash")
    var openRouterCleanupModel: String

    @UserDefault(key: "cloudflareCleanupEnabled", defaultValue: false)
    var cloudflareCleanupEnabled: Bool

    @UserDefault(key: "cloudflareCleanupModel", defaultValue: "llama-8b")
    var cloudflareCleanupModel: String

    /// Playback tempo used for cloud uploads. 1 keeps the original WAV.
    @UserDefault(key: "cloudflareCompressionRate", defaultValue: 1.0)
    var cloudflareCompressionRate: Double

    /// JSON map of model key to the languages it accepts, cached from the
    /// worker. "*" means unrestricted, empty means auto-detect only.
    @UserDefault(key: "cloudflareModelLanguages", defaultValue: "")
    var cloudflareModelLanguages: String
    
    @UserDefault(key: "qwen3Variant", defaultValue: "f32")
    var qwen3Variant: String
    
    @UserDefault(key: "whisperLanguage", defaultValue: "en")
    var whisperLanguage: String
    
    // Transcription settings
    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    @UserDefault(key: "initialPrompt", defaultValue: "")
    var initialPrompt: String
    
    @UserDefault(key: "useBeamSearch", defaultValue: false)
    var useBeamSearch: Bool
    
    @UserDefault(key: "beamSize", defaultValue: 5)
    var beamSize: Int
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    var playSoundOnRecordStart: Bool

    /// Removes audio the Mac plays from dictation recordings.
    @UserDefault(key: "cancelSpeakerEcho", defaultValue: true)
    var cancelSpeakerEcho: Bool
    
    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool
    
    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    var useAsianAutocorrect: Bool
    
    @OptionalUserDefault(key: "selectedMicrophoneData")
    var selectedMicrophoneData: Data?
    
    @UserDefault(key: "modifierOnlyHotkey", defaultValue: "none")
    var modifierOnlyHotkey: String
    
    /// Last non-none modifier key, used to restore the user's choice
    /// when switching back to Single Modifier Key mode.
    @UserDefault(key: "lastModifierOnlyHotkey", defaultValue: "leftCommand")
    var lastModifierOnlyHotkey: String
    
    @UserDefault(key: "mouseButtonHotkey", defaultValue: "none")
    var mouseButtonHotkey: String


    @UserDefault(key: "holdToRecord", defaultValue: true)
    var holdToRecord: Bool

    @UserDefault(key: "doublePressToTrigger", defaultValue: false)
    var doublePressToTrigger: Bool
    
    @UserDefault(key: "addSpaceAfterSentence", defaultValue: true)
    var addSpaceAfterSentence: Bool

    // Clipboard settings
    @UserDefault(key: "autoCopyToClipboard", defaultValue: false)
    var autoCopyToClipboard: Bool

    @UserDefault(key: "autoPasteTranscription", defaultValue: true)
    var autoPasteTranscription: Bool

    @UserDefault(key: "escCancelWithoutConfirmation", defaultValue: false)
    var escCancelWithoutConfirmation: Bool

    @UserDefault(key: "startHiddenInMenuBar", defaultValue: false)
    var startHiddenInMenuBar: Bool

    @UserDefault(key: "autoDeleteRecordingsEnabled", defaultValue: false)
    var autoDeleteRecordingsEnabled: Bool

    @UserDefault(key: "autoDeleteRecordingsAfterDays", defaultValue: 30)
    var autoDeleteRecordingsAfterDays: Int
}
