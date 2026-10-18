import SwiftUI
import AppKit

/// Renders the production OpenRouter price views in their own process from the
/// saved endpoint fixture. No network, credentials, preferences or app data.
/// Usage: openrouter_price_ui_probe <out-dir> <fixture.json> <light|dark> <list|summary|offline>
@main enum OpenRouterPriceUIProbe {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let appearance = CommandLine.arguments[3]
        let mode = CommandLine.arguments[4]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("probe-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: cache) }

        let fetchedAt = ISO8601DateFormatter().date(from: "2026-10-18T15:55:00Z")!
        var now = fetchedAt
        var serve = true
        let book = OpenRouterPriceBook(cacheURL: cache, fetch: {
            guard serve else { throw URLError(.notConnectedToInternet) }
            return fixture
        }, now: { now })
        await book.refresh()
        if mode == "offline" {
            serve = false
            now = fetchedAt.addingTimeInterval(2 * 24 * 3600)
            await book.refresh()
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let selected = "deepgram/nova-3"
        let size = mode == "summary" ? NSSize(width: 520, height: 120) : NSSize(width: 760, height: 1560)
        let view: AnyView = mode == "summary"
            ? AnyView(OpenRouterPriceSummary(book: book, selectedModelID: selected)
                .padding(16).frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(.windowBackgroundColor)))
            : AnyView(OpenRouterPriceList(book: book, selectedModelID: selected))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OpenRouter prices UI probe, fixture data"
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do { try data.write(to: root.appendingPathComponent("\(mode)-\(appearance).png")) }
            catch { print(error); exit(1) }
            print("Rendered \(mode) \(appearance) \(Int(size.width))x\(Int(size.height))")
            window.close()
            application.terminate(nil)
        }
        application.run()
    }
}
