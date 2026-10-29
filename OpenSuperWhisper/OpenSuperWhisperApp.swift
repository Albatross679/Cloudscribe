//
//  OpenSuperWhisperApp.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import AVFoundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@main
struct OpenSuperWhisperApp: App {
    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.isRunningTests {
                    EmptyView()
                } else if appState.isCloudflareSetupPresented {
                    CloudflareSetupView()
                } else if !appState.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    ContentView()
                }
            }
            .frame(width: 450)
            .frame(minHeight: 400, maxHeight: 900)
            .foregroundStyle(Theme.text)
            .tint(Theme.accent)
            .background(Theme.background)
            .environmentObject(appState)
            .onReceive(NotificationCenter.default.publisher(for: .showCloudflareSetup)) { _ in
                appState.presentCloudflareSetup()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 450, height: 650)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    if let delegate = NSApplication.shared.delegate as? AppDelegate {
                        delegate.showMainWindow()
                    }
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "openMainWindow"))
    }

    init() {
        guard !Self.isRunningTests else { return }
        _ = ShortcutManager.shared
        _ = MicrophoneService.shared
        WhisperModelManager.shared.ensureDefaultModelPresent()
    }
}

extension OpenSuperWhisperApp {
    static func startTranscriptionQueue() {
        Task { @MainActor in
            TranscriptionQueue.shared.startProcessingQueue()
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            AppPreferences.shared.hasCompletedOnboarding = hasCompletedOnboarding
        }
    }

    @Published var isCloudflareSetupPresented: Bool

    init() {
        var onboarding = AppPreferences.shared.hasCompletedOnboarding
        #if DEBUG
        if let force = DevConfig.shared.forceShowOnboarding {
            onboarding = !force
        }
        #endif
        self.hasCompletedOnboarding = onboarding
        self.isCloudflareSetupPresented = Self.needsCloudflareSetup()
    }

    /// A configured local engine or either Cloudflare credential keeps existing
    /// installs out of the first-launch screen. New users must prove a Direct
    /// API token by transcribing their own short recording before it is saved.
    private static func needsCloudflareSetup() -> Bool {
        let prefs = AppPreferences.shared
        let hasDirectToken = !prefs.cloudflareDirectAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWorkerCredentials = !prefs.cloudflareEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prefs.cloudflareAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWhisperModel = !(prefs.selectedWhisperModelPath ?? "").isEmpty
        let hasCompletedLocalSetup = prefs.hasCompletedOnboarding && prefs.selectedEngine != "cloudflare"
        return !hasDirectToken && !hasWorkerCredentials && !hasWhisperModel && !hasCompletedLocalSetup
    }

    func completeCloudflareSetup() {
        hasCompletedOnboarding = true
        isCloudflareSetupPresented = false
        TranscriptionService.shared.reloadEngine()
    }

    func skipCloudflareSetupToSettings() {
        hasCompletedOnboarding = true
        isCloudflareSetupPresented = false
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }
    }

    func presentCloudflareSetup() {
        isCloudflareSetupPresented = true
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var languageSubmenu: NSMenu?
    private var microphoneService = MicrophoneService.shared
    private var microphoneObserver: AnyCancellable?
    private var recordingRetentionTimer: Timer?
    private var hideMainWindowAtLaunch = false
    private var cloudflareMenuPreferencesObserver: NSObjectProtocol?
    /// Display names for the Cloudflare registry, which carries none.
    private let cloudflareModelLabels = [
        "nova-3": "Deepgram Nova-3",
        "whisper-turbo": "Whisper large-v3-turbo",
        "whisper": "Whisper (base)",
        "whisper-tiny-en": "Whisper tiny (English)",
    ]
    private let cloudflareCompressionRates = [
        (value: 1.0, label: "1"),
        (value: 1.25, label: "1.25"),
        (value: 1.5, label: "1.5"),
        (value: 1.75, label: "1.75"),
        (value: 2.0, label: "2"),
        (value: 2.25, label: "2.25"),
        (value: 2.5, label: "2.5"),
        (value: 2.75, label: "2.75"),
        (value: 3.0, label: "3"),
    ]
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !OpenSuperWhisperApp.isRunningTests else { return }

        setupStatusBarItem()

        // The WindowGroup window usually does not exist yet at this point:
        // SwiftUI creates it after applicationDidFinishLaunching, so it is
        // adopted lazily from windowDidBecomeKey instead.
        if let window = Self.resolveMainWindow() {
            adoptMainWindow(window)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        // SwiftUI owns the WindowGroup window and can replace its delegate,
        // so windowWillClose on AppDelegate is not guaranteed to fire. The
        // notification is delivered regardless of who the delegate is.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        let prefs = AppPreferences.shared
        if prefs.startHiddenInMenuBar && prefs.hasCompletedOnboarding {
            hideMainWindowAtLaunch = true
            mainWindow?.orderOut(nil)
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        OpenSuperWhisperApp.startTranscriptionQueue()
        observeMicrophoneChanges()
        observeCloudflareMenuPreferenceChanges()
        
        IndicatorWindowManager.shared.warmUp()
        
        startRecordingRetentionSchedule()

        Task { @MainActor in
            await RecordingStore.shared.backfillMissingDurations()
        }
    }

    private func startRecordingRetentionSchedule() {
        cleanupOutdatedRecordings()
        
        let timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.cleanupOutdatedRecordings()
        }
        timer.tolerance = 60 * 60
        recordingRetentionTimer = timer
    }

    private func cleanupOutdatedRecordings() {
        let prefs = AppPreferences.shared
        guard prefs.autoDeleteRecordingsEnabled else { return }
        let days = prefs.autoDeleteRecordingsAfterDays
        Task { @MainActor in
            try? await RecordingStore.shared.deleteRecordings(olderThanDays: days)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard isAudioFile(url) else {
            return false
        }

        queueAudioURLs([url])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let audioURLs = filenames
            .map { URL(fileURLWithPath: $0) }
            .filter { isAudioFile($0) }

        sender.reply(toOpenOrPrint: audioURLs.isEmpty ? .failure : .success)
        queueAudioURLs(audioURLs)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let audioURLs = urls.filter { isAudioFile($0) }
        queueAudioURLs(audioURLs)
    }

    private func queueAudioURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            showMainWindow()

            for url in urls {
                await TranscriptionQueue.shared.addFileToQueue(url: url)
            }
        }
    }

    private func isAudioFile(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return contentType.conforms(to: .audio)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }
    
    private func observeCloudflareMenuPreferenceChanges() {
        cloudflareMenuPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .appPreferencesCloudflareMenuChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusBarMenu()
        }
    }

    private func observeMicrophoneChanges() {
        microphoneObserver = microphoneService.$availableMicrophones
            .sink { [weak self] _ in
                self?.updateStatusBarMenu()
            }
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            if let iconImage = NSImage(named: "tray_icon") {
                iconImage.size = NSSize(width: 48, height: 48)
                iconImage.isTemplate = true
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Cloudscribe")
            }
            
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
        }
        
        updateStatusBarMenu()
    }
    
    private func updateStatusBarMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Cloudscribe", action: #selector(openApp), keyEquivalent: "o"))
        // Shown here, chosen only in Settings. Without an action it stays disabled.
        let activeEngine = SpeechRecognitionChoice.resolve(
            engine: AppPreferences.shared.selectedEngine, provider: AppPreferences.shared.cloudProvider)
        menu.addItem(NSMenuItem(title: activeEngine.menuBarTitle, action: nil, keyEquivalent: ""))
        
        let transcriptionLanguageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageSubmenu = NSMenu()
        
        if let languageSubmenu {
            populateLanguageSubmenu(languageSubmenu)
        }
        
        transcriptionLanguageItem.submenu = languageSubmenu
        menu.addItem(transcriptionLanguageItem)

        addCloudflareQuickControls(to: menu)
        
        // Listen for language preference changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languagePreferenceChanged),
            name: .appPreferencesLanguageChanged,
            object: nil
        )
        
        menu.addItem(NSMenuItem.separator())
        
        let microphoneMenu = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        
        let microphones = microphoneService.availableMicrophones
        let currentMic = microphoneService.currentMicrophone
        
        if microphones.isEmpty {
            let noDeviceItem = NSMenuItem(title: "No microphones available", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            submenu.addItem(noDeviceItem)
        } else {
            let builtInMicrophones = microphones.filter { $0.isBuiltIn }
            let externalMicrophones = microphones.filter { !$0.isBuiltIn }
            
            for microphone in builtInMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
            
            if !builtInMicrophones.isEmpty && !externalMicrophones.isEmpty {
                submenu.addItem(NSMenuItem.separator())
            }
            
            for microphone in externalMicrophones {
                let item = NSMenuItem(
                    title: microphone.displayName,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = microphone
                
                if let current = currentMic, current.id == microphone.id {
                    item.state = .on
                }
                
                submenu.addItem(item)
            }
        }
        
        microphoneMenu.submenu = submenu
        menu.addItem(microphoneMenu)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    private func addCloudflareQuickControls(to menu: NSMenu) {
        let prefs = AppPreferences.shared
        let cloudflareIsActive = prefs.selectedEngine == "cloudflare"
        let provider = CloudProviderSelection.current
        let selectedModel = CloudProviderSelection.modelKey(for: provider)

        // The menu follows the selected provider's registry, so it can never
        // offer a model that provider has no wire form for.
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for model in CloudProviderSelection.catalog(for: provider) {
            let title = model.label == model.key ? (cloudflareModelLabels[model.key] ?? model.key) : model.label
            let item = NSMenuItem(title: title, action: #selector(selectCloudflareModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.key
            item.state = selectedModel == model.key ? .on : .off
            item.isEnabled = cloudflareIsActive
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        modelItem.isEnabled = cloudflareIsActive
        menu.addItem(modelItem)

        let compressionItem = NSMenuItem(title: "Compression rate", action: nil, keyEquivalent: "")
        let compressionMenu = NSMenu()
        for rate in cloudflareCompressionRates {
            let item = NSMenuItem(title: rate.label, action: #selector(selectCloudflareCompressionRate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rate.value
            item.state = abs(prefs.cloudflareCompressionRate - rate.value) < 0.0001 ? .on : .off
            item.isEnabled = cloudflareIsActive
            compressionMenu.addItem(item)
        }
        compressionItem.submenu = compressionMenu
        compressionItem.isEnabled = cloudflareIsActive
        menu.addItem(compressionItem)

        let cleanupItem = NSMenuItem(title: "LLM cleanup", action: #selector(toggleCloudflareCleanup(_:)), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = prefs.cloudflareCleanupEnabled ? .on : .off
        // Greyed out rather than silently doing nothing on a provider whose
        // text models this app cannot reach.
        cleanupItem.isEnabled = cloudflareIsActive && CloudProviderFeatures.of(provider).cleanup.isSupported
        menu.addItem(cleanupItem)

        menu.addItem(NSMenuItem.separator())
    }

    @objc private func selectCloudflareModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }

        let prefs = AppPreferences.shared
        // Each provider remembers its own model, so the menu writes the key
        // back to the provider that published it.
        switch CloudProviderSelection.current {
        case .cloudflare: prefs.cloudflareModel = model
        case .huggingface: prefs.huggingFaceModel = model
        case .openrouter: prefs.openRouterModel = model
        }
        let supportedLanguages = LanguageUtil.supportedLanguages(
            engine: "cloudflare",
            fluidAudioModelVersion: prefs.fluidAudioModelVersion
        )
        if !supportedLanguages.contains(prefs.whisperLanguage) {
            prefs.whisperLanguage = supportedLanguages.first ?? "auto"
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
        updateStatusBarMenu()
    }

    @objc private func selectCloudflareCompressionRate(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? NSNumber else { return }
        AppPreferences.shared.cloudflareCompressionRate = rate.doubleValue
        updateStatusBarMenu()
    }

    @objc private func toggleCloudflareCleanup(_ sender: NSMenuItem) {
        AppPreferences.shared.cloudflareCleanupEnabled.toggle()
        updateStatusBarMenu()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? MicrophoneService.AudioDevice else { return }
        microphoneService.selectMicrophone(device)
        updateStatusBarMenu()
    }
    
    @objc private func statusBarButtonClicked(_ sender: Any) {
        statusItem?.button?.performClick(nil)
    }
    
    @objc private func openApp() {
        showMainWindow()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let languageCode = sender.representedObject as? String else { return }
        
        // Update preferences
        AppPreferences.shared.whisperLanguage = languageCode
        
        // Update menu item states
        if let submenu = sender.menu {
            for item in submenu.items {
                item.state = .off
            }
            sender.state = .on
        }
    }
    
    @objc private func languagePreferenceChanged() {
        updateLanguageMenuSelection()
    }
    
    private func updateLanguageMenuSelection() {
        guard let languageSubmenu = languageSubmenu else { return }
        populateLanguageSubmenu(languageSubmenu)
    }
    
    private func populateLanguageSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        
        let supportedLanguages = LanguageUtil.supportedLanguages(
            engine: AppPreferences.shared.selectedEngine,
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
        )
        let currentLanguage = AppPreferences.shared.whisperLanguage
        
        for languageCode in supportedLanguages {
            let languageName = LanguageUtil.languageNames[languageCode] ?? languageCode
            let languageItem = NSMenuItem(title: languageName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.representedObject = languageCode
            languageItem.state = (currentLanguage == languageCode) ? .on : .off
            submenu.addItem(languageItem)
        }
    }
    
    /// The WindowGroup window must be told apart from the other windows the
    /// app creates: the status item's NSStatusBarWindow, the borderless
    /// indicator NSPanel and SwiftUI sheet host windows.
    static func isMainAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && !window.isSheet && window.styleMask.contains(.titled)
    }

    private static func resolveMainWindow() -> NSWindow? {
        NSApplication.shared.windows.first(where: isMainAppWindow)
    }

    /// SwiftUI creates the WindowGroup window after applicationDidFinishLaunching
    /// and can recreate it later, so the reference is (re)captured whenever a
    /// main-type window becomes key.
    @objc private func anyWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              Self.isMainAppWindow(window),
              window !== mainWindow
        else { return }
        adoptMainWindow(window)
    }

    private func adoptMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.delegate = self
        window.minSize = NSSize(width: 450, height: 400)
        window.maxSize = NSSize(width: 450, height: 900)
        window.backgroundColor = Theme.NSColors.background

        if hideMainWindowAtLaunch {
            hideMainWindowAtLaunch = false
            window.orderOut(nil)
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    @objc private func anyWindowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, Self.isMainAppWindow(closing) else { return }
        // Deferred so the check runs after the window has actually closed.
        DispatchQueue.main.async {
            let anyMainWindowVisible = NSApplication.shared.windows.contains {
                $0 !== closing && Self.isMainAppWindow($0) && $0.isVisible
            }
            if !anyMainWindowVisible {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }

    func showMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)

        if mainWindow == nil {
            mainWindow = Self.resolveMainWindow()
        }

        if let window = mainWindow {
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            let url = URL(string: "openSuperWhisper://openMainWindow")!
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        return NSSize(width: 450, height: frameSize.height)
    }
}
