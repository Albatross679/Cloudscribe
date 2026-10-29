import SwiftUI
import Charts
import AppKit

@MainActor
enum OpenRouterPriceWindow {
    private static var controller: NSWindowController?
    static func show(selectedModelID: String?) {
        if controller == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 860),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "OpenRouter prices"
            window.contentMinSize = NSSize(width: 460, height: 400)
            window.isReleasedWhenClosed = false
            window.backgroundColor = Theme.NSColors.background
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.window?.contentView = NSHostingView(rootView: OpenRouterPriceList(book: .shared, selectedModelID: selectedModelID))
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}

/// The selected model's price under the settings picker, with the way to the
/// full comparison.
struct OpenRouterPriceSummary: View {
    @ObservedObject var book: OpenRouterPriceBook
    let selectedModelID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let selectedModelID {
                Label(book.price(for: selectedModelID).label, systemImage: "dollarsign.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.green)
                    .textSelection(.enabled)
            }
            OpenRouterPriceStatus(book: book)
            HStack(spacing: 12) {
                Button("Compare all OpenRouter prices") { OpenRouterPriceWindow.show(selectedModelID: selectedModelID) }
                    .buttonStyle(.themeLink)
                Button("Refresh prices") { Task { await book.refresh() } }
                    .buttonStyle(.themeLink)
                    .disabled(book.isRefreshing)
            }
            .font(.caption)
        }
        .onAppear { book.refreshIfStale() }
    }
}

/// When the prices were fetched, and whether they may be stale.
struct OpenRouterPriceStatus: View {
    @ObservedObject var book: OpenRouterPriceBook

    var body: some View {
        Group {
            if book.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Fetching current OpenRouter prices…")
                }
                .foregroundStyle(Theme.mutedText)
            } else if let snapshot = book.snapshot {
                let fetched = "OpenRouter list prices fetched " + snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)
                if book.isPossiblyOutdated {
                    Label(fetched + ". " + (book.refreshError.map { $0 + " " } ?? "") + "These prices may be outdated.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.amber)
                } else {
                    Text(fetched).foregroundStyle(Theme.mutedText)
                }
            } else if let error = book.refreshError {
                Label(error + " Prices unavailable until a fetch succeeds.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.amber)
            } else {
                Text("Prices not fetched yet.").foregroundStyle(Theme.mutedText)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Every model in the OpenRouter picker on comparable axes: duration-priced
/// models on one per-minute chart, token-priced models on their own.
struct OpenRouterPriceList: View {
    @ObservedObject var book: OpenRouterPriceBook
    let selectedModelID: String?
    var models: [CloudModel] = OpenRouterRequest.catalog

    struct MinuteRow: Identifiable {
        let id: String
        let label: String
        let usd: Double
    }

    struct TokenRow: Identifiable {
        let id: String
        let label: String
        let input: Double
        let output: Double
    }

    /// Cheapest first, ties in picker order.
    var minuteRows: [MinuteRow] {
        models.enumerated().compactMap { index, model -> (Int, MinuteRow)? in
            guard case .perAudioMinute(let usd) = book.price(for: model.id) else { return nil }
            return (index, MinuteRow(id: model.id, label: model.label, usd: usd))
        }
        .sorted { $0.1.usd == $1.1.usd ? $0.0 < $1.0 : $0.1.usd < $1.1.usd }
        .map(\.1)
    }

    var tokenRows: [TokenRow] {
        models.compactMap { model in
            guard case .perMillionTokens(let input, let output) = book.price(for: model.id) else { return nil }
            return TokenRow(id: model.id, label: model.label, input: input, output: output)
        }
        .sorted { $0.input == $1.input ? $0.output < $1.output : $0.input < $1.input }
    }

    var otherModels: [(CloudModel, OpenRouterPricing.Price)] {
        models.compactMap { model in
            let price = book.price(for: model.id)
            switch price {
            case .perAudioMinute, .perMillionTokens: return nil
            case .raw, .unavailable: return (model, price)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("OpenRouter prices").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Refresh") { Task { await book.refresh() } }
                        .disabled(book.isRefreshing)
                }
                OpenRouterPriceStatus(book: book)
                Text("List prices for every speech-to-text model in the OpenRouter picker. The selected model is highlighted. Each response's usage.cost and OpenRouter's activity page are the billing authority.")
                    .font(.caption)
                    .foregroundStyle(Theme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                if !minuteRows.isEmpty {
                    GroupBox("Per audio minute · USD, cheapest first") {
                        minuteChart.padding(4)
                    }
                }
                if !tokenRows.isEmpty {
                    GroupBox("Per 1M tokens · USD, billed by tokens rather than audio length") {
                        VStack(alignment: .leading, spacing: 8) {
                            tokenChart
                            Text("These models cannot share the per-minute axis: their cost depends on how many audio and text tokens a recording produces.")
                                .font(.caption)
                                .foregroundStyle(Theme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(4)
                    }
                }
                if !otherModels.isEmpty {
                    GroupBox("Not charted") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(otherModels, id: \.0.id) { model, price in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(model.label)
                                    Spacer()
                                    Text(price.label).foregroundStyle(Theme.mutedText).textSelection(.enabled)
                                }
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }
            }
            .padding(20)
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .groupBoxStyle(ThemeGroupBoxStyle())
        .background(Theme.background)
        .onAppear { book.refreshIfStale() }
    }

    private var minuteChart: some View {
        let rows = minuteRows
        let top = rows.map(\.usd).max() ?? 0
        return Chart(rows) { row in
            let color = row.id == selectedModelID ? Theme.cyan : Theme.green
            BarMark(x: .value("USD per audio minute", row.usd), y: .value("Model", row.label), height: .fixed(12), stacking: .unstacked)
                .foregroundStyle(color)
                .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                    Text(OpenRouterPricing.money(row.usd))
                        .font(.caption.monospacedDigit())
                        .fontWeight(row.id == selectedModelID ? .semibold : .regular)
                        .foregroundStyle(row.id == selectedModelID ? Theme.text : Theme.mutedText)
                }
                .accessibilityLabel(row.label)
                .accessibilityValue(OpenRouterPricing.money(row.usd) + " per audio minute")
            BarMark(x: .value("USD per audio minute", row.usd), y: .value("Model", row.label), height: .fixed(12), stacking: .unstacked)
                .themeBarFill(color)
        }
        // Room on the right for the longest bar's price label.
        .chartXScale(domain: 0...max(top * 1.18, 0.0001))
        .chartYScale(domain: rows.map(\.label))
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let usd = value.as(Double.self) { Text(OpenRouterPricing.money(usd)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel(horizontalSpacing: 8) {
                    if let label = value.as(String.self) {
                        Text(label).fontWeight(rows.first { $0.label == label }?.id == selectedModelID ? .semibold : .regular)
                    }
                }
            }
        }
        .frame(height: CGFloat(rows.count) * 40 + 30)
    }

    /// One bar per token direction, flattened so the chart body stays simple.
    struct TokenBar: Identifiable {
        var id: String { modelID + kind }
        let modelID: String
        let label: String
        let kind: String
        let usd: Double
        let emphasized: Bool
    }

    private var tokenBars: [TokenBar] {
        let rows = tokenRows
        // Dim the others only when the selection is one of these rows.
        let selectedIsTokenPriced = rows.contains { $0.id == selectedModelID }
        return rows.flatMap { row in
            let emphasized = row.id == selectedModelID || !selectedIsTokenPriced
            return [TokenBar(modelID: row.id, label: row.label, kind: "Input", usd: row.input, emphasized: emphasized),
                    TokenBar(modelID: row.id, label: row.label, kind: "Output", usd: row.output, emphasized: emphasized)]
        }
    }

    private var tokenChart: some View {
        let rows = tokenRows
        let top = rows.map { max($0.input, $0.output) }.max() ?? 0
        return Chart(tokenBars) { bar in
            BarMark(x: .value("USD per 1M tokens", bar.usd), y: .value("Model", bar.label), height: .fixed(12), stacking: .unstacked)
                .position(by: .value("Token type", bar.kind))
                .foregroundStyle(by: .value("Token type", bar.kind))
                .opacity(bar.emphasized ? 1 : 0.5)
                .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                    Text(OpenRouterPricing.money(bar.usd))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(bar.modelID == selectedModelID ? Theme.text : Theme.mutedText)
                }
                .accessibilityLabel(bar.label + " " + bar.kind.lowercased())
                .accessibilityValue(OpenRouterPricing.money(bar.usd) + " per 1M tokens")
            BarMark(x: .value("USD per 1M tokens", bar.usd), y: .value("Model", bar.label), height: .fixed(12), stacking: .unstacked)
                .position(by: .value("Token type", bar.kind))
                .themeBarFill(bar.kind == "Input" ? Theme.green : Theme.violet)
                .opacity(bar.emphasized ? 1 : 0.5)
        }
        .chartForegroundStyleScale(["Input": Theme.green, "Output": Theme.violet])
        .chartXScale(domain: 0...max(top * 1.2, 0.01))
        .chartYScale(domain: rows.map(\.label))
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let usd = value.as(Double.self) { Text(OpenRouterPricing.money(usd)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel(horizontalSpacing: 8) {
                    if let label = value.as(String.self) {
                        Text(label).fontWeight(rows.first { $0.label == label }?.id == selectedModelID ? .semibold : .regular)
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: CGFloat(rows.count) * 64 + 50)
    }
}
