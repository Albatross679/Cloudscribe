import AppKit
import SwiftUI

// Engine choice regression, compiled with the production CloudProvider.swift
// and EngineChoiceSelector.swift. No preferences, credentials or network.
// The window stays in an app that is never activated, which is the state of
// Settings when the user clicks it to bring it forward. Nothing is posted to
// other apps: every event goes into this process's own queue.

func check(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write("FAIL \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

func mappingTests() {
    for choice in SpeechRecognitionChoice.allCases {
        let saved = choice.persistedSelection(preserving: "openrouter")
        check(SpeechRecognitionChoice.resolve(engine: saved.engine, provider: saved.provider) == choice,
              "\(choice) round-trips through the saved engine and provider")
    }
    // Saved values stay compatible with existing installs.
    check(SpeechRecognitionChoice.parakeet.persistedSelection(preserving: "openrouter") == ("fluidaudio", "openrouter"),
          "Parakeet saves fluidaudio and keeps the remembered provider")
    check(SpeechRecognitionChoice.whisper.persistedSelection(preserving: "openrouter") == ("whisper", "openrouter"),
          "Whisper saves whisper and keeps the remembered provider")
    check(SpeechRecognitionChoice.openrouter.persistedSelection(preserving: "cloudflare") == ("cloudflare", "openrouter"),
          "OpenRouter saves the cloudflare engine with the openrouter provider")
    // The captain's saved state must show as Local, Parakeet, never OpenRouter.
    let captain = EngineSelection(choice: .resolve(engine: "fluidaudio", provider: "openrouter"))
    check(captain.tab == .local && captain.localSelection == .parakeet, "fluidaudio with a remembered provider shows Local, Parakeet")

    check(EngineTab.allCases.map(\.label) == ["Local", "Cloudflare", "Hugging Face", "OpenRouter"], "one Local tab, then the clouds")
    var selection = EngineSelection(choice: .openrouter)
    check(selection.tab == .openrouter && !selection.showsLocal, "a cloud engine opens on its own tab")
    selection.select(tab: .local)
    check(selection.choice == .openrouter && selection.tab == .local && selection.localSelection == nil,
          "opening Local switches nothing, so nothing downloads")
    selection.select(local: .cloudflare)
    check(selection.choice == .openrouter, "a cloud value is not a local option")
    selection.select(local: .parakeet)
    check(selection.choice == .parakeet && selection.tab == .local, "picking Parakeet is what switches to it")
    selection.select(tab: .openrouter)
    check(selection.choice == .openrouter && selection.tab == .openrouter, "a cloud tab switches back")

    check(SpeechRecognitionChoice.openrouter.dictationSummary(modelLabel: "Grok STT 1.0")
          == "Dictation is sent to OpenRouter, model Grok STT 1.0.", "cloud summary names provider and model")
    check(SpeechRecognitionChoice.parakeet.dictationSummary(modelLabel: "Grok STT 1.0")
          == "Dictation runs on this Mac with Parakeet. No cloud requests or charges.", "local summary ignores cloud models")
    check(SpeechRecognitionChoice.parakeet.menuBarTitle == "Engine: Parakeet (on this Mac)", "menu bar flags local engines")
    print("PASS engine choices keep saved values, Local opens without switching, and the active engine is named")
}

final class State: ObservableObject {
    /// Every write is kept, so a click that changes the engine and a later
    /// one that changes it back still fails the test.
    var writes: [EngineSelection] = []
    @Published var selection = EngineSelection(choice: .openrouter) { didSet { writes.append(selection) } }
    @Published var oldChoice = SpeechRecognitionChoice.openrouter
}

/// The segmented bar this fix replaced, kept verbatim as the control case.
struct OldEngineBar: View {
    @ObservedObject var state: State
    var body: some View {
        Picker("Engine", selection: $state.oldChoice) {
            ForEach(SpeechRecognitionChoice.allCases, id: \.rawValue) { choice in
                Text(choice.label).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct NewEngineBar: View {
    @ObservedObject var state: State
    var body: some View {
        EngineChoiceSelector(selection: $state.selection, cloudModelLabel: "Grok STT 1.0")
            .padding()
    }
}

func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

func makeWindow<V: View>(_ root: V, y: CGFloat) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 80, y: y, width: 550, height: 140),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: root)
    window.orderFront(nil)
    return window
}

/// One click, as the window server delivers it to a window of an inactive app.
func click(_ window: NSWindow, atWindowPoint point: NSPoint) {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        NSApp.postEvent(event, atStart: false)
    }
}

/// Window point at the middle of segment `index` of a bar with `count` segments.
func segmentPoint(_ bar: NSView, _ index: Int, of count: Int) -> NSPoint {
    let width = bar.bounds.width / CGFloat(count)
    return bar.convert(NSPoint(x: width * (CGFloat(index) + 0.5), y: bar.bounds.midY), to: nil)
}

let state = State()
var oldWindow: NSWindow!
var newWindow: NSWindow!

func later(_ seconds: Double, _ work: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
}

func focusClickTests() {
    check(!NSApp.isActive, "the test app must stay inactive to model a click that focuses Settings")
    oldWindow = makeWindow(OldEngineBar(state: state), y: 500)
    newWindow = makeWindow(NewEngineBar(state: state), y: 300)
    later(0.5) {
        guard let oldBar = oldWindow.contentView.flatMap({ allViews($0).first { "\(type(of: $0))".contains("SegmentedControl") } }),
              let newBar = newWindow.contentView.flatMap({ allViews($0).compactMap { $0 as? FocusClickSafeSegmentedControl }.first })
        else { check(false, "segmented bars were not created"); return }
        click(oldWindow, atWindowPoint: segmentPoint(oldBar, 0, of: SpeechRecognitionChoice.allCases.count))
        for index in EngineTab.allCases.indices {
            click(newWindow, atWindowPoint: segmentPoint(newBar, index, of: EngineTab.allCases.count))
        }
        later(0.5) {
            check(state.oldChoice == .parakeet,
                  "control case: the old SwiftUI segmented bar should switch to Parakeet on a focus click, got \(state.oldChoice)")
            check(state.writes.isEmpty && state.selection == EngineSelection(choice: .openrouter),
                  "a focus click on any engine tab must not change the selection, got \(state.writes)")
            print("PASS a click that only focuses an inactive Settings window cannot change the engine (the old bar switched to Parakeet)")
            deliberateTests(newBar)
        }
    }
}

/// A deliberate pick is the control's own action, as a click in the key
/// window sends it. Activating this test app to click for real would take
/// focus from whatever the person running the tests is doing.
func deliberateTests(_ bar: NSSegmentedControl) {
    bar.selectedSegment = EngineTab.allCases.firstIndex(of: .local)!
    bar.sendAction(bar.action, to: bar.target)
    later(0.3) {
        check(state.selection.choice == .openrouter && state.selection.tab == .local,
              "choosing the Local tab only reveals the local options")
        let localBars = allViews(newWindow.contentView!).compactMap { $0 as? FocusClickSafeSegmentedControl }.filter { $0 !== bar }
        check(localBars.count == 1 && localBars[0].segmentCount == 2 && localBars[0].selectedSegment == -1,
              "Local shows Parakeet and Whisper with neither picked")
        let local = localBars[0]
        local.selectedSegment = SpeechRecognitionChoice.localChoices.firstIndex(of: .parakeet)!
        local.sendAction(local.action, to: local.target)
        later(0.3) {
            check(state.selection.choice == .parakeet, "picking Parakeet switches to it")
            bar.selectedSegment = EngineTab.allCases.firstIndex(of: .openrouter)!
            bar.sendAction(bar.action, to: bar.target)
            later(0.3) {
                check(state.selection == EngineSelection(choice: .openrouter), "picking OpenRouter switches back")
                check(bar.selectedSegment == EngineTab.allCases.firstIndex(of: .openrouter)!, "the bar shows the active engine")
                print("PASS deliberate picks change the engine, and the bar shows the one in use")
                exit(0)
            }
        }
    }
}

@main enum EngineChoiceTests {
    static func main() {
        mappingTests()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        later(0.2, focusClickTests)
        later(20) { check(false, "timed out") }
        app.run()
    }
}
