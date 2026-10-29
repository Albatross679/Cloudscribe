import Foundation

// The count and outline the indicator shows while hotkey dictation transcribes.
@main enum TranscribingClockTests {
    static func main() {
        let limit: Duration = .seconds(8)
        let start = ContinuousClock.now
        var clock = TranscribingClock(deadline: start + limit, limit: limit)
        precondition(clock.startedAt == start, "the count must start when the deadline starts")

        precondition(clock.label == "Transcribing... 0s", clock.label)
        precondition(clock.progress(at: start) == 0 && clock.remaining(at: start) == limit)
        print("PASS starts at 0s with an empty outline")

        clock.tick(at: start + .milliseconds(3400))
        precondition(clock.seconds == 3 && clock.label == "Transcribing... 3s", clock.label)
        clock.tick(at: start + .milliseconds(6999))
        precondition(clock.seconds == 6, "a second is counted only once it has passed: \(clock.seconds)")
        precondition(abs(clock.progress(at: start + .seconds(6)) - 0.75) < 1e-9)
        precondition(clock.remaining(at: start + .seconds(6)) == .seconds(2))
        print("PASS counts whole elapsed seconds and fills the outline over the limit")

        clock.tick(at: start + .seconds(30))
        precondition(clock.seconds == 8 && clock.label == "Transcribing... 8s", "the count stops at the limit: \(clock.label)")
        precondition(clock.progress(at: start + .seconds(30)) == 1 && clock.remaining(at: start + .seconds(30)) == .zero)
        clock.tick(at: start - .seconds(1))
        precondition(clock.seconds == 0 && clock.progress(at: start - .seconds(1)) == 0)
        print("PASS never runs past the limit or below zero")

        precondition(TranscribingClock.timeoutMessage == "Timed out, saved to history")
        print("PASS timeout message")
    }
}
