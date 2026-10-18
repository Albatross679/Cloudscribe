import Foundation
import Combine

/// Current OpenRouter list prices for the speech-to-text models in the picker.
///
/// GET /api/v1/models?output_modalities=transcription is public and needs no
/// key. Each model's `pricing` object holds USD strings, but the response does
/// not say what one unit is: `prompt` means an audio second for most speech
/// models, an audio hour for others, and an input token for the GPT-4o and
/// Gemini transcription models. `units` therefore records the unit OpenRouter
/// publishes on each model page (its provider table header reads Audio/sec,
/// Audio/hr, or Input/M and Output/M), checked 2026-10-18. A model without a
/// recorded unit shows its raw field values instead of a guessed conversion.
enum OpenRouterPricing {
    static let endpoint = URL(string: "\(OpenRouterRequest.host)/models?output_modalities=transcription")!

    enum Unit: Equatable {
        /// `prompt` is USD per second of audio.
        case audioSecond
        /// `prompt` is USD per hour of audio.
        case audioHour
        /// `prompt` and `completion` are USD per input and output token.
        case token
    }

    static let units: [String: Unit] = [
        "openai/whisper-large-v3-turbo": .audioSecond,
        "openai/whisper-large-v3": .audioSecond,
        "deepgram/nova-3": .audioSecond,
        "openai/gpt-4o-mini-transcribe": .token,
        "openai/gpt-4o-transcribe": .token,
        "google/gemini-3.5-transcribe": .token,
        "fish-audio/transcribe-1-pro": .audioSecond,
        "assemblyai/universal-3-5-pro": .audioSecond,
        "meta/muse-voice-transcribe-1.0": .audioSecond,
        "microsoft/mai-transcribe-2": .audioHour,
        "qwen/qwen3-asr-1.7b": .audioSecond,
        "qwen/qwen3-asr-0.6b": .audioSecond,
        "openai/gpt-transcribe": .audioSecond,
        "elevenlabs/scribe-v2": .audioSecond,
        "elevenlabs/scribe-v2-medical": .audioSecond,
        "assemblyai/universal-3-6-pro": .audioSecond,
        "fish-audio/transcribe-1": .audioSecond,
        "google/chirp-3": .audioSecond,
        "microsoft/mai-transcribe-1.5": .audioHour,
        "mistralai/voxtral-mini-3b-2507": .audioSecond,
        "mistralai/voxtral-mini-transcribe": .audioSecond,
        "mistralai/voxtral-small-24b-2507-stt": .audioSecond,
        "nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b": .audioSecond,
        "nvidia/parakeet-tdt-0.6b-v3": .audioSecond,
        "openai/whisper-1": .audioSecond,
        "x-ai/grok-stt-1.0": .audioSecond,
    ]

    /// One `pricing` field exactly as OpenRouter sent it.
    struct RawField: Equatable {
        let name: String
        let value: String
    }

    enum Price: Equatable {
        case perAudioMinute(Double)
        case perMillionTokens(input: Double, output: Double)
        /// The unit is not established, so nothing is converted.
        case raw([RawField])
        /// The model is missing from the fetched list, or nothing is cached.
        case unavailable

        var label: String {
            switch self {
            case .perAudioMinute(let usd):
                return "\(money(usd)) per audio minute"
            case .perMillionTokens(let input, let output):
                return "\(money(input)) input · \(money(output)) output per 1M tokens"
            case .raw(let fields):
                return "OpenRouter " + fields.map { "\($0.name) \($0.value)" }.joined(separator: ", ") + " (unit not published)"
            case .unavailable:
                return "Price unavailable"
            }
        }

        /// Fits beside a model name in the picker; nil leaves the name alone.
        var shortLabel: String? {
            switch self {
            case .perAudioMinute(let usd): return "\(money(usd))/min"
            case .perMillionTokens(let input, let output): return "\(money(input)) in, \(money(output)) out /1M tokens"
            case .raw, .unavailable: return nil
            }
        }
    }

    /// Model id to its `pricing` fields. Throws when the body is not the
    /// models list, so a broken response never replaces a good cache.
    static func parse(_ data: Data) throws -> [String: [String: String]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var result: [String: [String: String]] = [:]
        for model in models {
            guard let id = model["id"] as? String, let pricing = model["pricing"] as? [String: Any] else { continue }
            var fields: [String: String] = [:]
            for (name, value) in pricing {
                if let text = value as? String { fields[name] = text }
                else if let number = value as? NSNumber { fields[name] = number.stringValue }
            }
            result[id] = fields
        }
        guard !result.isEmpty else { throw CocoaError(.propertyListReadCorrupt) }
        return result
    }

    static func price(for id: String, in pricing: [String: [String: String]]?) -> Price {
        guard let fields = pricing?[id] else { return .unavailable }
        let prompt = fields["prompt"].flatMap(Double.init)
        let completion = fields["completion"].flatMap(Double.init)
        switch units[id] {
        case .audioSecond?:
            if let prompt { return .perAudioMinute(prompt * 60) }
        case .audioHour?:
            if let prompt { return .perAudioMinute(prompt / 60) }
        case .token?:
            if let prompt, let completion {
                return .perMillionTokens(input: prompt * 1_000_000, output: completion * 1_000_000)
            }
        case nil:
            break
        }
        let raw = fields.sorted { $0.key < $1.key }.map { RawField(name: $0.key, value: $0.value) }
        return raw.isEmpty ? .unavailable : .raw(raw)
    }

    /// Three significant digits and at least two decimals, so sub-cent rates
    /// stay distinguishable and never round to free: $0.0002, $0.00183, $2.50.
    static func money(_ usd: Double) -> String {
        guard usd > 0, usd.isFinite else { return "$0.00" }
        let magnitude = Int(floor(log10(usd)))
        let decimals = max(2, 2 - magnitude)
        var text = String(format: "%.\(decimals)f", usd)
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 3 {
            text.removeLast()
        }
        return "$" + text
    }

    static func liveFetch() async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// The last successful price list, kept so prices still show offline.
struct OpenRouterPriceSnapshot: Codable, Equatable {
    var version = 1
    let fetchedAt: Date
    let pricing: [String: [String: String]]
}

/// Fetches and caches prices for the settings views. Nothing in dictation
/// reads this, so a slow or failing price fetch never delays transcription.
@MainActor
final class OpenRouterPriceBook: ObservableObject {
    static let shared = OpenRouterPriceBook(
        cacheURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OSW Cloud/openrouter-prices-v1.json"),
        fetch: OpenRouterPricing.liveFetch
    )

    /// A cache older than this is refreshed when a price view appears and is
    /// labelled possibly outdated.
    static let maxAge: TimeInterval = 24 * 3600

    @Published private(set) var snapshot: OpenRouterPriceSnapshot?
    @Published private(set) var isRefreshing = false
    /// Why the latest refresh failed; cleared by the next success.
    @Published private(set) var refreshError: String?

    private let cacheURL: URL
    private let fetch: () async throws -> Data
    private let now: () -> Date

    init(cacheURL: URL, fetch: @escaping () async throws -> Data, now: @escaping () -> Date = Date.init) {
        self.cacheURL = cacheURL
        self.fetch = fetch
        self.now = now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? decoder.decode(OpenRouterPriceSnapshot.self, from: data),
           cached.version == 1 {
            snapshot = cached
        }
    }

    func price(for id: String) -> OpenRouterPricing.Price {
        OpenRouterPricing.price(for: id, in: snapshot?.pricing)
    }

    /// True when the shown prices may no longer match OpenRouter's.
    var isPossiblyOutdated: Bool {
        guard let snapshot else { return false }
        return refreshError != nil || now().timeIntervalSince(snapshot.fetchedAt) > Self.maxAge
    }

    func refreshIfStale() {
        guard !isRefreshing else { return }
        if let snapshot, refreshError == nil, now().timeIntervalSince(snapshot.fetchedAt) <= Self.maxAge { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let pricing = try OpenRouterPricing.parse(try await fetch())
            let fresh = OpenRouterPriceSnapshot(fetchedAt: now(), pricing: pricing)
            snapshot = fresh
            refreshError = nil
            save(fresh)
        } catch {
            refreshError = (error as? URLError)?.code == .notConnectedToInternet
                ? "No internet connection."
                : "Could not reach OpenRouter's model list."
        }
    }

    private func save(_ snapshot: OpenRouterPriceSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
