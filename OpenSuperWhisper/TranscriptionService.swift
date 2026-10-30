import Foundation

/// Thrown when hotkey dictation runs past `TranscriptionService.dictationDeadline`.
struct DictationDeadlineExceeded: LocalizedError {
    var errorDescription: String? {
        "Transcription took longer than \(Int(TranscriptionService.dictationDeadline.components.seconds)) seconds and was stopped. Transcribe it again from history."
    }
}

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    /// Total time hotkey dictation may spend transcribing, from key release to
    /// text, including any cleanup request. A provider that never answers would
    /// otherwise keep the indicator up and the service busy for minutes, since
    /// `URLRequest.timeoutInterval` only measures idle time between bytes.
    /// Manual transcription from history, the queue, and file imports passes
    /// no deadline and keeps the per-request timeouts.
    nonisolated static let dictationDeadline: Duration = .seconds(8)
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var isConverting = false
    @Published private(set) var conversionProgress: Float = 0.0
    
    private final class TranscriptionTaskBox {
        let task: Task<String, Error>
        init(_ task: Task<String, Error>) { self.task = task }
    }
    
    private var currentEngine: TranscriptionEngine?
    private var usageLoadedSelection: UsageSelection?
    private var transcriptionTask: TranscriptionTaskBox? = nil
    private var isCancelled = false
    private var usageServiceBusy = false
    /// Counts cancelTranscription calls, so a running call can tell that it
    /// was cancelled even after isCancelled is reset.
    private var cancelGeneration = 0
    
    private let usageMetricsStore: UsageMetricsStore

    init(metricsStore: UsageMetricsStore = .shared) {
        self.usageMetricsStore = metricsStore
        loadEngine()
    }

    /// Uses `engine` as loaded instead of the one the preferences select.
    init(metricsStore: UsageMetricsStore, engine: TranscriptionEngine) {
        self.usageMetricsStore = metricsStore
        self.currentEngine = engine
    }
    
    func cancelTranscription() {
        cancelGeneration &+= 1
        isCancelled = true
        currentEngine?.cancelTranscription()
        transcriptionTask?.task.cancel()
        transcriptionTask = nil
        
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }
    
    private func loadEngine() {
        let selectedEngine = AppPreferences.shared.selectedEngine
        let usageSelection = UsageSelection.capture(engine: selectedEngine)
        print("Loading engine: \(selectedEngine)")
        
        isLoading = true
        
        Task.detached(priority: .userInitiated) {
            let engine: TranscriptionEngine?
            
            if selectedEngine == "fluidaudio" {
                engine = FluidAudioEngine()
            } else if selectedEngine == "cloudflare" {
                engine = CloudflareEngine()
            } else {
                engine = WhisperEngine()
            }
            
            do {
                try await engine?.initialize()
                
                await MainActor.run {
                    self.currentEngine = engine
                    self.usageLoadedSelection = usageSelection
                    self.isLoading = false
                    print("Engine loaded: \(selectedEngine)")
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    print("Failed to load engine: \(error)")
                }
            }
        }
    }
    
    func reloadEngine() {
        loadEngine()
    }
    
    func reloadModel(with path: String) {
        if AppPreferences.shared.selectedEngine == "whisper" {
            AppPreferences.shared.selectedWhisperModelPath = path
            reloadEngine()
        }
    }
    
    /// With a `deadline`, throws `DictationDeadlineExceeded` once it passes,
    /// cancels the engine work, and returns without waiting for the engine to
    /// stop, so the service is free for the next call right away.
    func transcribeAudio(url: URL, settings: Settings, metricID: UUID = UUID(), recordedAt: Date? = nil,
                         deadline: ContinuousClock.Instant? = nil) async throws -> String {
        // Reserve the whole call before the asynchronous original-duration read.
        // Otherwise indicator and queue calls can both pass the engine busy check.
        while usageServiceBusy {
            if let deadline, ContinuousClock.now >= deadline { throw DictationDeadlineExceeded() }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        usageServiceBusy = true
        defer { usageServiceBusy = false }
        let generation = cancelGeneration

        // Serialize access to the engine: a whisper context must not process
        // two transcriptions concurrently (indicator flow and queue flow can
        // both reach this point due to async busy checks). A task left behind
        // by an expired deadline is drained here too, before the engine is reused.
        while let existing = transcriptionTask {
            if let deadline {
                _ = try? await Self.value(of: existing.task, before: deadline)
                if ContinuousClock.now >= deadline { throw DictationDeadlineExceeded() }
            } else {
                _ = try? await existing.task.value
            }
            if transcriptionTask === existing {
                transcriptionTask = nil
            }
        }
        
        // Read the original recording before any engine converts or speeds it up.
        let usageEngine = currentEngine
        let selection = usageEngine is CloudflareEngine ? UsageSelection.capture(engine: "cloudflare") : usageLoadedSelection ?? UsageSelection.capture(engine: AppPreferences.shared.selectedEngine)
        let date = recordedAt ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let seconds = await UsageTracking.audioSeconds(url)
        let store = usageMetricsStore
        let metricRun = store.begin(UsageDictation(id: metricID, recordedAt: date, originalSeconds: seconds,
                                                 engine: selection.engine, provider: selection.provider, model: selection.model),
                                    engine: selection.engine, provider: selection.provider, model: selection.model)
        var metricOutcome = "failure"
        defer { store.finishRun(metricRun, outcome: metricOutcome) }

        progress = 0.0
        conversionProgress = 0.0
        isConverting = true
        isTranscribing = true
        transcribedText = ""
        currentSegment = ""
        isCancelled = false
        
        var ownTask: TranscriptionTaskBox?
        var expired = false
        defer {
            isTranscribing = false
            isConverting = false
            currentSegment = ""
            if !isCancelled {
                progress = 1.0
            }
            // An expired task may still be unwinding inside the engine, so it
            // stays registered for the next call to drain.
            if !expired, let ownTask, transcriptionTask === ownTask {
                transcriptionTask = nil
            }
        }
        
        guard let engine = usageEngine else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        // Setup progress callback for engines
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        } else if let cloudflareEngine = engine as? CloudflareEngine {
            cloudflareEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    self?.progress = newProgress
                }
            }
        } else if let fluidEngine = engine as? FluidAudioEngine {
            fluidEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        }
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            // A let, so the main-actor closures below capture no mutable var.
            let service = self
            try Task.checkCancellation()
            
            let cancelled = await MainActor.run {
                guard let self = service else { return true }
                return self.isCancelled
            }
            
            guard !cancelled else {
                throw CancellationError()
            }
            
            let result = try await UsageTracking.$context.withValue(
                UsageContext(dictationID: metricID, runID: metricRun, store: store)) {
                try await engine.transcribeAudio(url: url, settings: settings)
            }
            
            try Task.checkCancellation()
            
            let finalCancelled = await MainActor.run {
                guard let self = service else { return true }
                return self.isCancelled
            }
            
            await MainActor.run {
                guard let self = service, !self.isCancelled else { return }
                self.transcribedText = result
                self.progress = 1.0
            }
            
            guard !finalCancelled else {
                throw CancellationError()
            }
            
            return result
        }
        
        let box = TranscriptionTaskBox(task)
        ownTask = box
        transcriptionTask = box
        
        do {
            let result: String
            if let deadline {
                result = try await Self.value(of: task, before: deadline)
            } else {
                result = try await task.value
            }
            // An engine that ignores cancellation still must not paste.
            guard cancelGeneration == generation else {
                metricOutcome = "cancelled"
                throw CancellationError()
            }
            metricOutcome = "success"
            return result
        } catch let error as DictationDeadlineExceeded {
            metricOutcome = "deadlineExceeded"
            expired = true
            engine.cancelTranscription()
            task.cancel()
            throw error
        } catch is CancellationError {
            metricOutcome = "cancelled"
            isCancelled = true
            if cancelGeneration != generation { throw CancellationError() }
            throw TranscriptionError.processingFailed
        } catch where cancelGeneration != generation {
            // A cancelled upload surfaces as the provider's own error.
            metricOutcome = "cancelled"
            throw CancellationError()
        }
    }

    /// The task's value, or `DictationDeadlineExceeded` once `deadline` passes,
    /// whichever comes first. Unlike a task group this does not wait for the
    /// task to finish after the deadline wins.
    private static func value(of task: Task<String, Error>, before deadline: ContinuousClock.Instant) async throws -> String {
        let race = DeadlineRace()
        return try await withCheckedThrowingContinuation { continuation in
            race.start(continuation)
            let timer = Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                race.finish(.failure(DictationDeadlineExceeded()))
            }
            Task {
                do {
                    race.finish(.success(try await task.value))
                } catch {
                    race.finish(.failure(error))
                }
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation with whichever result arrives first.
private final class DeadlineRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    func start(_ continuation: CheckedContinuation<String, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func finish(_ result: Result<String, Error>) {
        let pending: CheckedContinuation<String, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}
