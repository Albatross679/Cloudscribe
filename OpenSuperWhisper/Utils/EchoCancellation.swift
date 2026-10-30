import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Speaker sound removal for dictation.
///
/// The microphone and a tap of everything the Mac plays arrive together in
/// one private aggregate device, on one clock. The played audio is the
/// reference WebRTC's echo canceller (AEC3) subtracts from the microphone,
/// and the cleaned microphone is written in the recorder's usual 16 kHz,
/// 16-bit mono WAV, so transcription is unchanged.
enum EchoCancellation {
    static let log = Logger(subsystem: "local.clouddictation.OpenSuperWhisper", category: "recording")

    /// The file format AudioRecorder has always written.
    static let fileSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false
    ]
}

/// Cuts paired microphone and speaker audio into 10 ms frames, removes the
/// echo, and writes the result at 16 kHz. Not thread safe: one queue feeds it.
final class EchoCancelledWriter {
    enum Failure: Error, CustomStringConvertible {
        case unsupportedRate(Double)
        case converter

        var description: String {
            switch self {
            case .unsupportedRate(let rate): return "echo canceller does not support \(rate) Hz"
            case .converter: return "cannot convert to 16 kHz"
            }
        }
    }

    let sampleRate: Double
    let frameLength: Int
    private var canceller: OpaquePointer?
    private var file: AVAudioFile?
    private let converter: AVAudioConverter
    private let processed: AVAudioPCMBuffer
    private let converted: AVAudioPCMBuffer
    private var microphone: [Float] = []
    private var speaker: [Float] = []
    /// Frames the canceller rejected; they are written unprocessed.
    private(set) var failedFrames = 0
    /// Loudest speaker sample seen, to tell a silent reference apart in logs.
    private(set) var speakerPeak: Float = 0

    /// cancelEcho false writes the microphone unchanged, for comparisons.
    init(url: URL, sampleRate: Double, cancelEcho: Bool = true) throws {
        let rate = Int(sampleRate.rounded())
        guard Double(rate) == sampleRate, rate % 100 == 0 else { throw Failure.unsupportedRate(sampleRate) }
        self.sampleRate = sampleRate
        frameLength = rate / 100
        if cancelEcho {
            guard let canceller = echo_canceller_create(Int32(rate)) else { throw Failure.unsupportedRate(sampleRate) }
            self.canceller = canceller
        }
        let file = try AVAudioFile(forWriting: url, settings: EchoCancellation.fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let input = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let converter = AVAudioConverter(from: input, to: file.processingFormat) else {
            if let canceller { echo_canceller_destroy(canceller) }
            throw Failure.converter
        }
        // Half a second per conversion. The output holds all of it, so the
        // converter never keeps part of an input buffer for a later call.
        let capacity = AVAudioFrameCount(frameLength * 50)
        processed = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: capacity)!
        converted = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(Double(capacity) * max(1, 16000 / sampleRate)) + 1024)!
        self.file = file
        self.converter = converter
    }

    deinit {
        if let canceller { echo_canceller_destroy(canceller) }
    }

    /// Seconds written so far.
    var duration: TimeInterval {
        Double(file?.length ?? 0) / 16000
    }

    func append(microphone mic: UnsafeBufferPointer<Float>, speaker played: UnsafeBufferPointer<Float>) throws {
        microphone.append(contentsOf: mic)
        speaker.append(contentsOf: played)
        for sample in played { speakerPeak = max(speakerPeak, abs(sample)) }

        var offset = 0
        while microphone.count - offset >= frameLength {
            let available = Int(processed.frameCapacity - processed.frameLength)
            if available < frameLength { try write(endOfStream: false) }
            let destination = processed.floatChannelData![0] + Int(processed.frameLength)
            microphone.withUnsafeBufferPointer { destination.update(from: $0.baseAddress! + offset, count: frameLength) }
            if let canceller {
                let status = speaker.withUnsafeBufferPointer {
                    echo_canceller_process(canceller, $0.baseAddress! + offset, destination)
                }
                if status != 0 {
                    failedFrames += 1
                    microphone.withUnsafeBufferPointer { destination.update(from: $0.baseAddress! + offset, count: frameLength) }
                }
            }
            processed.frameLength += AVAudioFrameCount(frameLength)
            offset += frameLength
        }
        microphone.removeFirst(offset)
        speaker.removeFirst(offset)
        try write(endOfStream: false)
    }

    /// Flushes the resampler and closes the file. The last partial 10 ms
    /// frame is dropped.
    @discardableResult
    func finish() throws -> TimeInterval {
        try write(endOfStream: true)
        let seconds = duration
        file = nil
        return seconds
    }

    private func write(endOfStream: Bool) throws {
        guard let file else { return }
        var supplied = processed.frameLength == 0
        while true {
            converted.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                if !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return self.processed
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if converted.frameLength > 0 { try file.write(from: converted) }
            if status != .haveData { break }
        }
        processed.frameLength = 0
    }
}

/// Microphone and speaker samples handed from the audio thread to the
/// processing queue. Fixed size, so the audio thread never allocates.
private final class SampleRing {
    private let capacity: Int
    private let microphone: UnsafeMutablePointer<Float>
    private let speaker: UnsafeMutablePointer<Float>
    private var start = 0
    private var count = 0
    private var lock = os_unfair_lock()
    /// Samples dropped because the processing queue fell behind.
    private(set) var dropped = 0

    init(capacity: Int) {
        self.capacity = capacity
        microphone = .allocate(capacity: capacity)
        speaker = .allocate(capacity: capacity)
    }

    deinit {
        microphone.deallocate()
        speaker.deallocate()
    }

    func write(microphone mic: UnsafePointer<Float>, speaker played: UnsafePointer<Float>, count frames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let accepted = min(frames, capacity - count)
        dropped += frames - accepted
        for index in 0..<accepted {
            let slot = (start + count + index) % capacity
            microphone[slot] = mic[index]
            speaker[slot] = played[index]
        }
        count += accepted
    }

    /// Moves everything buffered into the given arrays.
    func read(microphone mic: inout [Float], speaker played: inout [Float]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        mic.removeAll(keepingCapacity: true)
        played.removeAll(keepingCapacity: true)
        for index in 0..<count {
            let slot = (start + index) % capacity
            mic.append(microphone[slot])
            played.append(speaker[slot])
        }
        start = (start + count) % capacity
        count = 0
    }
}

/// Records one microphone with the speaker sound removed.
final class EchoCancellingRecorder {
    enum Failure: Error, CustomStringConvertible {
        case unsupportedSystem
        case status(String, OSStatus)
        case layout(String)

        var description: String {
            switch self {
            case .unsupportedSystem: return "process taps need macOS 14.2"
            case .status(let call, let status): return "\(call) failed with \(status)"
            case .layout(let detail): return detail
            }
        }
    }

    /// A start running on its own thread, so a dictation never waits on Core
    /// Audio. The first time, Core Audio can block until the person answers
    /// the System Audio Recording prompt.
    final class Start {
        let url: URL
        private let lock = NSLock()
        private var result: Result<EchoCancellingRecorder, Error>?
        private var abandoned = false

        fileprivate init(url: URL) {
            self.url = url
        }

        /// The running recorder, or nil if it failed or has not started yet.
        /// A start still running is abandoned: it stops itself and removes
        /// its file when it finishes.
        func take() -> EchoCancellingRecorder? {
            lock.lock()
            defer { lock.unlock() }
            guard let result else {
                abandoned = true
                EchoCancellation.log.notice("Echo cancellation had not started when the recording stopped")
                return nil
            }
            switch result {
            case .success(let recorder): return recorder
            case .failure(let error):
                EchoCancellation.log.error("Echo cancellation did not start: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        /// False if the recording already stopped, so the caller cleans up.
        fileprivate func finish(_ value: Result<EchoCancellingRecorder, Error>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !abandoned else { return false }
            result = value
            return true
        }
    }

    private static let pendingLock = NSLock()
    private static var pending: Start?

    /// Starts capture on its own thread. Nil while an earlier start is still
    /// blocked, so starts do not pile up behind an open prompt.
    static func begin(microphone: AudioDeviceID, url: URL) -> Start? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard pending == nil else {
            EchoCancellation.log.notice("Echo cancellation skipped: an earlier start is still waiting on Core Audio")
            return nil
        }
        let start = Start(url: url)
        pending = start
        Thread.detachNewThread {
            let result = Result { try EchoCancellingRecorder(microphone: microphone, url: url) }
            pendingLock.lock()
            pending = nil
            pendingLock.unlock()
            guard !start.finish(result) else { return }
            if case .success(let late) = result {
                _ = late.stop()
            }
            try? FileManager.default.removeItem(at: url)
            EchoCancellation.log.notice("A late echo cancellation start finished and was discarded")
        }
        return start
    }

    let url: URL
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ring: SampleRing
    private let writer: EchoCancelledWriter
    private let queue = DispatchQueue(label: "local.clouddictation.echo-cancellation", qos: .userInitiated)
    private var drainTimer: DispatchSourceTimer?
    private var drainedMicrophone: [Float] = []
    private var drainedSpeaker: [Float] = []
    private var writeError: Error?

    init(microphone: AudioDeviceID, url: URL) throws {
        guard #available(macOS 14.2, *) else { throw Failure.unsupportedSystem }
        let devices = try Self.makeAggregate(microphone: microphone)
        let layout: InputLayout
        let rate: Double
        do {
            layout = try Self.inputLayout(aggregate: devices.aggregate, microphone: microphone)
            rate = try Self.sampleRate(of: devices.aggregate)
            let tapRate = try Self.tapSampleRate(devices.tap)
            guard tapRate == rate else {
                throw Failure.layout("speakers run at \(tapRate) Hz but the microphone at \(rate) Hz")
            }
            writer = try EchoCancelledWriter(url: url, sampleRate: rate)
        } catch {
            AudioHardwareDestroyAggregateDevice(devices.aggregate)
            AudioHardwareDestroyProcessTap(devices.tap)
            throw error
        }
        self.url = url
        tapID = devices.tap
        aggregateID = devices.aggregate
        ring = SampleRing(capacity: Int(rate) * 4)
        do {
            try start(layout: layout)
        } catch {
            teardown()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        EchoCancellation.log.notice("Echo cancelled recording at \(rate, privacy: .public) Hz, microphone channels \(layout.microphoneChannels, privacy: .public), speaker channels \(layout.speakerChannels, privacy: .public)")
    }

    deinit {
        teardown()
    }

    /// Stops capture, writes what is left and returns the recorded seconds.
    func stop() -> TimeInterval {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        teardown()
        return queue.sync {
            drainTimer?.cancel()
            drainTimer = nil
            drain()
            do {
                let seconds = try writer.finish()
                EchoCancellation.log.notice("Echo cancelled recording finished: \(seconds, privacy: .public) s, speaker peak \(self.writer.speakerPeak, privacy: .public), rejected frames \(self.writer.failedFrames, privacy: .public), dropped samples \(self.ring.dropped, privacy: .public)")
                return writeError == nil ? seconds : 0
            } catch {
                EchoCancellation.log.error("Echo cancelled recording failed: \(error.localizedDescription, privacy: .public)")
                return 0
            }
        }
    }

    private func drain() {
        ring.read(microphone: &drainedMicrophone, speaker: &drainedSpeaker)
        guard !drainedMicrophone.isEmpty, writeError == nil else { return }
        do {
            try drainedMicrophone.withUnsafeBufferPointer { mic in
                try drainedSpeaker.withUnsafeBufferPointer { played in
                    try writer.append(microphone: mic, speaker: played)
                }
            }
        } catch {
            writeError = error
            EchoCancellation.log.error("Echo cancelled write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct InputLayout {
        /// Buffer index ranges: the microphone's streams come first in the
        /// aggregate, then the tap's.
        var microphoneBuffers: Range<Int>
        var speakerBuffers: Range<Int>
        var microphoneChannels: Int
        var speakerChannels: Int
    }

    private func start(layout: InputLayout) throws {
        let ring = ring
        let scratchFrames = 16384
        let mic = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)
        let played = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)
        scratch = (mic, played)
        let micScale = 1 / Float(layout.microphoneChannels)
        let speakerScale = 1 / Float(layout.speakerChannels)

        // Runs on the real-time audio thread: mixes each side to mono and
        // hands it over, nothing else.
        let block: AudioDeviceIOBlock = { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard buffers.count >= layout.speakerBuffers.upperBound else { return }
            let first = buffers[layout.microphoneBuffers.lowerBound]
            let frames = min(Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(max(first.mNumberChannels, 1))), scratchFrames)
            mic.update(repeating: 0, count: frames)
            played.update(repeating: 0, count: frames)
            func mix(_ range: Range<Int>, into target: UnsafeMutablePointer<Float>, scale: Float) {
                for index in range {
                    let buffer = buffers[index]
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let channels = Int(buffer.mNumberChannels)
                    let available = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1)))
                    for frame in 0..<available {
                        var sum: Float = 0
                        for channel in 0..<channels { sum += data[frame * channels + channel] }
                        target[frame] += sum * scale
                    }
                }
            }
            mix(layout.microphoneBuffers, into: mic, scale: micScale)
            mix(layout.speakerBuffers, into: played, scale: speakerScale)
            ring.write(microphone: mic, speaker: played, count: frames)
        }

        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block), "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.02, repeating: 0.02)
        timer.setEventHandler { [weak self] in self?.drain() }
        drainTimer = timer
        timer.resume()

        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    private var scratch: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)?

    private func teardown() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // The IO proc is gone, so nothing reads the scratch buffers any more.
        if let (mic, played) = scratch {
            mic.deallocate()
            played.deallocate()
            scratch = nil
        }
    }

    @available(macOS 14.2, *)
    private static func makeAggregate(microphone: AudioDeviceID) throws -> (tap: AudioObjectID, aggregate: AudioObjectID) {
        let microphoneUID: CFString = try property(microphone, kAudioDevicePropertyDeviceUID)

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Cloudscribe speaker reference"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cloudscribe echo cancellation",
            kAudioAggregateDeviceUIDKey: "local.clouddictation.echo-cancellation.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: microphoneUID as String,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: microphoneUID as String]],
            // With auto start on, the aggregate runs no IO at all, microphone
            // included, until something plays. Off, it runs from the start
            // and the tap hears silence until then.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure.status("AudioHardwareCreateAggregateDevice", status)
        }
        return (tap, aggregate)
    }

    private static func inputLayout(aggregate: AudioObjectID, microphone: AudioDeviceID) throws -> InputLayout {
        let all = try inputChannelsPerBuffer(aggregate)
        let microphoneCount = try inputChannelsPerBuffer(microphone).count
        guard microphoneCount > 0, all.count > microphoneCount else {
            throw Failure.layout("aggregate has \(all.count) input buffers, microphone \(microphoneCount)")
        }
        for stream in try inputStreams(aggregate) {
            let format: AudioStreamBasicDescription = try property(stream, kAudioStreamPropertyVirtualFormat)
            let float = format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mBitsPerChannel == 32
                && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            guard float else { throw Failure.layout("input stream is not interleaved Float32") }
        }
        let microphoneBuffers = 0..<microphoneCount
        let speakerBuffers = microphoneCount..<all.count
        return InputLayout(
            microphoneBuffers: microphoneBuffers,
            speakerBuffers: speakerBuffers,
            microphoneChannels: max(1, microphoneBuffers.reduce(0) { $0 + all[$1] }),
            speakerChannels: max(1, speakerBuffers.reduce(0) { $0 + all[$1] })
        )
    }

    private static func inputChannelsPerBuffer(_ device: AudioObjectID) throws -> [Int] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "stream configuration size")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "stream configuration")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    private static func inputStreams(_ device: AudioObjectID) throws -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "streams size")
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams), "streams")
        return streams
    }

    private static func sampleRate(of device: AudioObjectID) throws -> Double {
        try property(device, kAudioDevicePropertyNominalSampleRate)
    }

    private static func tapSampleRate(_ tap: AudioObjectID) throws -> Double {
        let format: AudioStreamBasicDescription = try property(tap, kAudioTapPropertyFormat)
        return format.mSampleRate
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, value), "property \(selector)")
        return value.move()
    }
}

private func check(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else { throw EchoCancellingRecorder.Failure.status(call, status) }
}
