import SwiftUI
import Foundation

// The hotkey dictation deadline against the real TranscriptionService and the
// real OpenRouter client. Only preferences and the engine shell are doubled.
// OpenRouter itself is replaced by a URLProtocol that can hold a request open
// forever, which is what a provider that never answers looks like to the app.
struct Settings {}
@MainActor final class AppPreferences {
    static let shared = AppPreferences()
    var selectedEngine = "cloudflare"
    var selectedWhisperModelPath: String?
}
struct UsageSelection {
    let engine: String
    let provider: String
    let model: String
    @MainActor static func capture(engine: String) -> Self {
        Self(engine: engine, provider: "openrouter", model: "openai/whisper-large-v3-turbo")
    }
}
protocol TranscriptionEngine: AnyObject {
    func initialize() async throws
    func transcribeAudio(url: URL, settings: Settings) async throws -> String
    func cancelTranscription()
}
class CloudflareEngine: TranscriptionEngine {
    var onProgressUpdate: ((Float) -> Void)?
    func initialize() async throws {}
    func transcribeAudio(url: URL, settings: Settings) async throws -> String { "" }
    func cancelTranscription() {}
}
final class WhisperEngine: CloudflareEngine {}
final class FluidAudioEngine: CloudflareEngine {}

/// The request handling of the shipping CloudflareEngine for the OpenRouter
/// provider: the upload runs in its own task and cancelTranscription cancels it.
final class OpenRouterEngine: CloudflareEngine {
    var cleanup = false
    private var uploadTask: Task<String, Error>?

    override func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        var query = [URLQueryItem(name: "model", value: "whisper-large-v3-turbo")]
        if cleanup { query.append(URLQueryItem(name: "cleanup", value: "1")) }
        let task = Task { try await OpenRouterClient(token: "test-key").transcribe(fileURL: url, query: query) }
        uploadTask = task
        defer { uploadTask = nil }
        return try await task.value
    }

    override func cancelTranscription() {
        uploadTask?.cancel()
        uploadTask = nil
    }
}

/// Stands in for openrouter.ai. Each route either answers or never answers.
final class OpenRouterStub: URLProtocol {
    enum Reply { case text(String, after: TimeInterval), never }
    nonisolated(unsafe) static var transcription = Reply.never
    nonisolated(unsafe) static var cleanup = Reply.never
    nonisolated(unsafe) static var started: [String] = []
    nonisolated(unsafe) static var stopped: [String] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "openrouter.ai" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var finished = false

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.started.append(path) }
        let reply = path.hasSuffix("/chat/completions") ? Self.cleanup : Self.transcription
        guard case let .text(text, delay) = reply else { return }
        let body = path.hasSuffix("/chat/completions")
            ? #"{"choices":[{"message":{"content":"\#(text)"}}]}"#
            : #"{"text":"\#(text)"}"#
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard Self.lock.withLock({ !finished }) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.withLock {
            finished = true
            Self.stopped.append(request.url?.path ?? "")
        }
    }

    static func reset(transcription: Reply, cleanup: Reply = .never) {
        lock.withLock {
            Self.transcription = transcription
            Self.cleanup = cleanup
            started = []
            stopped = []
        }
    }

    static var counts: (started: Int, stopped: Int) { lock.withLock { (started.count, stopped.count) } }
}

@main enum DictationDeadlineTests {
    @MainActor static func main() async throws {
        URLProtocol.registerClass(OpenRouterStub.self)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = UsageMetricsStore(url: root.appendingPathComponent("deadline-profile/usage.json"))
        let engine = OpenRouterEngine()
        let service = TranscriptionService(metricsStore: store, engine: engine)
        let wav = root.appendingPathComponent("deadline-sample.wav")
        // One second of 16kHz silent PCM.
        var data = Data()
        func text(_ text: String) { data.append(contentsOf: text.utf8) }
        func n32(_ n: Int) { data.append(contentsOf: (0..<4).map { UInt8((n >> (8 * $0)) & 255) }) }
        func n16(_ n: Int) { data.append(contentsOf: (0..<2).map { UInt8((n >> (8 * $0)) & 255) }) }
        text("RIFF"); n32(36 + 32000); text("WAVEfmt "); n32(16); n16(1); n16(1)
        n32(16000); n32(32000); n16(2); n16(16); text("data"); n32(32000); data.append(Data(count: 32000))
        try data.write(to: wav)

        precondition(TranscriptionService.dictationDeadline == .seconds(8), "the hotkey limit is 8 seconds")

        // A test deadline far shorter than 8 s keeps the run fast; the code
        // path is the one the indicator takes with the real constant.
        let limit: Duration = .milliseconds(600)
        let clock = ContinuousClock()

        // 1. OpenRouter accepts the upload and never answers.
        OpenRouterStub.reset(transcription: .never)
        var start = clock.now
        var outcome: Error?
        do {
            _ = try await service.transcribeAudio(url: wav, settings: Settings(), deadline: start + limit)
        } catch { outcome = error }
        var elapsed = clock.now - start
        precondition(outcome is DictationDeadlineExceeded, "expected the deadline error, got \(String(describing: outcome))")
        precondition(elapsed >= limit && elapsed < limit + .seconds(1), "deadline fired after \(elapsed)")
        precondition(!service.isTranscribing, "service still reports transcribing after the deadline")
        precondition((outcome as? LocalizedError)?.errorDescription?.contains("8 seconds") == true)
        // The indicator's count and outline run on the same deadline and are
        // full when the deadline error arrives.
        var indicatorClock = TranscribingClock(deadline: start + limit, limit: limit)
        indicatorClock.tick()
        precondition(indicatorClock.progress() == 1 && indicatorClock.remaining() == .zero, "outline not full at the deadline")
        precondition(indicatorClock.seconds == Int(limit.components.seconds), "count went past the limit: \(indicatorClock.seconds)")
        try await waitUntil { OpenRouterStub.counts.stopped == 1 }
        precondition(OpenRouterStub.counts == (1, 1), "the in-flight request was not cancelled: \(OpenRouterStub.counts)")
        print("PASS a request that never answers is cancelled at the deadline, after \(elapsed)")

        // 2. The next dictation starts right away and succeeds.
        OpenRouterStub.reset(transcription: .text("hello", after: 0))
        start = clock.now
        let next = try await service.transcribeAudio(url: wav, settings: Settings(), deadline: clock.now + limit)
        elapsed = clock.now - start
        precondition(next == "hello" && elapsed < limit, "next dictation took \(elapsed) and returned \(next)")
        print("PASS the next dictation runs immediately, in \(elapsed)")

        // 3. The cleanup request counts toward the same deadline.
        engine.cleanup = true
        OpenRouterStub.reset(transcription: .text("raw", after: 0), cleanup: .never)
        start = clock.now
        outcome = nil
        do {
            _ = try await service.transcribeAudio(url: wav, settings: Settings(), deadline: start + limit)
        } catch { outcome = error }
        elapsed = clock.now - start
        precondition(outcome is DictationDeadlineExceeded && elapsed < limit + .seconds(1), "cleanup escaped the deadline: \(String(describing: outcome)) after \(elapsed)")
        try await waitUntil { OpenRouterStub.counts.stopped == 2 }
        precondition(OpenRouterStub.started.last?.hasSuffix("/chat/completions") == true, "cleanup request never started")
        print("PASS a stalled cleanup request is cancelled by the same deadline")
        engine.cleanup = false

        // 4. Manual transcription passes no deadline and may run longer.
        OpenRouterStub.reset(transcription: .text("slow but fine", after: 1.5))
        start = clock.now
        let manual = try await service.transcribeAudio(url: wav, settings: Settings())
        elapsed = clock.now - start
        precondition(manual == "slow but fine" && elapsed > limit + .milliseconds(500), "manual call returned \(manual) after \(elapsed)")
        print("PASS manual transcription without a deadline waits \(elapsed) for the answer")

        // 5. The person cancels while the upload is in flight.
        OpenRouterStub.reset(transcription: .never)
        start = clock.now
        outcome = nil
        let running = Task { @MainActor in
            try await service.transcribeAudio(url: wav, settings: Settings(), deadline: clock.now + .seconds(8))
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        service.cancelTranscription()
        do { _ = try await running.value } catch { outcome = error }
        elapsed = clock.now - start
        precondition(outcome is CancellationError, "a cancel should end as CancellationError, got \(String(describing: outcome))")
        precondition(elapsed < .seconds(1), "cancel took \(elapsed)")
        try await waitUntil { OpenRouterStub.counts.stopped == 1 }
        print("PASS a cancelled dictation stops its request at once, after \(elapsed)")

        // 6. The service is free right away.
        OpenRouterStub.reset(transcription: .text("after cancel", after: 0))
        let afterCancel = try await service.transcribeAudio(url: wav, settings: Settings(), deadline: clock.now + limit)
        precondition(afterCancel == "after cancel", "dictation after a cancel returned \(afterCancel)")
        print("PASS the next dictation after a cancel succeeds")

        let runs = store.snapshot().archive.runs.map(\.outcome)
        precondition(runs == ["deadlineExceeded", "success", "deadlineExceeded", "success", "cancelled", "success"], "run outcomes \(runs)")
        print("PASS usage metrics record deadlineExceeded and a cancel as cancelled, not failure")
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "condition not met within 2 seconds")
    }
}
