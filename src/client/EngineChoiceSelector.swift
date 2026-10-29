import AppKit
import SwiftUI

/// The top-level engine tabs in Settings. Parakeet and Whisper both run on
/// this Mac, so they share one Local tab instead of taking two.
enum EngineTab: String, CaseIterable {
    case local
    case cloudflare
    case huggingface
    case openrouter

    init(_ choice: SpeechRecognitionChoice) {
        switch choice {
        case .parakeet, .whisper: self = .local
        case .cloudflare: self = .cloudflare
        case .huggingface: self = .huggingface
        case .openrouter: self = .openrouter
        }
    }

    var label: String {
        switch self {
        case .local: return "Local"
        case .cloudflare: return "Cloudflare"
        case .huggingface: return "Hugging Face"
        case .openrouter: return "OpenRouter"
        }
    }

    /// The engine a cloud tab selects. Local has none: it only reveals the
    /// local options, so opening it never switches engines or downloads.
    var cloudChoice: SpeechRecognitionChoice? {
        switch self {
        case .local: return nil
        case .cloudflare: return .cloudflare
        case .huggingface: return .huggingface
        case .openrouter: return .openrouter
        }
    }
}

extension SpeechRecognitionChoice {
    static let localChoices: [SpeechRecognitionChoice] = [.parakeet, .whisper]

    var isLocal: Bool { Self.localChoices.contains(self) }

    /// What dictation runs on, shown under the tabs so a switch cannot go
    /// unnoticed.
    func dictationSummary(modelLabel: String?) -> String {
        if isLocal {
            return "Dictation runs on this Mac with \(label). No cloud requests or charges."
        }
        guard let modelLabel, !modelLabel.isEmpty else { return "Dictation is sent to \(label)." }
        return "Dictation is sent to \(label), model \(modelLabel)."
    }

    var menuBarTitle: String {
        "Engine: \(label)" + (isLocal ? " (on this Mac)" : "")
    }
}

/// The engine dictation uses plus which tab is showing. They differ only
/// while Local is open and no local engine has been picked yet.
struct EngineSelection: Equatable {
    var choice: SpeechRecognitionChoice
    var showsLocal: Bool

    init(choice: SpeechRecognitionChoice, showsLocal: Bool? = nil) {
        self.choice = choice
        self.showsLocal = showsLocal ?? choice.isLocal
    }

    var tab: EngineTab { showsLocal ? .local : EngineTab(choice) }

    /// The local option to mark, or none while a cloud engine stays active.
    var localSelection: SpeechRecognitionChoice? { choice.isLocal ? choice : nil }

    mutating func select(tab: EngineTab) {
        if let cloud = tab.cloudChoice {
            showsLocal = false
            choice = cloud
        } else {
            showsLocal = true
        }
    }

    mutating func select(local: SpeechRecognitionChoice) {
        guard local.isLocal else { return }
        showsLocal = true
        choice = local
    }
}

/// Settings' engine control: the tabs, the local options under Local, and a
/// line naming the engine dictation actually uses.
struct EngineChoiceSelector: View {
    @Binding var selection: EngineSelection
    let cloudModelLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClickSafeSegmentedPicker(
                options: EngineTab.allCases.map { ($0, $0.label) },
                selected: selection.tab,
                accessibilityLabel: "Engine"
            ) { selection.select(tab: $0) }
            .frame(maxWidth: .infinity)

            if selection.showsLocal {
                ClickSafeSegmentedPicker(
                    options: SpeechRecognitionChoice.localChoices.map { ($0, $0.label) },
                    selected: selection.localSelection,
                    accessibilityLabel: "Local engine"
                ) { selection.select(local: $0) }
                .fixedSize()

                if selection.localSelection == nil {
                    Text("Pick Parakeet or Whisper to run dictation on this Mac. No local model is downloaded before you pick one.")
                        .font(.caption)
                        .foregroundColor(Theme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label(selection.choice.dictationSummary(modelLabel: cloudModelLabel),
                  systemImage: selection.choice.isLocal ? "laptopcomputer" : "cloud")
                .font(.caption)
                .foregroundColor(Theme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A segmented control that ignores the click which only brings an inactive
/// window forward.
///
/// SwiftUI's segmented Picker, like a stock NSSegmentedControl, accepts that
/// first click. A click meant to focus the Settings window therefore changed
/// the engine when it landed on a segment.
final class FocusClickSafeSegmentedControl: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    /// Separate flat tabs, the selected one outlined in the accent color.
    /// Each tab is drawn inside its own equal-width segment, so clicks still
    /// land on the segment that is drawn there.
    override func draw(_ dirtyRect: NSRect) {
        guard segmentCount > 0 else { return }
        let slot = bounds.width / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let selected = index == selectedSegment
            let rect = NSRect(x: CGFloat(index) * slot, y: 0, width: slot, height: bounds.height)
                .insetBy(dx: segmentCount > 1 ? 4 : 0, dy: 0)
                .insetBy(dx: 0.5, dy: 0.5)
            let outline = NSBezierPath(roundedRect: rect, xRadius: Theme.rowCornerRadius, yRadius: Theme.rowCornerRadius)
            outline.lineWidth = 1
            (selected ? Theme.NSColors.accent : Theme.NSColors.line).setStroke()
            outline.stroke()

            let label = NSAttributedString(string: label(forSegment: index) ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: selected ? .medium : .regular),
                .foregroundColor: selected ? Theme.NSColors.accent : Theme.NSColors.mutedText,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }
}

struct ClickSafeSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    let options: [(value: Value, label: String)]
    let selected: Value?
    let accessibilityLabel: String
    let onSelect: (Value) -> Void

    init(options: [(Value, String)], selected: Value?, accessibilityLabel: String, onSelect: @escaping (Value) -> Void) {
        self.options = options.map { (value: $0.0, label: $0.1) }
        self.selected = selected
        self.accessibilityLabel = accessibilityLabel
        self.onSelect = onSelect
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusClickSafeSegmentedControl {
        let control = FocusClickSafeSegmentedControl(
            labels: options.map(\.label), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(accessibilityLabel)
        return control
    }

    func updateNSView(_ control: FocusClickSafeSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = selected.flatMap { value in options.firstIndex { $0.value == value } } ?? -1
    }

    final class Coordinator: NSObject {
        var parent: ClickSafeSegmentedPicker

        init(_ parent: ClickSafeSegmentedPicker) { self.parent = parent }

        @objc func changed(_ control: NSSegmentedControl) {
            guard parent.options.indices.contains(control.selectedSegment) else { return }
            parent.onSelect(parent.options[control.selectedSegment].value)
        }
    }
}
