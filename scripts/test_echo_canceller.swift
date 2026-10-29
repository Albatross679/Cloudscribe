// Feeds a simulated speaker echo through the production EchoCancelledWriter.
// The speaker plays jfk.wav, the room returns it to the microphone delayed
// and attenuated, and from 8 s a second talker (the same clip reversed)
// speaks over it. No audio device, permission or network is used.
import AVFoundation
import Foundation

func fail(_ message: String) -> Never {
    print("FAIL \(message)")
    exit(1)
}

let rate = 48000.0
let seconds = 16.0
let count = Int(rate * seconds)

func load(_ url: URL) -> [Float] {
    let file = try! AVAudioFile(forReading: url)
    let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: source)
    let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024)!
    var supplied = false
    _ = converter.convert(to: output, error: nil) { _, status in
        if supplied { status.pointee = .endOfStream; return nil }
        supplied = true
        status.pointee = .haveData
        return source
    }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

let clip = load(URL(fileURLWithPath: CommandLine.arguments[1]))
var speaker = [Float](repeating: 0, count: count)
for index in 0..<min(clip.count, count) { speaker[index] = clip[index] * 0.8 }

// Room: 30 ms to the first reflection at gain 0.6, then a decaying tail.
// Seeded, so every run hears the same room.
struct Seeded: RandomNumberGenerator {
    var state: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
var generator = Seeded()
var room = [Float](repeating: 0, count: Int(rate * 0.08))
let firstReflection = Int(rate * 0.03)
room[firstReflection] = 0.6
for index in (firstReflection + 1)..<room.count {
    let decay = exp(-Float(index - firstReflection) / Float(rate * 0.012))
    room[index] = Float.random(in: -0.15...0.15, using: &generator) * decay
}
var echo = [Float](repeating: 0, count: count)
for (lag, gain) in room.enumerated() where gain != 0 {
    for index in lag..<count { echo[index] += speaker[index - lag] * gain }
}

var talker = [Float](repeating: 0, count: count)
let talkerStart = Int(rate * 8)
let reversed = Array(clip.reversed())
for index in 0..<min(reversed.count, count - talkerStart) { talker[talkerStart + index] = reversed[index] * 0.5 }

func noise() -> Float { Float.random(in: -0.0005...0.0005, using: &generator) }
let microphone = (0..<count).map { echo[$0] + talker[$0] + noise() }
let silence = [Float](repeating: 0, count: count)

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("echo-canceller-test-\(getpid())")
try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

/// Writes in uneven chunks, like the 20 ms drains of a real recording.
func record(_ name: String, microphone mic: [Float], speaker played: [Float], cancelEcho: Bool) -> [Float] {
    let url = directory.appendingPathComponent("\(name).wav")
    let writer = try! EchoCancelledWriter(url: url, sampleRate: rate, cancelEcho: cancelEcho)
    var offset = 0
    var chunk = 911
    while offset < mic.count {
        let end = min(offset + chunk, mic.count)
        try! mic[offset..<end].withUnsafeBufferPointer { m in
            try played[offset..<end].withUnsafeBufferPointer { s in try writer.append(microphone: m, speaker: s) }
        }
        offset = end
        chunk = chunk == 911 ? 1013 : 911
    }
    try! writer.finish()
    if writer.failedFrames > 0 { fail("\(name): canceller rejected \(writer.failedFrames) frames") }

    let file = try! AVAudioFile(forReading: url)
    let format = file.fileFormat.settings
    guard file.fileFormat.sampleRate == 16000, file.fileFormat.channelCount == 1,
          format[AVLinearPCMBitDepthKey] as? Int == 16, format[AVLinearPCMIsFloatKey] as? Bool == false else {
        fail("\(name): file is not 16 kHz 16-bit mono PCM: \(format)")
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func energy(_ samples: [Float], _ from: Double, _ to: Double) -> Double {
    samples[Int(from * 16000)..<min(Int(to * 16000), samples.count)].reduce(0) { $0 + Double($1 * $1) }
}
func db(_ ratio: Double) -> Double { 10 * log10(ratio) }

let off = record("off", microphone: microphone, speaker: speaker, cancelEcho: false)
let on = record("on", microphone: microphone, speaker: speaker, cancelEcho: true)
let talkerOnly = record("talker", microphone: talker, speaker: silence, cancelEcho: false)

let expected = Int(seconds * 16000)
guard abs(on.count - expected) <= 160 else { fail("wrote \(on.count) samples, expected about \(expected)") }

func dot(_ a: [Float], _ b: [Float], _ from: Double, _ to: Double) -> Double {
    (Int(from * 16000)..<min(Int(to * 16000), a.count, b.count)).reduce(0) { $0 + Double(a[$1] * b[$1]) }
}
func delayed(_ samples: [Float], by lag: Int) -> [Float] {
    Array(repeating: 0, count: lag) + samples.dropLast(lag)
}

// Echo only. The filter takes a few seconds of playback to converge.
let earlyReduction = db(energy(off, 0, 2) / energy(on, 0, 2))
let reduction = db(energy(off, 3, 8) / energy(on, 3, 8))
// Second talker alone after the speaker stops: it must keep its level.
let talkerLevel = db(energy(on, 11.5, 14) / energy(talkerOnly, 11.5, 14))
// The canceller's band filters delay its output by a few ms. Find that delay
// from the second talker alone, then measure how much of the second talker
// survives while both play, and how much echo is gone beside it.
let lag = (0..<480).max { a, b in
    dot(on, delayed(talkerOnly, by: a), 11.5, 14) < dot(on, delayed(talkerOnly, by: b), 11.5, 14)
}!
let talkerAligned = delayed(talkerOnly, by: lag)
let talkerKept = dot(on, talkerAligned, 8.5, 11) / energy(talkerAligned, 8.5, 11)
let echoLeft = (0..<on.count).map { on[$0] - Float(talkerKept) * talkerAligned[$0] }
let echoBefore = (0..<off.count).map { off[$0] - talkerOnly[$0] }
let doubleTalkReduction = db(energy(echoBefore, 8.5, 11) / energy(echoLeft, 8.5, 11))

print(String(format: "echo reduction while only the speaker plays: %.1f dB in the first 2 s, %.1f dB from 3 s", earlyReduction, reduction))
print(String(format: "second talker level after the speaker stops: %+.1f dB", talkerLevel))
print(String(format: "while both play: second talker kept at %.2f of its amplitude, echo reduced %.1f dB (output delay %.1f ms)",
             talkerKept, doubleTalkReduction, Double(lag) / 16))

guard reduction >= 25 else { fail("echo reduced by only \(reduction) dB") }
guard abs(talkerLevel) <= 3 else { fail("second talker level changed by \(talkerLevel) dB") }
guard talkerKept >= 0.5 else { fail("double talk kept only \(talkerKept) of the second talker") }
guard doubleTalkReduction >= 6 else { fail("double talk reduced echo by only \(doubleTalkReduction) dB") }
print("PASS echo canceller: production writer, 48 kHz in, 16 kHz 16-bit mono out")
