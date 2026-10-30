// The runner appends this to the real ShortcutManager implementation, replacing
// only its external dependencies. No global input, microphone, or preferences
// are touched. Callback dispatch, hold timing and cancellation are production code.
import AppKit

struct KeyboardShortcuts {
    struct Shortcut { enum Key { case backtick, escape }; enum Modifier { case option }; init(_ key: Key, modifiers: Modifier? = nil) {} }
    struct Name: Hashable { let raw: String; init(_ raw: String, default shortcut: Shortcut? = nil) { self.raw = raw } }
    static var down: [Name: () -> Void] = [:]
    static var up: [Name: () -> Void] = [:]
    static var enabled = Set<Name>()
    static func onKeyDown(for name: Name, action: @escaping () -> Void) { down[name] = action }
    static func onKeyUp(for name: Name, action: @escaping () -> Void) { up[name] = action }
    static func enable(_ name: Name) { enabled.insert(name) }
    static func disable(_ name: Name) { enabled.remove(name) }
}
extension Notification.Name {
    static let hotkeySettingsChanged = Self("testHotkeySettingsChanged")
    static let indicatorWindowDidHide = Self("testIndicatorDidHide")
}
final class AppPreferences {
    static let shared = AppPreferences()
    var modifierOnlyHotkey = "none"
    var mouseButtonHotkey = "middle"
    var doublePressToTrigger = true
    var holdToRecord = false
}
enum ModifierKey: String { case none, leftCommand, rightOption; var displayName: String { rawValue } }
final class ModifierKeyMonitor {
    static let shared = ModifierKeyMonitor()
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    func start(modifierKey: ModifierKey) {}
    func stop() {}
}
final class MouseButtonMonitor {
    static let shared = MouseButtonMonitor()
    var onButtonDown: (() -> Void)?
    var onButtonUp: (() -> Void)?
    var selected = MouseButton.none
    func start(mouseButton: MouseButton) { selected = mouseButton }
    func stop() { selected = .none }
}
@MainActor final class IndicatorViewModel {
    func startRecording() { IndicatorWindowManager.shared.starts += 1 }
}
@MainActor final class IndicatorWindowManager {
    static let shared = IndicatorWindowManager()
    var starts = 0
    var stops = 0
    var cancels = 0
    /// A stopped hotkey dictation transcribes until cancelled or the test ends it.
    var transcribing = false
    var transcriptionCancels = 0
    private init() {
        // Hiding the indicator ends its session, transcribing or not.
        NotificationCenter.default.addObserver(forName: .indicatorWindowDidHide, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { IndicatorWindowManager.shared.transcribing = false }
        }
    }
    func prepare() -> IndicatorViewModel { KeyboardShortcuts.enable(.escape); return IndicatorViewModel() }
    func presentWindow(for vm: IndicatorViewModel, nearPoint: NSPoint?) {}
    func stopRecording() { stops += 1; transcribing = true }
    func cancelTranscription() -> Bool {
        guard transcribing else { return false }
        transcribing = false
        transcriptionCancels += 1
        NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        return true
    }
    func finishTranscribing() {
        NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
    }
    func requestCancel() -> Bool {
        cancels += 1
        NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        return true
    }
}
enum FocusUtils {
    static func getCurrentCursorPosition() -> NSPoint? { nil }
    static func getInputAnchorPoint() -> NSPoint? { nil }
}

@main enum ShortcutTests {
    static var failures = 0
    static func check(_ name: String, _ result: Bool) {
        print("  \(result ? "ok  " : "FAIL") \(name)")
        if !result { failures += 1 }
    }
    @MainActor static func tick(_ seconds: Double = 0.04) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    @MainActor static func main() async {
        _ = ShortcutManager.shared
        let window = IndicatorWindowManager.shared
        let prefs = AppPreferences.shared
        check("mouse mode disables keyboard recording shortcut", !KeyboardShortcuts.enabled.contains(.toggleRecord))
        MouseButtonMonitor.shared.onButtonDown?()
        await tick()
        check("hidden modifier double-press setting does not block mouse start", window.starts == 1)
        MouseButtonMonitor.shared.onButtonUp?()
        await tick()
        check("toggle mouse release does not submit recording", window.stops == 0)
        KeyboardShortcuts.up[.escape]?()
        await tick()
        check("Escape cancels mouse session without decoding", window.cancels == 1 && window.stops == 0)

        prefs.mouseButtonHotkey = "none"
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        check("keyboard mode enables recording shortcut", KeyboardShortcuts.enabled.contains(.toggleRecord))
        KeyboardShortcuts.down[.toggleRecord]?()
        await tick()
        check("hidden modifier double-press setting does not block keyboard start", window.starts == 2)
        KeyboardShortcuts.up[.toggleRecord]?()
        KeyboardShortcuts.up[.escape]?()
        await tick()
        check("Escape cancels keyboard session without decoding", window.cancels == 2 && window.stops == 0)

        prefs.doublePressToTrigger = false
        prefs.holdToRecord = true
        let before = window.stops
        KeyboardShortcuts.down[.toggleRecord]?()
        await tick(0.36)
        KeyboardShortcuts.up[.toggleRecord]?()
        await tick()
        check("held keyboard release stops exactly once", window.stops == before + 1)
        NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        prefs.mouseButtonHotkey = "middle"
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        MouseButtonMonitor.shared.onButtonDown?()
        await tick(0.36)
        MouseButtonMonitor.shared.onButtonUp?()
        await tick()
        check("held mouse release stops exactly once", window.stops == before + 2)
        NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)

        prefs.mouseButtonHotkey = "none"
        prefs.modifierOnlyHotkey = "leftCommand"
        prefs.doublePressToTrigger = true
        prefs.holdToRecord = false
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        let starts = window.starts
        ModifierKeyMonitor.shared.onKeyDown?()
        ModifierKeyMonitor.shared.onKeyUp?()
        await tick()
        check("modifier first tap waits for configured double-tap", window.starts == starts)
        ModifierKeyMonitor.shared.onKeyDown?()
        await tick()
        check("modifier second tap starts recording", window.starts == starts + 1)
        KeyboardShortcuts.up[.escape]?()
        await tick()

        // Right Option held to record, as the captain uses it.
        prefs.modifierOnlyHotkey = "rightOption"
        prefs.doublePressToTrigger = false
        prefs.holdToRecord = true
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        func hold() async {
            ModifierKeyMonitor.shared.onKeyDown?()
            await tick(0.36)
            ModifierKeyMonitor.shared.onKeyUp?()
            await tick()
        }
        var mark = (window.starts, window.stops, window.cancels)
        await hold()
        check("idle hold records and stops once", window.starts == mark.0 + 1 && window.stops == mark.1 + 1 && window.transcribing)
        mark = (window.starts, window.stops, window.cancels)
        ModifierKeyMonitor.shared.onKeyDown?()
        await tick()
        check("press while transcribing cancels the transcription", window.transcriptionCancels == 1 && !window.transcribing)
        check("cancel press starts no recording", window.starts == mark.0)
        await tick(0.36)
        ModifierKeyMonitor.shared.onKeyUp?()
        await tick()
        check("cancel press key-up does nothing", window.starts == mark.0 && window.stops == mark.1 && window.cancels == mark.2)
        await hold()
        check("next hold records normally after a cancel", window.starts == mark.0 + 1 && window.stops == mark.1 + 1)
        KeyboardShortcuts.up[.escape]?()
        await tick()
        check("Escape cancels while transcribing", window.transcriptionCancels == 2 && window.cancels == mark.2 && !window.transcribing)
        await hold()
        window.finishTranscribing()
        await tick()
        mark = (window.starts, window.stops, window.cancels)
        await hold()
        check("hold after a finished transcription records normally", window.starts == mark.0 + 1 && window.stops == mark.1 + 1 && window.transcriptionCancels == 2)
        window.finishTranscribing()

        // Double-press mode: one press is enough to cancel.
        prefs.doublePressToTrigger = true
        prefs.holdToRecord = false
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        ModifierKeyMonitor.shared.onKeyDown?(); ModifierKeyMonitor.shared.onKeyUp?()
        ModifierKeyMonitor.shared.onKeyDown?(); ModifierKeyMonitor.shared.onKeyUp?()
        await tick()
        ModifierKeyMonitor.shared.onKeyDown?(); ModifierKeyMonitor.shared.onKeyUp?()
        await tick()
        mark = (window.starts, window.stops, window.cancels)
        check("toggle double-press session reaches transcribing", window.transcribing)
        ModifierKeyMonitor.shared.onKeyDown?(); ModifierKeyMonitor.shared.onKeyUp?()
        await tick()
        check("single press cancels transcribing in double-press mode", window.transcriptionCancels == 3 && window.starts == mark.0 && window.stops == mark.1)
        if failures != 0 { exit(1) }
        print("all shortcut dispatch checks passed")
    }
}
