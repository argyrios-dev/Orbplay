import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
@preconcurrency import AVFoundation
import Vision

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let isBluetooth: Bool
}

@MainActor
final class SpatialAudio: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var status = "System audio is not being processed"
    @Published var error: String?
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var inputLevel: Float = 0
    @Published var selectedOutputUID = ""
    @Published var sourceX = 0.0 { didSet { updateSpatialDSP() } }
    @Published var sourceY = 0.0
    @Published var sourceZ = -1.0
    @Published private(set) var headYaw: Float = 0
    @Published var equalizerEnabled = true { didSet { updateEQ() } }
    @Published var gains = Array(repeating: 0.0, count: 10) { didSet { updateEQ() } }
    @Published var selectedEQPreset = EQPreset.flat.rawValue

    private let dsp = AudioDSPState()
    let headTracker = CameraHeadTracker()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var meterTask: Task<Void, Never>?
    private let ioQueue = DispatchQueue(label: "com.orbplay.audio-io", qos: .userInitiated)
    private let frequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    init() {
        refreshOutputDevices()
        if let savedUID = UserDefaults.standard.string(forKey: "Orbplay.outputUID"), outputDevices.contains(where: { $0.uid == savedUID }) {
            selectedOutputUID = savedUID
        }
        updateEQ()
        headTracker.onOrientation = { [weak self] yaw, _ in
            self?.headYaw = yaw
            self?.updateSpatialDSP()
        }
    }

    func toggleProcessing() {
        isProcessing ? stopProcessing() : startProcessing()
    }

    func refreshOutputDevices() {
        do {
            let devices = try Self.readOutputDevices()
            outputDevices = devices
            if !devices.contains(where: { $0.uid == selectedOutputUID }) {
                let defaultUID = try? Self.defaultOutputUID()
                selectedOutputUID = devices.first(where: { $0.uid == defaultUID })?.uid
                    ?? devices.first(where: \.isBluetooth)?.uid
                    ?? devices.first?.uid ?? ""
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func selectOutput(_ uid: String) {
        guard uid != selectedOutputUID, outputDevices.contains(where: { $0.uid == uid }) else { return }
        selectedOutputUID = uid
        UserDefaults.standard.set(uid, forKey: "Orbplay.outputUID")
        if isProcessing {
            stopProcessing()
            startProcessing()
        }
    }

    func startProcessing() {
        guard !isProcessing else { return }
        guard #available(macOS 14.2, *) else {
            error = "System-wide audio capture requires macOS 14.2 or later."
            return
        }
        error = nil
        refreshOutputDevices()
        guard !selectedOutputUID.isEmpty else {
            error = "No audio output is available. Connect headphones or choose an output in System Settings."
            return
        }
        do {
            try createTapAndAggregateDevice(outputUID: selectedOutputUID)
            try startIOProc()
            isProcessing = true
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.inputLevel = self.dsp.inputPeak
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }
            status = "Capturing and sending audio to \(outputDevices.first(where: { $0.uid == selectedOutputUID })?.name ?? "the selected output")"
        } catch {
            stopProcessing()
            self.error = error.localizedDescription
            status = "Could not start system audio processing"
        }
    }

    func stopProcessing() {
        meterTask?.cancel()
        meterTask = nil
        inputLevel = 0
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isProcessing = false
        status = "System audio is not being processed"
    }

    func setSource(x: Double, y: Double) {
        // The control is a top-down listening map: up is in front, down is behind.
        // Keep the source on the horizontal plane so front/back changes are audible.
        let px = min(0.94, max(-0.94, x))
        let forward = min(0.94, max(-0.94, y))
        let length = sqrt(px * px + forward * forward)
        if length > 0.96 {
            sourceX = px / length * 0.96
            sourceZ = -forward / length * 0.96
        } else {
            sourceX = px
            sourceZ = -forward
        }
        sourceY = 0
        dsp.rearAmount = Float(max(0, sourceZ))
        updateSpatialDSP()
    }

    func centerSource() {
        sourceX = 0
        sourceY = 0
        sourceZ = -1
        dsp.rearAmount = 0
        updateSpatialDSP()
    }

    private func updateSpatialDSP() {
        let azimuth = atan2(Float(sourceX), max(0.001, -Float(sourceZ)))
        // Vision's yaw sign is opposite the listener-relative rotation convention.
        // Turning the head right must move a fixed source toward the left ear.
        let listenerRelativeAzimuth = azimuth + headYaw
        dsp.pan = min(1, max(-1, sin(listenerRelativeAzimuth)))
    }

    private func createTapAndAggregateDevice(outputUID: String) throws {
        let processObject = try currentProcessObjectID()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [processObject])
        let uuid = UUID()
        description.name = "Orbplay System Mix"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var createdTap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &createdTap), "Could not create the system audio capture")
        tapID = createdTap

        let device = try Self.readOutputDevices().first(where: { $0.uid == outputUID })
        guard let device else { throw OrbplayAudioError.outputUnavailable }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Orbplay System Audio",
            kAudioAggregateDeviceUIDKey: "com.orbplay.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceClockDeviceKey: device.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: device.uid,
                kAudioSubDeviceDriftCompensationKey: false
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uuid.uuidString,
                kAudioSubTapDriftCompensationKey: !device.isBluetooth
            ]]
        ]
        var createdAggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregate), "Could not create the audio route for \(device.name)")
        aggregateID = createdAggregate
        guard Self.waitUntilReady(createdAggregate) else { throw OrbplayAudioError.aggregateNotReady }
    }

    private func startIOProc() throws {
        guard aggregateID != kAudioObjectUnknown else { throw OrbplayAudioError.aggregateNotReady }
        var newIOProc: AudioDeviceIOProcID?
        let state = dsp
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&newIOProc, aggregateID, ioQueue) { _, inputData, _, outputData, _ in
                state.process(input: inputData, output: outputData)
            },
            "Core Audio could not start playback on the selected output"
        )
        guard let newIOProc else { throw OrbplayAudioError.ioProcUnavailable }
        ioProcID = newIOProc
        try check(AudioDeviceStart(aggregateID, newIOProc), "Could not open the selected output. Check that your Bluetooth headphones are still connected.")
    }

    private func currentProcessObjectID() throws -> AudioObjectID {
        var pid = getpid()
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject), "Core Audio could not identify Orbplay")
        guard processObject != kAudioObjectUnknown else { throw OrbplayAudioError.processNotFound }
        return processObject
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw OrbplayAudioError.coreAudio(operation, status) }
    }

    private func updateEQ() {
        dsp.configureEQ(frequencies: frequencies, gains: gains.map(Float.init), enabled: equalizerEnabled)
    }

    func applyEQPreset(_ preset: EQPreset) {
        selectedEQPreset = preset.rawValue
        gains = preset.gains
    }

    func setEQGain(_ value: Double, at index: Int) {
        guard gains.indices.contains(index) else { return }
        gains[index] = value
        selectedEQPreset = EQPreset.allCases.first(where: { $0.gains == gains })?.rawValue ?? EQPreset.custom.rawValue
    }

    private static func readOutputDevices() throws -> [AudioOutputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try checkStatic(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "Could not read audio outputs")
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        try checkStatic(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids), "Could not list audio outputs")
        return ids.compactMap { id in
            guard let channels = try? outputChannelCount(id), channels > 0,
                  let name = try? readString(id, selector: kAudioObjectPropertyName),
                  let uid = try? readString(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name, isBluetooth: isBluetooth(id))
        }.sorted { lhs, rhs in
            if lhs.isBluetooth != rhs.isBluetooth { return lhs.isBluetooth }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func outputChannelCount(_ id: AudioObjectID) throws -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        try checkStatic(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Could not query output channels")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try checkStatic(AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw), "Could not query output channels")
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func readString(_ id: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try checkStatic(withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }, "Could not read the device name")
        return value as String
    }

    private static func defaultOutputUID() throws -> String {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkStatic(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id), "Could not find the Mac's default output")
        return try readString(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func isBluetooth(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func waitUntilReady(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsAlive)
        for _ in 0..<100 {
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr, alive != 0 { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func checkStatic(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw OrbplayAudioError.coreAudio(message, status) }
    }
}

private final class AudioDSPState: @unchecked Sendable {
    var pan: Float = 0
    var rearAmount: Float = 0
    var inputPeak: Float = 0
    private let configurationLock = NSLock()
    private var coefficients = Array(repeating: Biquad(), count: 10)
    private var memories = Array(repeating: [FilterMemory(), FilterMemory()], count: 10)
    private var eqIsEnabled = true
    private var rearLowPassState: [Float] = [0, 0]

    func configureEQ(frequencies: [Float], gains: [Float], enabled: Bool) {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        eqIsEnabled = enabled
        for index in 0..<min(10, min(frequencies.count, gains.count)) {
            coefficients[index] = Biquad.peaking(frequency: frequencies[index], gainDB: gains[index], sampleRate: 48_000)
        }
    }

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard inputs.count > 0, !outputs.isEmpty else { return }
        let panValue = min(1, max(-1, pan))
        let rearValue = min(1, max(0, rearAmount))
        let leftGain = sqrt((1 - panValue) * 0.5) * 1.41421356
        let rightGain = sqrt((1 + panValue) * 0.5) * 1.41421356
        let rearCutoff: Float = 18_000 - rearValue * 12_000
        let rearFilterCoefficient = exp(-2 * Float.pi * rearCutoff / 48_000)
        var peak: Float = 0
        for (index, destination) in outputs.enumerated() {
            guard let dst = destination.mData else { continue }
            let sourceIndex = inputs.count >= outputs.count ? inputs.count - outputs.count + index : min(index, inputs.count - 1)
            let source = inputs[sourceIndex]
            guard let src = source.mData else {
                memset(dst, 0, Int(destination.mDataByteSize))
                continue
            }
            let frameBytes = MemoryLayout<Float>.size * max(1, Int(destination.mNumberChannels))
            let frames = min(Int(destination.mDataByteSize), Int(source.mDataByteSize)) / frameBytes
            let srcSamples = src.assumingMemoryBound(to: Float.self)
            let dstSamples = dst.assumingMemoryBound(to: Float.self)
            let channels = max(1, Int(destination.mNumberChannels))
            let srcChannels = max(1, Int(source.mNumberChannels))
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let sourceChannel = inputs.count == 1 ? min(index, srcChannels - 1) : min(channel, srcChannels - 1)
                    var sample = srcSamples[frame * srcChannels + sourceChannel]
                    peak = max(peak, abs(sample))
                    if eqIsEnabled, channels <= 2 {
                        let side = min(channel, 1)
                        for band in 0..<coefficients.count {
                            sample = coefficients[band].process(sample, memory: &memories[band][side])
                        }
                    }
                    if rearValue > 0.001, channels <= 2 {
                        let side = min(channel, 1)
                        rearLowPassState[side] = (1 - rearFilterCoefficient) * sample + rearFilterCoefficient * rearLowPassState[side]
                        sample += (rearLowPassState[side] - sample) * rearValue
                    }
                    let gain = channel == 0 ? leftGain : (channel == 1 ? rightGain : 1)
                    // Soft limiting only engages close to full scale, so cutting an EQ
                    // band remains directly audible instead of being hidden by global attenuation.
                    let mixed = sample * gain
                    let magnitude = abs(mixed)
                    let safeSample = magnitude <= 0.98 ? mixed : copysign(0.98 + 0.02 * tanh((magnitude - 0.98) / 0.02), mixed)
                    dstSamples[frame * channels + channel] = safeSample
                }
            }
            let writtenBytes = frames * frameBytes
            if writtenBytes < Int(destination.mDataByteSize) {
                memset(dst.advanced(by: writtenBytes), 0, Int(destination.mDataByteSize) - writtenBytes)
            }
        }
        inputPeak = max(peak, inputPeak * 0.75)
    }

}

private struct FilterMemory {
    var z1: Float = 0
    var z2: Float = 0
}

private struct Biquad {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0

    static func peaking(frequency: Float, gainDB: Float, sampleRate: Float) -> Biquad {
        let a = pow(10, gainDB / 40)
        let omega = 2 * Float.pi * frequency / sampleRate
        let alpha = sin(omega) / 2
        let a0 = 1 + alpha / a
        return Biquad(
            b0: (1 + alpha * a) / a0,
            b1: (-2 * cos(omega)) / a0,
            b2: (1 - alpha * a) / a0,
            a1: (-2 * cos(omega)) / a0,
            a2: (1 - alpha / a) / a0
        )
    }

    @inline(__always) func process(_ input: Float, memory: inout FilterMemory) -> Float {
        let output = b0 * input + memory.z1
        memory.z1 = b1 * input - a1 * output + memory.z2
        memory.z2 = b2 * input - a2 * output
        return output
    }

}

enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case trebleBoost = "Treble Boost"
    case vocal = "Vocals"
    case rock = "Rock"
    case bassCut = "Bass Cut"
    case custom = "Custom"

    var id: String { rawValue }
    var gains: [Double] {
        switch self {
        case .flat, .custom: return Array(repeating: 0, count: 10)
        case .bassBoost: return [8, 7, 5, 2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost: return [0, 0, 0, 0, 0, 1, 3, 5, 7, 8]
        case .vocal: return [-2, -2, 0, 3, 5, 4, 1, -1, -2, -2]
        case .rock: return [5, 3, -2, -3, 1, 3, 5, 4, 5, 5]
        case .bassCut: return [-8, -7, -5, -2, 0, 0, 0, 0, 0, 0]
        }
    }
}

enum HeadTrackingSensitivity: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }
    var multiplier: Float {
        switch self {
        case .low: return 0.8
        case .medium: return 1.8
        case .high: return 3.6
        }
    }
}

private enum OrbplayAudioError: LocalizedError {
    case processNotFound, outputUnavailable, aggregateNotReady, ioProcUnavailable
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .processNotFound: return "Core Audio could not identify Orbplay."
        case .outputUnavailable: return "The selected output is no longer available."
        case .aggregateNotReady: return "Core Audio did not prepare the output. Select your headphones again and try once more."
        case .ioProcUnavailable: return "Core Audio could not create the output processor."
        case let .coreAudio(message, status):
            if status == -10868 || status == -10867 {
                return "\(message) (\(status)). Check the System Audio Recording permission in Privacy & Security, then reopen Orbplay."
            }
            return "\(message) (Core Audio: \(status)). Check the System Audio Recording permission in Privacy & Security."
        }
    }
}

@MainActor
final class CameraHeadTracker: ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var status = "Tracking is off"
    @Published private(set) var hasFace = false
    @Published private(set) var yaw: Float = 0
    @Published private(set) var pitch: Float = 0
    @Published var sensitivity: HeadTrackingSensitivity = .high

    var onOrientation: ((Float, Float) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.orbplay.camera-session", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "com.orbplay.face-camera", qos: .userInitiated)
    private let framesQueue = DispatchQueue(label: "com.orbplay.face-vision", qos: .userInitiated)
    private var frameDelegate: FaceFrameDelegate?
    private var isStarting = false
    private var sessionGeneration = 0
    private var referenceYaw: Float?
    private var referencePitch: Float?
    private var smoothedYaw: Float = 0
    private var smoothedPitch: Float = 0
    private var lastFaceTime = Date.distantPast
    private var noFaceTask: Task<Void, Never>?

    func start() {
        guard !isTracking, !isStarting else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            status = "Waiting for camera permission…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.status = "Camera permission denied. Enable it in System Settings → Privacy & Security → Camera."
                    }
                }
            }
        case .denied:
            status = "Camera permission denied. Enable it in System Settings → Privacy & Security → Camera."
        case .restricted:
            status = "Camera access is restricted on this Mac."
        @unknown default:
            status = "Could not check camera permission."
        }
    }

    func stop() {
        guard isTracking || isStarting else { return }
        sessionGeneration += 1
        isStarting = false
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
        noFaceTask?.cancel()
        noFaceTask = nil
        frameDelegate = nil
        isTracking = false
        hasFace = false
        yaw = 0
        pitch = 0
        referenceYaw = nil
        referencePitch = nil
        smoothedYaw = 0
        smoothedPitch = 0
        onOrientation?(0, 0)
        status = "Tracking is off"
    }

    func recenter() {
        guard isTracking, hasFace else {
            status = "Look at the camera and wait for face detection before recentering."
            return
        }
        referenceYaw = smoothedYaw + (referenceYaw ?? 0)
        referencePitch = smoothedPitch + (referencePitch ?? 0)
        smoothedYaw = 0
        smoothedPitch = 0
        yaw = 0
        pitch = 0
        onOrientation?(0, 0)
        status = "Center updated. Turn your head to test tracking."
    }

    private func configureAndStart() {
        guard !isTracking, !isStarting else { return }
        guard let camera = AVCaptureDevice.default(for: .video) else {
            status = "No camera was found on this Mac."
            return
        }
        isStarting = true
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                isStarting = false
                status = "Could not connect the camera to Orbplay."
                return
            }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            let delegate = FaceFrameDelegate(queue: framesQueue) { [weak self] detectedYaw, detectedPitch in
                Task { @MainActor in self?.receivePose(yaw: detectedYaw, pitch: detectedPitch) }
            }
            frameDelegate = delegate
            output.setSampleBufferDelegate(delegate, queue: captureQueue)
            guard session.canAddOutput(output) else {
                session.removeInput(input)
                session.commitConfiguration()
                frameDelegate = nil
                isStarting = false
                status = "Could not start camera image analysis."
                return
            }
            session.addOutput(output)
            session.commitConfiguration()
            sessionGeneration += 1
            let generation = sessionGeneration
            let session = self.session
            sessionQueue.async { [weak self] in
                session.startRunning()
                Task { @MainActor in
                    guard let self else { return }
                    guard self.sessionGeneration == generation else {
                        self.sessionQueue.async {
                            if session.isRunning { session.stopRunning() }
                        }
                        return
                    }
                    self.isStarting = false
                    guard session.isRunning else {
                        self.frameDelegate = nil
                        self.status = "The camera session could not start. Check that the camera is available and try again."
                        return
                    }
                    self.isTracking = true
                    self.status = "Camera is active. Look at it to set your center position."
                    self.noFaceTask = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            guard let self else { return }
                            if self.isTracking, Date().timeIntervalSince(self.lastFaceTime) > 1.2 {
                                self.hasFace = false
                                self.yaw = 0
                                self.pitch = 0
                                self.onOrientation?(0, 0)
                                self.status = "No face detected. Sit in front of the camera."
                            }
                        }
                    }
                }
            }
        } catch {
            session.commitConfiguration()
            isStarting = false
            status = "Could not open the camera: \(error.localizedDescription)"
        }
    }

    private func receivePose(yaw detectedYaw: Float, pitch detectedPitch: Float) {
        lastFaceTime = Date()
        hasFace = true
        if referenceYaw == nil {
            referenceYaw = detectedYaw
            referencePitch = detectedPitch
            status = "Face detected. Tracking is active."
        }
        let targetYaw = max(-1.35, min(1.35, (detectedYaw - (referenceYaw ?? detectedYaw)) * sensitivity.multiplier))
        let targetPitch = max(-0.65, min(0.65, detectedPitch - (referencePitch ?? detectedPitch)))
        smoothedYaw += (targetYaw - smoothedYaw) * 0.24
        smoothedPitch += (targetPitch - smoothedPitch) * 0.24
        yaw = smoothedYaw
        pitch = smoothedPitch
        onOrientation?(yaw, pitch)
    }
}

private final class FaceFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let visionQueue: DispatchQueue
    private let onPose: @Sendable (Float, Float) -> Void
    private var lastSubmittedAt: TimeInterval = 0

    init(queue: DispatchQueue, onPose: @escaping @Sendable (Float, Float) -> Void) {
        self.visionQueue = queue
        self.onPose = onPose
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSubmittedAt >= 1.0 / 15.0 else { return }
        lastSubmittedAt = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        visionQueue.async { [onPose] in
            let request = VNDetectFaceRectanglesRequest()
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
                guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
                      let yaw = face.yaw?.floatValue else { return }
                onPose(yaw, face.pitch?.floatValue ?? 0)
            } catch {
                // A bad or dropped frame is ignored; later frames continue tracking.
            }
        }
    }
}
