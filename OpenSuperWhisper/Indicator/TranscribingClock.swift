import SwiftUI

/// The time hotkey dictation has spent transcribing, shown on the indicator.
/// It counts from the moment `TranscriptionService.dictationDeadline` starts,
/// so the count and the outline reach the limit together with the deadline.
struct TranscribingClock: Equatable {
    static let timeoutMessage = "Timed out, saved to history"

    let startedAt: ContinuousClock.Instant
    let limit: Duration
    /// Whole seconds since transcribing started, never past the limit.
    private(set) var seconds = 0

    init(deadline: ContinuousClock.Instant, limit: Duration) {
        startedAt = deadline - limit
        self.limit = limit
    }

    var label: String { "Transcribing... \(seconds)s" }

    mutating func tick(at now: ContinuousClock.Instant = .now) {
        seconds = Int(min(elapsed(at: now), limit).components.seconds)
    }

    /// How much of the outline is filled: 0 when transcribing starts, 1 at the limit.
    func progress(at now: ContinuousClock.Instant = .now) -> Double {
        min(max(elapsed(at: now) / limit, 0), 1)
    }

    /// Time left until the limit, zero once it has passed.
    func remaining(at now: ContinuousClock.Instant = .now) -> Duration {
        max(limit - elapsed(at: now), .zero)
    }

    private func elapsed(at now: ContinuousClock.Instant) -> Duration {
        max(now - startedAt, .zero)
    }
}

/// The indicator card outline as a path that starts at the top center and
/// runs clockwise, so a trimmed stroke fills like a progress ring. `inset`
/// keeps a stroke of twice that width inside the card.
struct CardOutline: Shape {
    var cornerRadius: CGFloat
    var inset: CGFloat = 0

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(cornerRadius - inset, rect.height / 2, rect.width / 2)
        let corners = [
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY),
        ]
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        for (index, corner) in corners.enumerated() {
            let next = index + 1 < corners.count ? corners[index + 1] : CGPoint(x: rect.midX, y: rect.minY)
            path.addArc(tangent1End: corner, tangent2End: next, radius: max(radius, 0))
        }
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

/// An amber stroke over the card outline that fills once over the dictation
/// limit, so the cutoff is visible before it arrives.
struct TranscribingProgressOutline: View {
    let clock: TranscribingClock
    let cornerRadius: CGFloat
    @State private var progress: Double = 0

    private static let lineWidth: CGFloat = 2

    var body: some View {
        CardOutline(cornerRadius: cornerRadius, inset: Self.lineWidth / 2)
            .trim(from: 0, to: progress)
            .stroke(Theme.amber, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
            .onAppear {
                let now = ContinuousClock.now
                progress = clock.progress(at: now)
                withAnimation(.linear(duration: clock.remaining(at: now) / .seconds(1))) {
                    progress = 1
                }
            }
    }
}
