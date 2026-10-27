import Foundation

/// Offline. Parses a saved copy of GET /api/v1/models?output_modalities=transcription
/// (fetched 2026-10-18, with the two Voxtral Transcribe 3 entries added from a
/// 2026-10-27 fetch) and drives the cache with stubbed fetches; no network.
@main enum OpenRouterPricingTests {
    static var failures = 0
    static func check(_ name: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(name)")
        if !ok { failures += 1 }
    }

    @MainActor static func main() async throws {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try Data(contentsOf: fixtureURL)
        let pricing = try OpenRouterPricing.parse(fixture)

        check("fixture lists 28 transcription models", pricing.count == 28)
        let ids = OpenRouterRequest.catalog.map(\.id)
        check("every picker model has a price in the fixture", ids.allSatisfy { pricing[$0] != nil })
        check("every picker model has a published unit", ids.allSatisfy { OpenRouterPricing.units[$0] != nil })
        check("no unit is recorded for a model outside the picker", Set(OpenRouterPricing.units.keys) == Set(ids))
        check("raw strings are kept exactly", pricing["deepgram/nova-3"]?["prompt"] == "0.0000716666666667")

        func price(_ id: String) -> OpenRouterPricing.Price { OpenRouterPricing.price(for: id, in: pricing) }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-12 }

        // Per audio second: multiply by 60.
        if case .perAudioMinute(let usd) = price("deepgram/nova-3") { check("Nova-3 per second becomes per minute", near(usd, 0.0043)) }
        else { check("Nova-3 is per minute", false) }
        check("Nova-3 label", price("deepgram/nova-3").label == "$0.0043 per audio minute")
        check("Whisper turbo short label", price("openai/whisper-large-v3-turbo").shortLabel == "$0.0002/min")
        check("Scribe v2 discounted rate", price("elevenlabs/scribe-v2").shortLabel == "$0.00183/min")
        check("Chirp 3", price("google/chirp-3").shortLabel == "$0.016/min")
        check("Voxtral Mini Transcribe 3", price("mistralai/voxtral-mini-transcribe-3-0").shortLabel == "$0.0035/min")
        check("Voxtral Small Transcribe 3", price("mistralai/voxtral-small-transcribe-3-0").shortLabel == "$0.004/min")

        // Per audio hour: divide by 60.
        if case .perAudioMinute(let usd) = price("microsoft/mai-transcribe-2") { check("MAI-Transcribe 2 per hour becomes per minute", near(usd, 0.1 / 60)) }
        else { check("MAI-Transcribe 2 is per minute", false) }
        check("MAI-Transcribe 1.5 per hour", price("microsoft/mai-transcribe-1.5").shortLabel == "$0.006/min")

        // Per token: multiply by one million.
        check("GPT-4o transcribe per 1M tokens", price("openai/gpt-4o-transcribe") == .perMillionTokens(input: 2.5, output: 10))
        check("GPT-4o transcribe label", price("openai/gpt-4o-transcribe").label == "$2.50 input · $10.00 output per 1M tokens")
        check("GPT-4o mini transcribe per 1M tokens", price("openai/gpt-4o-mini-transcribe").shortLabel == "$1.25 in, $5.00 out /1M tokens")
        check("Gemini 3.5 Transcribe per 1M tokens", price("google/gemini-3.5-transcribe") == .perMillionTokens(input: 2, output: 12))

        // An unknown unit shows the raw fields rather than a guess.
        let unknown = try OpenRouterPricing.parse(Data(#"{"data":[{"id":"vendor/new-stt","pricing":{"prompt":"0.5","request":"0.01"}}]}"#.utf8))
        let raw = OpenRouterPricing.price(for: "vendor/new-stt", in: unknown)
        check("unknown unit stays raw", raw == .raw([.init(name: "prompt", value: "0.5"), .init(name: "request", value: "0.01")]))
        check("raw label names the fields", raw.label == "OpenRouter prompt 0.5, request 0.01 (unit not published)")
        check("raw has no picker label", raw.shortLabel == nil)
        check("missing model is unavailable", OpenRouterPricing.price(for: "deepgram/nova-3", in: unknown) == .unavailable)
        check("no cache is unavailable", OpenRouterPricing.price(for: "deepgram/nova-3", in: nil).label == "Price unavailable")
        let broken = try OpenRouterPricing.parse(Data(#"{"data":[{"id":"deepgram/nova-3","pricing":{"prompt":"n/a"}}]}"#.utf8))
        check("unparseable number stays raw", OpenRouterPricing.price(for: "deepgram/nova-3", in: broken) == .raw([.init(name: "prompt", value: "n/a")]))

        check("garbage body throws", (try? OpenRouterPricing.parse(Data("<html>".utf8))) == nil)
        check("empty list throws", (try? OpenRouterPricing.parse(Data(#"{"data":[]}"#.utf8))) == nil)

        // Money keeps three significant digits and at least two decimals.
        check("money 10", OpenRouterPricing.money(10) == "$10.00")
        check("money 0.0001998", OpenRouterPricing.money(0.0001998) == "$0.0002")
        check("money 0.00166667", OpenRouterPricing.money(0.1 / 60) == "$0.00167")
        check("money 0.000999", OpenRouterPricing.money(0.000999) == "$0.000999")
        check("money zero", OpenRouterPricing.money(0) == "$0.00")

        // Cache: success saves, failure keeps the cache and marks it outdated.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-pricing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("nested/openrouter-prices-v1.json")
        var clock = Date(timeIntervalSince1970: 1_792_339_200)
        var responses: [Result<Data, Error>] = [.success(fixture)]
        let book = OpenRouterPriceBook(cacheURL: cacheURL, fetch: {
            guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
            return try responses.removeFirst().get()
        }, now: { clock })

        check("empty book is unavailable", book.price(for: "deepgram/nova-3") == .unavailable)
        check("empty book is not called outdated", !book.isPossiblyOutdated)
        await book.refresh()
        check("refresh fills prices", book.price(for: "deepgram/nova-3").shortLabel == "$0.0043/min")
        check("refresh records fetch time", book.snapshot?.fetchedAt == clock)
        check("fresh prices are current", !book.isPossiblyOutdated && book.refreshError == nil)
        check("refresh writes the cache", FileManager.default.fileExists(atPath: cacheURL.path))

        clock = clock.addingTimeInterval(3600)
        responses = [.success(Data("<html>".utf8))]
        await book.refresh()
        check("failed refresh keeps cached prices", book.price(for: "deepgram/nova-3").shortLabel == "$0.0043/min")
        check("failed refresh marks prices possibly outdated", book.isPossiblyOutdated && book.refreshError != nil)
        check("failed refresh keeps the old fetch time", book.snapshot?.fetchedAt == clock.addingTimeInterval(-3600))

        let reopened = OpenRouterPriceBook(cacheURL: cacheURL, fetch: { throw URLError(.notConnectedToInternet) }, now: { clock })
        check("cache survives relaunch", reopened.price(for: "openai/gpt-4o-transcribe") == .perMillionTokens(input: 2.5, output: 10))
        check("relaunched cache keeps its fetch time", reopened.snapshot?.fetchedAt == clock.addingTimeInterval(-3600))
        check("cache under a day old is current", !reopened.isPossiblyOutdated)
        clock = clock.addingTimeInterval(OpenRouterPriceBook.maxAge)
        check("cache over a day old is possibly outdated", reopened.isPossiblyOutdated)
        await reopened.refresh()
        check("offline refresh says so", reopened.refreshError == "No internet connection.")

        try Data("not json".utf8).write(to: cacheURL)
        let damaged = OpenRouterPriceBook(cacheURL: cacheURL, fetch: { throw URLError(.timedOut) }, now: { clock })
        check("damaged cache reads as unavailable", damaged.price(for: "deepgram/nova-3") == .unavailable)

        print(failures == 0 ? "All OpenRouter pricing checks passed." : "\(failures) OpenRouter pricing check(s) failed.")
        if failures > 0 { exit(1) }
    }
}
