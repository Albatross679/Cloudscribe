import AppKit
import Carbon
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI
import FluidAudio

class SettingsViewModel: ObservableObject {
    @Published var selectedEngine: String {
        didSet {
            AppPreferences.shared.selectedEngine = selectedEngine
            if selectedEngine == "whisper" {
                loadAvailableModels()
            } else {
                initializeFluidAudioModels()
            }
            resetLanguageIfUnsupported()
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
            NotificationCenter.default.post(name: .appPreferencesCloudflareMenuChanged, object: nil)
        }
    }
    
    @Published var fluidAudioModelVersion: String {
        didSet {
            AppPreferences.shared.fluidAudioModelVersion = fluidAudioModelVersion
            if selectedEngine == "fluidaudio" {
                Task { @MainActor in
                    TranscriptionService.shared.reloadEngine()
                }
            }
            initializeFluidAudioModels()
            resetLanguageIfUnsupported()
        }
    }
    
    /// Which cloud transcribes. Cloudflare is the default and its
    /// controls are the only ones shown for it, so nothing about that path
    /// changed when the other two arrived.
    @Published var cloudProvider: String {
        didSet {
            AppPreferences.shared.cloudProvider = cloudProvider
            cloudflareTestStatus = .idle
            // Setting a cloud choice while a local engine is active must not
            // narrow local languages or schedule an intermediate reload.
            guard selectedEngine == "cloudflare" else { return }
            // The new provider's models and languages differ, so the pickers
            // must be refilled before the user can pick an impossible pairing.
            let allowed = LanguageUtil.supportedLanguages(
                engine: selectedEngine, fluidAudioModelVersion: fluidAudioModelVersion)
            if !allowed.contains(selectedLanguage) {
                selectedLanguage = allowed.first ?? "auto"
            }
            Task { @MainActor in TranscriptionService.shared.reloadEngine() }
            NotificationCenter.default.post(name: .appPreferencesCloudflareMenuChanged, object: nil)
        }
    }

    /// Present old engine/provider settings as one choice without rewriting
    /// credentials, models, or the remembered cloud provider for local engines.
    var recognitionChoice: SpeechRecognitionChoice {
        get { SpeechRecognitionChoice.resolve(engine: selectedEngine, provider: cloudProvider) }
        set {
            let selection = newValue.persistedSelection(preserving: cloudProvider)
            // Provider first: while local, its observer only persists the value.
            // The engine observer then validates language against the final pair.
            if cloudProvider != selection.provider { cloudProvider = selection.provider }
            if selectedEngine != selection.engine { selectedEngine = selection.engine }
        }
    }

    var cloudProviderCase: CloudProvider { CloudProvider.named(cloudProvider) }
    var cloudFeatures: CloudProviderFeatures { CloudProviderFeatures.of(cloudProviderCase) }

    /// The models the selected provider can actually encode.
    var cloudModels: [CloudModel] { CloudProviderSelection.catalog(for: cloudProviderCase) }
    var cloudCleanupModels: [(key: String, id: String, label: String)] {
        CloudProviderSelection.cleanupModels(for: cloudProviderCase)
    }

    /// One binding for whichever provider's model is being edited, so the
    /// picker does not need a branch per provider.
    var cloudModelSelection: String {
        get { CloudProviderSelection.modelKey(for: cloudProviderCase) }
        set {
            switch cloudProviderCase {
            case .cloudflare: cloudflareModel = newValue
            case .huggingface: huggingFaceModel = newValue
            case .openrouter: openRouterModel = newValue
            }
        }
    }

    var cloudCleanupModelSelection: String {
        get { CloudProviderSelection.cleanupModelKey(for: cloudProviderCase) }
        set {
            switch cloudProviderCase {
            case .cloudflare: cloudflareCleanupModel = newValue
            case .huggingface: huggingFaceCleanupModel = newValue
            case .openrouter: openRouterCleanupModel = newValue
            }
        }
    }

    var cloudProviderKey: String {
        get {
            switch cloudProviderCase {
            case .cloudflare: return cloudflareDirectAPIToken
            case .huggingface: return huggingFaceAPIToken
            case .openrouter: return openRouterAPIToken
            }
        }
        set {
            switch cloudProviderCase {
            case .cloudflare: cloudflareDirectAPIToken = newValue
            case .huggingface: huggingFaceAPIToken = newValue
            case .openrouter: openRouterAPIToken = newValue
            }
        }
    }

    private var isRefreshingCloudCredentials = false

    var credentialStorageMessage: String? {
        AuthTokenStore.persistenceError ?? AuthTokenStore.importMessage(
            for: cloudProviderCase, connectionMode: cloudflareConnectionMode)
    }

    func refreshLocalCredentials(importEnvironment: Bool = false) {
        if importEnvironment { AuthTokenStore.importEnvironment() }
        else { AuthTokenStore.reload() }
        isRefreshingCloudCredentials = true
        defer { isRefreshingCloudCredentials = false }
        let prefs = AppPreferences.shared
        cloudflareAuthToken = prefs.cloudflareAuthToken
        cloudflareDirectAPIToken = prefs.cloudflareDirectAPIToken
        huggingFaceAPIToken = prefs.huggingFaceAPIToken
        openRouterAPIToken = prefs.openRouterAPIToken
        cloudflareTestStatus = .idle
    }

    @Published var huggingFaceAPIToken: String {
        didSet { if !isRefreshingCloudCredentials { AppPreferences.shared.huggingFaceAPIToken = huggingFaceAPIToken } }
    }

    @Published var openRouterAPIToken: String {
        didSet { if !isRefreshingCloudCredentials { AppPreferences.shared.openRouterAPIToken = openRouterAPIToken } }
    }

    @Published var huggingFaceModel: String {
        didSet {
            AppPreferences.shared.huggingFaceModel = huggingFaceModel
            narrowLanguageToSelectedCloudModel()
        }
    }

    @Published var openRouterModel: String {
        didSet {
            AppPreferences.shared.openRouterModel = openRouterModel
            narrowLanguageToSelectedCloudModel()
        }
    }

    @Published var huggingFaceCleanupModel: String {
        didSet { AppPreferences.shared.huggingFaceCleanupModel = huggingFaceCleanupModel }
    }

    @Published var openRouterCleanupModel: String {
        didSet { AppPreferences.shared.openRouterCleanupModel = openRouterCleanupModel }
    }

    /// A newly selected model may not accept the language the old one did.
    private func narrowLanguageToSelectedCloudModel() {
        let allowed = LanguageUtil.supportedLanguages(
            engine: selectedEngine, fluidAudioModelVersion: fluidAudioModelVersion)
        if !allowed.contains(selectedLanguage) {
            selectedLanguage = allowed.first ?? "auto"
        }
        NotificationCenter.default.post(name: .appPreferencesCloudflareMenuChanged, object: nil)
    }

    @Published var cloudflareEndpoint: String {
        didSet { AppPreferences.shared.cloudflareEndpoint = cloudflareEndpoint }
    }

    @Published var cloudflareConnectionMode: String {
        didSet {
            AppPreferences.shared.cloudflareConnectionMode = cloudflareConnectionMode
            if cloudflareConnectionMode == "direct" { discoverCloudflareAccounts() }
        }
    }

    @Published var cloudflareAccountID: String {
        didSet { AppPreferences.shared.cloudflareAccountID = cloudflareAccountID }
    }

    @Published var cloudflareAccounts: [CloudflareClient.Account] = []
    private var cloudflareAccountDiscoveryTask: Task<Void, Never>?

    @Published var cloudflareAuthToken: String {
        didSet { if !isRefreshingCloudCredentials { AppPreferences.shared.cloudflareAuthToken = cloudflareAuthToken } }
    }

    @Published var cloudflareDirectAPIToken: String {
        didSet {
            guard !isRefreshingCloudCredentials else { return }
            AppPreferences.shared.cloudflareDirectAPIToken = cloudflareDirectAPIToken
            if cloudflareConnectionMode == "direct" { discoverCloudflareAccounts() }
        }
    }

    func discoverCloudflareAccounts() {
        cloudflareAccountDiscoveryTask?.cancel()
        guard !cloudflareDirectAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cloudflareAccounts = []
            return
        }
        cloudflareAccountDiscoveryTask = Task { @MainActor [weak self] in
            // SecureField updates character-by-character. Wait for a paste or
            // a brief pause instead of issuing one API request per character.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let accounts = try await CloudflareEngine.client.accounts()
                guard !Task.isCancelled else { return }
                self.cloudflareAccounts = accounts
                if !accounts.contains(where: { $0.id == self.cloudflareAccountID }) {
                    self.cloudflareAccountID = accounts[0].id
                }
            } catch {
                // Test Connection presents the API's credential error. Avoid
                // flashing an error while a user is still entering a token.
                self.cloudflareAccounts = []
            }
        }
    }

    private func refreshCloudflareAccountsForTest() async throws {
        let accounts = try await CloudflareEngine.client.accounts()
        cloudflareAccounts = accounts
        if !accounts.contains(where: { $0.id == cloudflareAccountID }) {
            cloudflareAccountID = accounts[0].id
        }
    }

    @Published var cloudflareModel: String {
        didSet {
            AppPreferences.shared.cloudflareModel = cloudflareModel
            // The new model may not accept the language the old one did.
            let allowed = LanguageUtil.supportedLanguages(
                engine: selectedEngine, fluidAudioModelVersion: fluidAudioModelVersion)
            if !allowed.contains(selectedLanguage) {
                selectedLanguage = allowed.first ?? "auto"
            }
            NotificationCenter.default.post(name: .appPreferencesCloudflareMenuChanged, object: nil)
        }
    }

    @Published var cloudflareCleanupEnabled: Bool {
        didSet {
            AppPreferences.shared.cloudflareCleanupEnabled = cloudflareCleanupEnabled
            NotificationCenter.default.post(name: .appPreferencesCloudflareMenuChanged, object: nil)
        }
    }

    @Published var cloudflareCleanupModel: String {
        didSet { AppPreferences.shared.cloudflareCleanupModel = cloudflareCleanupModel }
    }

    @Published var cloudflareCompressionRate: Double {
        didSet {
            AppPreferences.shared.cloudflareCompressionRate = cloudflareCompressionRate
            NotificationCenter.default.post(name: .appPreferencesCloudflareMenuChanged, object: nil)
        }
    }

    @Published var cloudflareTestStatus: CloudflareTestStatus = .idle

    func testCloudflareConnection() {
        cloudflareTestStatus = .testing
        Task { @MainActor in
            do {
                try AuthTokenStore.validateStorage(for: cloudProviderCase, connectionMode: cloudflareConnectionMode)
                if cloudProviderCase == .cloudflare {
                    if cloudflareConnectionMode == "direct" {
                        try await refreshCloudflareAccountsForTest()
                    }
                    let models = try await CloudflareEngine.client.validateConnection()
                    cloudflareTestStatus = .ok("Connected. \(models.count) models available.")
                } else {
                    // Reports a rejected key, an unreachable host, and a
                    // refused request as three different messages.
                    let models = try await CloudflareEngine.transcriber.validateConnection()
                    cloudflareTestStatus = .ok("Connected to \(cloudProviderCase.label). \(models.count) models available.")
                }
                TranscriptionService.shared.reloadEngine()
            } catch {
                cloudflareTestStatus = .failed(error.localizedDescription)
            }
        }
    }

    var supportedLanguages: [String] {
        LanguageUtil.supportedLanguages(engine: selectedEngine, fluidAudioModelVersion: fluidAudioModelVersion)
    }
    
    private func resetLanguageIfUnsupported() {
        if !supportedLanguages.contains(selectedLanguage) {
            selectedLanguage = LanguageUtil.fallbackLanguage(engine: selectedEngine)
        } else {
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }
    
    @Published var selectedModelURL: URL? {
        didSet {
            if let url = selectedModelURL {
                AppPreferences.shared.selectedWhisperModelPath = url.path
            }
        }
    }

    /// User-initiated model selection. Persists the model and, if the model declares a
    /// preferred language (e.g. the ivrit.ai Hebrew model), switches the language to it.
    /// Do not call from init/restore — only in response to an explicit user action.
    func selectModel(_ url: URL) {
        selectedModelURL = url
        if let lang = SettingsDownloadableModels.preferredLanguage(forFilename: url.lastPathComponent),
           selectedLanguage != lang {
            selectedLanguage = lang
        }
    }

    @Published var availableModels: [URL] = []
    
    @Published var downloadableModels: [SettingsDownloadableModel] = []
    @Published var downloadableFluidAudioModels: [SettingsFluidAudioModel] = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    private var downloadTask: Task<Void, Error>?
    
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }

    @Published var suppressBlankAudio: Bool {
        didSet {
            AppPreferences.shared.suppressBlankAudio = suppressBlankAudio
        }
    }

    @Published var showTimestamps: Bool {
        didSet {
            AppPreferences.shared.showTimestamps = showTimestamps
        }
    }
    
    @Published var temperature: Double {
        didSet {
            AppPreferences.shared.temperature = temperature
        }
    }

    @Published var noSpeechThreshold: Double {
        didSet {
            AppPreferences.shared.noSpeechThreshold = noSpeechThreshold
        }
    }

    @Published var initialPrompt: String {
        didSet {
            AppPreferences.shared.initialPrompt = initialPrompt
        }
    }

    @Published var useBeamSearch: Bool {
        didSet {
            AppPreferences.shared.useBeamSearch = useBeamSearch
        }
    }

    @Published var beamSize: Int {
        didSet {
            AppPreferences.shared.beamSize = beamSize
        }
    }

    @Published var debugMode: Bool {
        didSet {
            AppPreferences.shared.debugMode = debugMode
        }
    }
    
    @Published var playSoundOnRecordStart: Bool {
        didSet {
            AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart
        }
    }
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            if modifierOnlyHotkey != .none {
                AppPreferences.shared.lastModifierOnlyHotkey = modifierOnlyHotkey.rawValue
            }
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var mouseButtonHotkey: MouseButton {
        didSet {
            AppPreferences.shared.mouseButtonHotkey = mouseButtonHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    
    @Published var holdToRecord: Bool {
        didSet {
            AppPreferences.shared.holdToRecord = holdToRecord
        }
    }

    @Published var doublePressToTrigger: Bool {
        didSet {
            AppPreferences.shared.doublePressToTrigger = doublePressToTrigger
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    
    @Published var escCancelWithoutConfirmation: Bool {
        didSet {
            AppPreferences.shared.escCancelWithoutConfirmation = escCancelWithoutConfirmation
        }
    }

    @Published var startHiddenInMenuBar: Bool {
        didSet {
            AppPreferences.shared.startHiddenInMenuBar = startHiddenInMenuBar
        }
    }
    
    @Published var addSpaceAfterSentence: Bool {
        didSet {
            AppPreferences.shared.addSpaceAfterSentence = addSpaceAfterSentence
        }
    }

    @Published var autoCopyToClipboard: Bool {
        didSet {
            AppPreferences.shared.autoCopyToClipboard = autoCopyToClipboard
        }
    }

    @Published var autoPasteTranscription: Bool {
        didSet {
            AppPreferences.shared.autoPasteTranscription = autoPasteTranscription
        }
    }

    init() {
        let prefs = AppPreferences.shared
        self.selectedEngine = prefs.selectedEngine
        self.fluidAudioModelVersion = prefs.fluidAudioModelVersion
        self.cloudProvider = prefs.cloudProvider
        self.cloudflareEndpoint = prefs.cloudflareEndpoint
        self.cloudflareConnectionMode = prefs.cloudflareConnectionMode
        self.cloudflareAccountID = prefs.cloudflareAccountID
        self.cloudflareAuthToken = prefs.cloudflareAuthToken
        self.cloudflareDirectAPIToken = prefs.cloudflareDirectAPIToken
        self.huggingFaceAPIToken = prefs.huggingFaceAPIToken
        self.openRouterAPIToken = prefs.openRouterAPIToken
        self.cloudflareModel = prefs.cloudflareModel
        self.huggingFaceModel = prefs.huggingFaceModel
        self.openRouterModel = prefs.openRouterModel
        self.cloudflareCleanupEnabled = prefs.cloudflareCleanupEnabled
        self.cloudflareCleanupModel = prefs.cloudflareCleanupModel
        self.huggingFaceCleanupModel = prefs.huggingFaceCleanupModel
        self.openRouterCleanupModel = prefs.openRouterCleanupModel
        self.cloudflareCompressionRate = prefs.cloudflareCompressionRate
        self.selectedLanguage = prefs.whisperLanguage
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.modifierOnlyHotkey = ModifierKey(rawValue: prefs.modifierOnlyHotkey) ?? .none
        self.mouseButtonHotkey = MouseButton(rawValue: prefs.mouseButtonHotkey) ?? .none
        self.holdToRecord = prefs.holdToRecord
        self.doublePressToTrigger = prefs.doublePressToTrigger
        self.escCancelWithoutConfirmation = prefs.escCancelWithoutConfirmation
        self.startHiddenInMenuBar = prefs.startHiddenInMenuBar
        self.addSpaceAfterSentence = prefs.addSpaceAfterSentence
        self.autoCopyToClipboard = prefs.autoCopyToClipboard
        self.autoPasteTranscription = prefs.autoPasteTranscription

        if let savedPath = prefs.selectedWhisperModelPath ?? prefs.selectedModelPath {
            self.selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
        initializeDownloadableModels()
        initializeFluidAudioModels()
        
        if !supportedLanguages.contains(selectedLanguage) {
            let fallback = LanguageUtil.fallbackLanguage(engine: selectedEngine)
            selectedLanguage = fallback
            AppPreferences.shared.whisperLanguage = fallback
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }
    
    func initializeFluidAudioModels() {
        downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: model.version)
            return updatedModel
        }
    }
    
    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
        
        // Используем правильный путь к кэшу согласно документации:
        // ~/Library/Application Support/FluidAudio/Models/<version-folder>/
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        
        // Проверяем наличие всех необходимых файлов модели
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }
    
    func initializeDownloadableModels() {
        let modelManager = WhisperModelManager.shared
        downloadableModels = SettingsDownloadableModels.availableModels.map { model in
            var updatedModel = model
            let filename = model.filename
            updatedModel.isDownloaded = modelManager.isModelDownloaded(name: filename)
            return updatedModel
        }
    }
    
    func loadAvailableModels() {
        availableModels = WhisperModelManager.shared.getAvailableModels()
        if selectedModelURL == nil {
            selectedModelURL = availableModels.first
        }
        initializeDownloadableModels()
    }
    
    @MainActor
    func downloadModel(_ model: SettingsDownloadableModel) async throws {
        guard !isDownloading else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        downloadTask = Task {
            do {
                let filename = model.filename
                
                try await WhisperModelManager.shared.downloadModel(url: model.url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.downloadableModels[index].isDownloaded = true
                            }
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = 0.0
                        }
                    }
                    return
                }
                
                await MainActor.run {
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].isDownloaded = true
                        downloadableModels[index].downloadProgress = 0.0
                    }
                    loadAvailableModels()
                    let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename).path
                    selectModel(URL(fileURLWithPath: modelPath))
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    
                    Task { @MainActor in
                        TranscriptionService.shared.reloadModel(with: modelPath)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }
        
        try await downloadTask?.value
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if selectedEngine == "whisper", let model = downloadableModels.first(where: { $0.name == modelName }) {
                let filename = model.filename
                WhisperModelManager.shared.cancelDownload(name: filename)
            }
            // Reset progress for the downloading model
            if let index = downloadableModels.firstIndex(where: { $0.name == modelName }) {
                downloadableModels[index].downloadProgress = 0.0
            }
            if let index = downloadableFluidAudioModels.firstIndex(where: { $0.name == modelName }) {
                downloadableFluidAudioModels[index].downloadProgress = 0.0
            }
        }
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }
    
    @MainActor
    func downloadFluidAudioModel(_ model: SettingsFluidAudioModel) async throws {
        guard !isDownloading else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
            downloadableFluidAudioModels[index].downloadProgress = 0.0
        }
        
        var wasCancelled = false
        
        downloadTask = Task {
            do {
                let version: AsrModelVersion = model.version == "v2" ? .v2 : .v3
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let modelId = model.id
                let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] progress in
                    print("[ParakeetProgress] fraction=\(progress.fractionCompleted) phase=\(progress.phase)")
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        self.downloadProgress = progress.fractionCompleted
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == modelId }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = progress.fractionCompleted
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                
                await MainActor.run {
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].isDownloaded = true
                        downloadableFluidAudioModels[index].downloadProgress = 1.0
                    }
                    fluidAudioModelVersion = model.version
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 1.0
                    
                    Task { @MainActor in
                        TranscriptionService.shared.reloadEngine()
                    }
                }
            } catch is CancellationError {
                wasCancelled = true
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].downloadProgress = 0.0
                    }
                }
                // Don't re-throw CancellationError - it's a manual cancellation
            } catch {
                // Check if we were cancelled before the error occurred
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }
        
        // Handle cancellation gracefully - don't throw if cancelled
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            // Already handled in catch block above, just consume the error
            wasCancelled = true
        } catch {
            // If we were cancelled, don't throw
            if !wasCancelled {
                throw error
            }
        }
    }
    
    @MainActor
    func downloadFluidAudioModel() async throws {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        if let model = downloadableFluidAudioModels.first(where: { $0.version == versionString }) {
            try await downloadFluidAudioModel(model)
        }
    }
}

struct SettingsDownloadableModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let url: URL
    let size: Int
    let description: String
    var downloadProgress: Double = 0.0
    let filename: String
    let preferredLanguage: String?

    var sizeString: String {
        formatModelSize(megabytes: size)
    }

    var huggingFacePageURL: URL? {
        makeHuggingFacePageURL(fromDownloadURL: url)
    }

    init(name: String, isDownloaded: Bool, url: URL, size: Int, description: String,
         filename: String? = nil, preferredLanguage: String? = nil) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.description = description
        self.filename = filename ?? url.lastPathComponent
        self.preferredLanguage = preferredLanguage
    }
}

struct SettingsDownloadableModels {
    static let availableModels = [
        SettingsDownloadableModel(
            name: "Turbo V3 large",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1624,
            description: "High accuracy, best quality"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 medium",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
            size: 874,
            description: "Balanced speed and accuracy"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 small",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
            size: 574,
            description: "Fastest processing"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 Hebrew",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin?download=true")!,
            size: 1624,
            description: "Hebrew fine-tune of Turbo V3 by ivrit.ai. Sets the language to Hebrew.",
            filename: "ggml-ivrit-large-v3-turbo.bin",
            preferredLanguage: "he"
        )
    ]

    static func preferredLanguage(forFilename filename: String) -> String? {
        availableModels.first { $0.filename == filename }?.preferredLanguage
    }

    static func isVisible(_ model: SettingsDownloadableModel,
                          selectedLanguage: String,
                          systemLanguage: String) -> Bool {
        guard let lang = model.preferredLanguage else { return true }
        if model.isDownloaded { return true }
        return selectedLanguage == lang || systemLanguage == lang
    }
}

func countLabel(_ count: Int, singular: String, plural: String) -> String {
    count == 1 ? "\(count) \(singular)" : "\(count) \(plural)"
}

func formatModelSize(megabytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(megabytes) * 1000000)
}

func makeHuggingFacePageURL(fromDownloadURL url: URL) -> URL? {
    let absoluteString = url.absoluteString
    guard let range = absoluteString.range(of: "/resolve/") else { return nil }
    return URL(string: String(absoluteString[..<range.lowerBound]))
}

/// The Hugging Face owner (user / organization) from a model page URL,
/// e.g. https://huggingface.co/ivrit-ai/whisper-... -> "ivrit-ai".
func huggingFaceOwner(fromPageURL url: URL) -> String? {
    url.pathComponents.first { $0 != "/" }
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]
    
    var selectedLanguage: String
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool
    
    var isAsianLanguage: Bool {
        Settings.asianLanguages.contains(selectedLanguage)
    }
    
    var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }
    
    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var openRouterPrices = OpenRouterPriceBook.shared
    @StateObject private var permissionsManager = PermissionsManager()
    @Environment(\.dismiss) var dismiss
    @State private var isRecordingNewShortcut = false
    @State private var selectedTab = 0
    @State private var previousModelURL: URL?
    
    private var sheetSize: CGSize {
        let visibleFrame = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let width = min(550, visibleFrame.width - 40)
        let height = min(500, visibleFrame.height - 60)
        return CGSize(width: width, height: height)
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {

             // Shortcut Settings
            shortcutSettings
                .tabItem {
                    Label("Shortcuts", systemImage: "command")
                }
                .tag(0)
            // Model Settings
            modelSettings
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
                .tag(1)
            
            // Transcription Settings
            transcriptionSettings
                .tabItem {
                    Label("Transcription", systemImage: "text.bubble")
                }
                .tag(2)
            
            // Advanced Settings
            advancedSettings
                .tabItem {
                    Label("Advanced", systemImage: "gear")
                }
                .tag(3)
            }
        .padding()
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(Color(.windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Done") {
                    if viewModel.selectedEngine == "whisper" {
                        if viewModel.selectedModelURL != previousModelURL, let modelPath = viewModel.selectedModelURL?.path {
                            TranscriptionService.shared.reloadModel(with: modelPath)
                        }
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                
                Spacer()
                
                Link(destination: URL(string: "https://github.com/Starmel/OpenSuperWhisper")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "star")
                            .font(.system(size: 10))
                        Text("GitHub")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
        }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            if viewModel.selectedEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.selectedEngine) { _, newEngine in
            if newEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.fluidAudioModelVersion) { _, _ in
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
        .onChange(of: viewModel.selectedModelURL) { _, newURL in
            if viewModel.selectedEngine == "whisper", let modelPath = newURL?.path {
                Task { @MainActor in
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }
            }
        }
    }
    
    private var cloudflareSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API keys are plaintext in this Mac's private Application Support/OSW Cloud/credentials.json, not in the app or Keychain. Keep this file private.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = viewModel.credentialStorageMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Import keys from environment") {
                    viewModel.refreshLocalCredentials(importEnvironment: true)
                }
                Button("Reload local settings") {
                    viewModel.refreshLocalCredentials()
                }
            }
            if viewModel.cloudProviderCase == .cloudflare {
                cloudflareConnectionSettings
            } else {
                otherProviderSettings
            }

            Text("Transcription Model")
                .font(.headline)
            Picker("Model", selection: Binding(
                get: { viewModel.cloudModelSelection },
                set: { viewModel.cloudModelSelection = $0 }
            )) {
                ForEach(viewModel.cloudModels, id: \.key) { model in
                    Text(cloudModelPickerLabel(model)).tag(model.key)
                }
            }
            .labelsHidden()

            if let notes = viewModel.cloudModels.first(where: { $0.key == viewModel.cloudModelSelection })?.notes,
               !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.cloudProviderCase == .openrouter {
                OpenRouterPriceSummary(
                    book: openRouterPrices,
                    selectedModelID: viewModel.cloudModels.first(where: { $0.key == viewModel.cloudModelSelection })?.id
                )
            }

            if viewModel.cloudProviderCase == .cloudflare, viewModel.cloudflareModel == "whisper" {
                Label(
                    "Whisper base ignores the language setting and detects per clip, so short audio can come back in the wrong language.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Picker("Audio speed", selection: $viewModel.cloudflareCompressionRate) {
                Text("1").tag(1.0)
                Text("1.25").tag(1.25)
                Text("1.5").tag(1.5)
                Text("1.75").tag(1.75)
                Text("2").tag(2.0)
                Text("2.25").tag(2.25)
                Text("2.5").tag(2.5)
                Text("2.75").tag(2.75)
                Text("3").tag(3.0)
            }
            Text("Speeds up cloud uploads while preserving pitch. Higher speeds lower cost but can reduce accuracy. Applied on this Mac, so every provider honors it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Clean up dictation with an LLM", isOn: $viewModel.cloudflareCleanupEnabled)
                .disabled(!viewModel.cloudFeatures.cleanup.isSupported)

            if let reason = viewModel.cloudFeatures.cleanup.reason {
                unavailableNote(reason)
            } else if viewModel.cloudflareCleanupEnabled {
                Picker("Cleanup model", selection: Binding(
                    get: { viewModel.cloudCleanupModelSelection },
                    set: { viewModel.cloudCleanupModelSelection = $0 }
                )) {
                    ForEach(viewModel.cloudCleanupModels, id: \.key) { model in
                        Text(model.label).tag(model.key)
                    }
                }
                Text("Adds roughly 3 seconds. Removes filler words and fixes punctuation. Runs on the selected provider's own text models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Test Connection") {
                    viewModel.testCloudflareConnection()
                }

                switch viewModel.cloudflareTestStatus {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView()
                        .controlSize(.small)
                case .ok(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failed(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)

            // The setup flow proves a Cloudflare Direct API token by
            // transcribing a live recording, so it is offered only there.
            if viewModel.cloudProviderCase == .cloudflare {
                Button("Run setup again") {
                    dismiss()
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .showCloudflareSetup, object: nil)
                    }
                }
                .buttonStyle(.link)
            }

            cloudFeatureNotes
        }
        .padding(.vertical, 8)
        .onAppear {
            if viewModel.cloudProviderCase == .cloudflare, viewModel.cloudflareConnectionMode == "direct" {
                viewModel.discoverCloudflareAccounts()
            }
        }
    }

    /// What the selected provider cannot do, each with the reason. A feature
    /// that cannot reach the model is stated here rather than being accepted
    /// in the UI and dropped on the wire.
    @ViewBuilder
    private var cloudFeatureNotes: some View {
        let features = viewModel.cloudFeatures
        VStack(alignment: .leading, spacing: 6) {
            if let reason = features.language.reason {
                unavailableNote("Language pinning is unavailable. " + reason)
            } else {
                Text("Language lives in the Transcription tab.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let reason = features.vocabulary.reason {
                unavailableNote("Vocabulary boosting is unavailable. " + reason + " The cleanup pass still receives the list as known spellings.")
            } else {
                Text("Vocabulary lives in the Transcription tab. Nova-3 boosts those terms only when a language is pinned.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let reason = features.usage.reason {
                unavailableNote(reason)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func unavailableNote(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// OpenRouter entries carry their current list price, so models compare
    /// at a glance. Without a fetched price the name stands alone.
    private func cloudModelPickerLabel(_ model: CloudModel) -> String {
        let label = cloudModelLabel(model)
        guard viewModel.cloudProviderCase == .openrouter,
              let price = openRouterPrices.price(for: model.id).shortLabel else { return label }
        return label + " · " + price
    }

    private func cloudModelLabel(_ model: CloudModel) -> String {
        model.label == model.key ? cloudflareModelLabels[model.key] ?? model.key : model.label
    }

    /// The Cloudflare registry carries no display names, so the ones the picker
    /// has always shown stay here rather than changing what users read.
    private var cloudflareModelLabels: [String: String] {
        [
            "nova-3": "Nova-3 (fast, accurate)",
            "whisper-turbo": "Whisper turbo (cheapest)",
            "whisper": "Whisper base",
            "whisper-tiny-en": "Whisper tiny (English only)",
        ]
    }

    /// The other providers need one key and nothing else: no account to
    /// discover, no endpoint to deploy, no neuron budget to watch.
    private var otherProviderSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Create \(viewModel.cloudProviderCase.label) API key") {
                if let url = URL(string: viewModel.cloudProviderCase.tokenPageURL) {
                    NSWorkspace.shared.open(url)
                }
            }

            SecureField(
                viewModel.cloudProviderCase.keyFieldPrompt,
                text: Binding(
                    get: { viewModel.cloudProviderKey },
                    set: { viewModel.cloudProviderKey = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

            Text("Stored as plaintext in a private local settings file, with a separate key for each provider.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cloudflareConnectionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.headline)
            Picker("Connection", selection: $viewModel.cloudflareConnectionMode) {
                Text("Direct API").tag("direct")
                Text("Worker").tag("worker")
            }
            .pickerStyle(.segmented)

            if viewModel.cloudflareConnectionMode == "direct" {
                SecureField("Workers AI API token", text: $viewModel.cloudflareDirectAPIToken)
                    .textFieldStyle(.roundedBorder)
                if viewModel.cloudflareAccounts.count > 1 {
                    Picker("Cloudflare account", selection: $viewModel.cloudflareAccountID) {
                        ForEach(viewModel.cloudflareAccounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                } else if let account = viewModel.cloudflareAccounts.first {
                    Text("Using Cloudflare account: \(account.name)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("Paste a Workers AI API Token and the app finds its account automatically. Create one from Workers AI > Use REST API; it is saved in your private local settings file.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Worker Endpoint")
                    .font(.headline)
                TextField("https://cloud-dictation.<subdomain>.workers.dev", text: $viewModel.cloudflareEndpoint)
                    .textFieldStyle(.roundedBorder)

                Text("Auth Token")
                    .font(.headline)
                SecureField("Bearer token", text: $viewModel.cloudflareAuthToken)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var modelSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Speech Recognition Engine")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Picker("Engine", selection: Binding(
                    get: { viewModel.recognitionChoice },
                    set: { viewModel.recognitionChoice = $0 }
                )) {
                    ForEach(SpeechRecognitionChoice.allCases, id: \.rawValue) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Engine")
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

                if viewModel.selectedEngine == "cloudflare" {
                    cloudflareSettings
                }
                
                if viewModel.selectedEngine == "whisper" {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Whisper Model")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("Download Models")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                        
                        VStack(spacing: 12) {
                            ForEach($viewModel.downloadableModels) { $model in
                                if SettingsDownloadableModels.isVisible(model,
                                        selectedLanguage: viewModel.selectedLanguage,
                                        systemLanguage: LanguageUtil.getSystemLanguage()) {
                                    ModelDownloadItemView(model: $model, viewModel: viewModel)
                                }
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Models Directory:")
                                    .font(.subheadline)
                                Button(action: {
                                    NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                                }) {
                                    Label("Open Folder", systemImage: "folder")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.borderless)
                                .help("Open models directory")
                            }
                            Text(WhisperModelManager.shared.modelsDirectory.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                        }
                        .padding(.top, 8)
                    }
                } else if viewModel.selectedEngine == "fluidaudio" {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Parakeet Model")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("Download Models")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                        
                        VStack(spacing: 12) {
                            ForEach($viewModel.downloadableFluidAudioModels) { $model in
                                FluidAudioModelDownloadItemView(model: $model, viewModel: viewModel)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Models Directory:")
                                    .font(.subheadline)
                                Button(action: {
                                    let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
                                    let parentDir = cacheDir.deletingLastPathComponent()
                                    NSWorkspace.shared.open(parentDir)
                                }) {
                                    Label("Open Folder", systemImage: "folder")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.borderless)
                                .help("Open models directory")
                            }
                            Text(AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor).opacity(0.3))
            .cornerRadius(12)
        }
        .padding()
    }
    
    private var transcriptionSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Language Settings
                VStack(alignment: .leading, spacing: 16) {
                    Text("Language Settings")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcription Language")
                            .font(.subheadline)
                        
                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            ForEach(viewModel.supportedLanguages, id: \.self) { code in
                                Text(LanguageUtil.languageNames[code] ?? code)
                                    .tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                            HStack {
                                Text("Use Asian Autocorrect")
                                    .font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $viewModel.useAsianAutocorrect)
                                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                    .labelsHidden()
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Output Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Output Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Show Timestamps")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.showTimestamps)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        
                        HStack {
                            Text("Suppress Blank Audio")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.suppressBlankAudio)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add Space After Sentence")
                                    .font(.subheadline)
                                Text("Appends a space when transcription ends with punctuation")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.addSpaceAfterSentence)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Clipboard & Paste
                VStack(alignment: .leading, spacing: 16) {
                    Text("Clipboard & Paste")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Copy to Clipboard")
                                    .font(.subheadline)
                                Text("Keep transcription in clipboard after recording")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.autoCopyToClipboard)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-paste Transcription")
                                    .font(.subheadline)
                                Text("Automatically paste into the focused app")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.autoPasteTranscription)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Vocabulary
                VStack(alignment: .leading, spacing: 16) {
                    Text("Vocabulary")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $viewModel.initialPrompt)
                            .frame(height: 60)
                            .padding(6)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                        
                        Text("Terms the model should spell correctly, separated by commas. Words and names, not sentences.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Transcriptions Directory
                VStack(alignment: .leading, spacing: 16) {
                    Text("Transcriptions Directory")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Directory:")
                                .font(.subheadline)
                            Spacer()
                            Button(action: {
                                NSWorkspace.shared.open(Recording.recordingsDirectory)
                            }) {
                                Label("Open Folder", systemImage: "folder")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                            .help("Open transcriptions directory")
                        }
                        
                        Text(Recording.recordingsDirectory.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                RecordingStorageSettingsView()
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
            }
            .padding()
        }
    }
    
    private var advancedSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Decoding Strategy
                VStack(alignment: .leading, spacing: 16) {
                    Text("Decoding Strategy")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Use Beam Search")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.useBeamSearch)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                                .help("Beam search can provide better results but is slower")
                        }
                        
                        if viewModel.useBeamSearch {
                            HStack {
                                Text("Beam Size:")
                                    .font(.subheadline)
                                Spacer()
                                Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
                                    .help("Number of beams to use in beam search")
                                    .frame(width: 120)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Model Parameters
                VStack(alignment: .leading, spacing: 16) {
                    Text("Model Parameters")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Temperature:")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.temperature))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                                .help("Higher values make the output more random")
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("No Speech Threshold:")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.noSpeechThreshold))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $viewModel.noSpeechThreshold, in: 0.0...1.0, step: 0.1)
                                .help("Threshold for detecting speech vs. silence")
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Debug Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Debug Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text("Debug Mode")
                            .font(.subheadline)
                        Spacer()
                        Toggle("", isOn: $viewModel.debugMode)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                            .help("Enable additional logging and debugging information")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
    
    private enum TriggerMode: Hashable {
        case keyCombo
        case modifier
        case mouse
    }

    @ViewBuilder
    private func permissionWarning(message: String, isGranted: Bool, grantAction: @escaping () -> Void) -> some View {
        if permissionsManager.hasCompletedInitialCheck && !isGranted {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                
                Button("Grant Permission") {
                    grantAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    private var triggerMode: TriggerMode {
        if viewModel.mouseButtonHotkey != .none { return .mouse }
        if viewModel.modifierOnlyHotkey != .none { return .modifier }
        return .keyCombo
    }
    
    private var shortcutSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Recording Trigger
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Trigger")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("", selection: Binding(
                            get: { triggerMode },
                            set: { newMode in
                                switch newMode {
                                case .keyCombo:
                                    viewModel.mouseButtonHotkey = .none
                                    viewModel.modifierOnlyHotkey = .none
                                case .modifier:
                                    viewModel.mouseButtonHotkey = .none
                                    if viewModel.modifierOnlyHotkey == .none {
                                        viewModel.modifierOnlyHotkey =
                                            ModifierKey(rawValue: AppPreferences.shared.lastModifierOnlyHotkey) ?? .leftCommand
                                    }
                                case .mouse:
                                    viewModel.modifierOnlyHotkey = .none
                                    if viewModel.mouseButtonHotkey == .none {
                                        viewModel.mouseButtonHotkey = .middle
                                    }
                                }
                            }
                        )) {
                            Text("Key Combination").tag(TriggerMode.keyCombo)
                            Text("Single Modifier Key").tag(TriggerMode.modifier)
                            Text("Mouse Button").tag(TriggerMode.mouse)
                        }
                        .pickerStyle(.segmented)

                        switch triggerMode {
                        case .modifier:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Modifier Key")
                                        .font(.subheadline)
                                    Spacer()
                                    Picker("", selection: $viewModel.modifierOnlyHotkey) {
                                        ForEach(ModifierKey.allCases.filter { $0 != .none }) { key in
                                            Text(key.displayName).tag(key)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 200)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                Text(viewModel.doublePressToTrigger
                                     ? "Double-tap to toggle recording"
                                     : "One-tap to toggle recording")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Double Tap to Trigger")
                                            .font(.subheadline)
                                        Text("Require two quick taps to avoid accidental activation")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $viewModel.doublePressToTrigger)
                                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                        .labelsHidden()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                permissionWarning(
                                    message: "⚠️ This mode requires Input Monitoring permission. macOS requires this to detect single modifier key presses globally. Only modifier key events (⌘, ⌥, ⇧, ⌃, Fn) are monitored — no regular keystrokes are captured.",
                                    isGranted: permissionsManager.isInputMonitoringPermissionGranted
                                ) {
                                    permissionsManager.requestInputMonitoringPermissionOrOpenSystemPreferences()
                                }
                            }
                        case .mouse:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Mouse Button")
                                        .font(.subheadline)
                                    Spacer()
                                    Picker("", selection: $viewModel.mouseButtonHotkey) {
                                        ForEach(MouseButton.allCases.filter { $0 != .none }) { button in
                                            Text(button.displayName).tag(button)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 200)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                Text("Click to toggle recording, or hold when Hold to Record is on. The left and right buttons are reserved — pick the middle or an extra (thumb) button.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                permissionWarning(
                                    message: "⚠️ This mode requires Accessibility permission so the button can be detected globally and used only as a recording trigger. Only the selected mouse button is intercepted — no other clicks or keystrokes are captured.",
                                    isGranted: permissionsManager.isAccessibilityPermissionGranted
                                ) {
                                    permissionsManager.requestAccessibilityPermissionOrOpenSystemPreferences()
                                }
                            }
                        case .keyCombo:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Shortcut")
                                        .font(.subheadline)
                                    Spacer()
                                    KeyboardShortcuts.Recorder("", name: .toggleRecord)
                                        .frame(width: 150)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                if isRecordingNewShortcut {
                                    Text("Press your new shortcut combination...")
                                        .foregroundColor(.secondary)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Recording Behavior
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Behavior")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Hold to Record")
                                    .font(.subheadline)
                                Text("Hold the shortcut to record, release to stop")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.holdToRecord)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        
                        HStack {
                            Text("Play sound when recording starts")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.playSoundOnRecordStart)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                                .help("Play a notification sound when recording begins")
                        }
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cancel without confirmation")
                                    .font(.subheadline)
                                Text("Skip the double-Esc confirmation for recordings longer than 10 seconds")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.escCancelWithoutConfirmation)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Application
                VStack(alignment: .leading, spacing: 16) {
                    Text("Application")
                        .font(.headline)
                        .foregroundColor(.primary)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start hidden in menu bar")
                                .font(.subheadline)
                            Text("Launch without opening the main window; use the menu bar icon to open it")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.startHiddenInMenuBar)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
}

struct SettingsFluidAudioModel: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    var isDownloaded: Bool
    let description: String
    let size: Int
    var downloadProgress: Double = 0.0

    var sizeString: String {
        formatModelSize(megabytes: size)
    }
}

struct SettingsFluidAudioModels {
    static let availableModels = [
        SettingsFluidAudioModel(
            name: "Parakeet v3",
            version: "v3",
            isDownloaded: false,
            description: "Multilingual, 25 languages",
            size: 483
        ),
        SettingsFluidAudioModel(
            name: "Parakeet v2",
            version: "v2",
            isDownloaded: false,
            description: "English-only, higher recall",
            size: 464
        )
    ]
}

enum CloudflareTestStatus: Equatable {
    case idle
    case testing
    case ok(String)
    case failed(String)
}

enum OnboardingModelType {
    case whisper(url: URL, size: Int)
    case parakeet(version: String)
    case cloudflare
}

struct OnboardingUnifiedModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let description: String
    let type: OnboardingModelType
    var downloadProgress: Double = 0.0

    var huggingFacePageURL: URL? {
        switch type {
        case .whisper(let url, _):
            return makeHuggingFacePageURL(fromDownloadURL: url)
        case .parakeet(let version):
            let repo = version == "v2" ? "parakeet-tdt-0.6b-v2-coreml" : "parakeet-tdt-0.6b-v3-coreml"
            return URL(string: "https://huggingface.co/FluidInference/\(repo)")
        case .cloudflare:
            return nil
        }
    }
}

struct OnboardingUnifiedModels {
    static let availableModels = [
        OnboardingUnifiedModel(
            name: "Cloudflare",
            isDownloaded: true,
            description: "Runs online on Workers AI, nothing to download",
            type: .cloudflare
        ),
        OnboardingUnifiedModel(
            name: "Whisper V3 Large",
            isDownloaded: false,
            description: "High accuracy, best quality",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
                size: 1624
            )
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v3",
            isDownloaded: false,
            description: "Fastest processing and accurate",
            type: .parakeet(version: "v3")
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v2",
            isDownloaded: false,
            description: "Fastest processing and English-only, higher recall",
            type: .parakeet(version: "v2")
        ),
        OnboardingUnifiedModel(
            name: "Whisper Medium",
            isDownloaded: false,
            description: "Balanced speed and accuracy",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
                size: 874
            )
        ),
        OnboardingUnifiedModel(
            name: "Whisper Small",
            isDownloaded: false,
            description: "Very fast processing",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
                size: 574
            )
        )
    ]
}

struct FluidAudioModelDownloadItemView: View {
    @Binding var model: SettingsFluidAudioModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        viewModel.fluidAudioModelVersion == model.version
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        viewModel.fluidAudioModelVersion = model.version
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        Task {
                            do {
                                try await viewModel.downloadFluidAudioModel(model)
                            } catch is CancellationError {
                                // Don't show error for manual cancellation
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isDownloading)
                }
            }
        }
        .padding(12)
        .background(isSelected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                viewModel.fluidAudioModelVersion = model.version
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

struct RecordingStorageSettingsView: View {
    @State private var autoDeleteEnabled = AppPreferences.shared.autoDeleteRecordingsEnabled
    @State private var retentionDays = AppPreferences.shared.autoDeleteRecordingsAfterDays
    @State private var diskUsage: Int64 = 0
    @State private var showConfirmation = false
    @State private var pendingDays = 0
    @State private var pendingCount = 0
    @State private var pendingOldestDate: Date?

    private let dayOptions = [1, 7, 14, 30, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History Storage")
                .font(.headline)
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recordings on disk:")
                        .font(.subheadline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Delete recordings older than")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { retentionDays },
                        set: { newValue in
                            if autoDeleteEnabled {
                                requestAutoDelete(days: newValue)
                            } else {
                                retentionDays = newValue
                                AppPreferences.shared.autoDeleteRecordingsAfterDays = newValue
                            }
                        }
                    )) {
                        ForEach(dayOptions, id: \.self) { days in
                            Text(countLabel(days, singular: "day", plural: "days")).tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-delete old recordings")
                            .font(.subheadline)
                        Text("Removes both audio files and their transcriptions from history")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { autoDeleteEnabled },
                        set: { newValue in
                            if newValue {
                                requestAutoDelete(days: retentionDays)
                            } else {
                                autoDeleteEnabled = false
                                AppPreferences.shared.autoDeleteRecordingsEnabled = false
                            }
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    .labelsHidden()
                    .help("Automatically delete recordings and their transcriptions older than the selected number of days")
                }
            }
        }
        .onAppear {
            refreshDiskUsage()
        }
        .alert("Delete Old Recordings?", isPresented: $showConfirmation) {
            Button("Delete", role: .destructive) {
                confirmAutoDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(countLabel(pendingCount, singular: "recording", plural: "recordings")) with \(pendingCount == 1 ? "its transcription" : "their transcriptions") starting from \(formattedDate(pendingOldestDate)) will be deleted.")
        }
    }

    private func requestAutoDelete(days: Int) {
        Task { @MainActor in
            let result: (count: Int, oldestDate: Date?) = (try? await RecordingStore.shared.recordingsOlderThan(days: days)) ?? (count: 0, oldestDate: nil)
            if result.count > 0 {
                pendingDays = days
                pendingCount = result.count
                pendingOldestDate = result.oldestDate
                showConfirmation = true
            } else {
                applyAutoDelete(days: days)
            }
        }
    }

    private func confirmAutoDelete() {
        applyAutoDelete(days: pendingDays)
    }

    private func applyAutoDelete(days: Int) {
        retentionDays = days
        autoDeleteEnabled = true
        AppPreferences.shared.autoDeleteRecordingsAfterDays = days
        AppPreferences.shared.autoDeleteRecordingsEnabled = true
        Task { @MainActor in
            try? await RecordingStore.shared.deleteRecordings(olderThanDays: days)
            refreshDiskUsage()
        }
    }

    private func refreshDiskUsage() {
        Task.detached {
            let usage = RecordingStore.recordingsDiskUsage()
            await MainActor.run {
                diskUsage = usage
            }
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct ModelDownloadItemView: View {
    @Binding var model: SettingsDownloadableModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        if let selectedURL = viewModel.selectedModelURL {
            let filename = model.filename
            return selectedURL.lastPathComponent == filename
        }
        return false
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let pageURL = model.huggingFacePageURL,
                       let owner = huggingFaceOwner(fromPageURL: pageURL) {
                        Link(owner, destination: pageURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("View on Hugging Face")
                    }
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path
                        viewModel.selectModel(URL(fileURLWithPath: modelPath))
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        Task {
                            do {
                                try await viewModel.downloadModel(model)
                            } catch is CancellationError {
                                // Don't show error for manual cancellation
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isDownloading)
                }
            }
        }
        .padding(12)
        .background(isSelected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path
                viewModel.selectModel(URL(fileURLWithPath: modelPath))
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

