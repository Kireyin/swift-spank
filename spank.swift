#!/usr/bin/env swift
// spank detects slaps/hits on the laptop and plays audio responses.
// It reads the Apple Silicon accelerometer directly via IOKit HID —
// no separate sensor daemon required. Needs sudo.
//
// Build: swiftc -O -o spank spank.swift -framework IOKit -framework AVFoundation
// Run:   sudo ./spank

import Foundation
import IOKit
import IOKit.hid
import AVFoundation
import Darwin

// MARK: - Version

let version = "dev"

// MARK: - Constants

let decayHalfLife: Double = 30.0
let defaultMinAmplitude: Double = 0.05
let defaultCooldownMs: Int = 750
let defaultSpeedRatio: Double = 1.0
let defaultSensorPollInterval: TimeInterval = 0.01   // 10ms
let defaultMaxSampleBatch: Int = 200
let sensorStartupDelay: TimeInterval = 0.1            // 100ms

// IOKit HID constants for Apple Silicon accelerometer (Bosch BMI286)
let kPageVendor: Int = 0xFF00
let kUsageAccel: Int = 3
let kIMUReportLen: Int = 22
let kIMUDataOffset: Int = 6
let kIMUScale: Double = 65536.0
let kIMUDecimation: Int = 8
let kReportIntervalUS: Int = 1000

// MARK: - Debug Logging

var debugMode = false

func debugLog(_ msg: @autoclosure () -> String) {
    guard debugMode else { return }
    fputs("spank: \(msg())\n", stderr)
}

// MARK: - Types

enum PlayMode {
    case random
    case escalation
}

struct RuntimeTuning {
    var minAmplitude: Double = defaultMinAmplitude
    var cooldown: TimeInterval = Double(defaultCooldownMs) / 1000.0
    var pollInterval: TimeInterval = defaultSensorPollInterval
    var maxBatch: Int = defaultMaxSampleBatch
}

func applyFastOverlay(_ base: inout RuntimeTuning) {
    base.pollInterval = 0.004  // 4ms
    base.cooldown = 0.35       // 350ms
    if base.minAmplitude > 0.18 {
        base.minAmplitude = 0.18
    }
    if base.maxBatch < 320 {
        base.maxBatch = 320
    }
}

struct SoundPack {
    let name: String
    let mode: PlayMode
    var files: [String]
    let isCustom: Bool
    var dir: String

    mutating func loadFiles() throws {
        let fm = FileManager.default
        if isCustom {
            let entries = try fm.contentsOfDirectory(atPath: dir)
            files = entries.filter { !fm.isDirectory(atPath: "\(dir)/\($0)") }
                .map { "\(dir)/\($0)" }
        } else {
            let entries = try fm.contentsOfDirectory(atPath: dir)
            files = entries.filter { $0.hasSuffix(".mp3") }
                .map { "\(dir)/\($0)" }
        }
        files.sort()
        guard !files.isEmpty else {
            throw SpankError.noAudioFiles(dir)
        }
    }
}

struct AccelSample {
    let x: Double
    let y: Double
    let z: Double
}

struct ImpactEvent {
    let time: Date
    let amplitude: Double
    let severity: String
}

struct StdinCommand: Decodable {
    let cmd: String
    var amplitude: Double?
    var cooldown: Int?
    var speed: Double?
}

enum SpankError: Error, CustomStringConvertible {
    case noAudioFiles(String)
    case sensorNotFound
    case sensorOpenFailed(Int32)

    var description: String {
        switch self {
        case .noAudioFiles(let dir):
            return "no audio files found in \(dir)"
        case .sensorNotFound:
            return "accelerometer not found (Apple Silicon required)"
        case .sensorOpenFailed(let code):
            return "failed to open accelerometer (IOKit error \(code))"
        }
    }
}

// MARK: - Thread-Safe State

class SpankState {
    private let queue = DispatchQueue(label: "com.spank.state")
    private var _paused: Bool = false
    private var _minAmplitude: Double
    private var _cooldownMs: Int
    private var _speedRatio: Double
    private var _volumeScaling: Bool
    private var _stdioMode: Bool

    init(minAmplitude: Double, cooldownMs: Int, speedRatio: Double, volumeScaling: Bool, stdioMode: Bool) {
        _minAmplitude = minAmplitude
        _cooldownMs = cooldownMs
        _speedRatio = speedRatio
        _volumeScaling = volumeScaling
        _stdioMode = stdioMode
    }

    var paused: Bool {
        get { queue.sync { _paused } }
        set { queue.sync { _paused = newValue } }
    }
    var minAmplitude: Double {
        get { queue.sync { _minAmplitude } }
        set { queue.sync { _minAmplitude = newValue } }
    }
    var cooldownMs: Int {
        get { queue.sync { _cooldownMs } }
        set { queue.sync { _cooldownMs = newValue } }
    }
    var cooldown: TimeInterval {
        queue.sync { Double(_cooldownMs) / 1000.0 }
    }
    var speedRatio: Double {
        get { queue.sync { _speedRatio } }
        set { queue.sync { _speedRatio = newValue } }
    }
    var volumeScaling: Bool {
        get { queue.sync { _volumeScaling } }
        set { queue.sync { _volumeScaling = newValue } }
    }
    var stdioMode: Bool {
        get { queue.sync { _stdioMode } }
        set { queue.sync { _stdioMode = newValue } }
    }
}

// MARK: - Accelerometer Ring Buffer

class AccelRingBuffer {
    private let capacity = 2048
    private var buffer: [AccelSample]
    private var writeIdx: Int = 0
    private var totalCount: UInt64 = 0
    private let lock = NSLock()

    init() {
        buffer = [AccelSample](repeating: AccelSample(x: 0, y: 0, z: 0), count: capacity)
    }

    func write(_ sample: AccelSample) {
        lock.lock()
        buffer[writeIdx % capacity] = sample
        writeIdx += 1
        totalCount += 1
        lock.unlock()
    }

    func readNew(after: UInt64) -> ([AccelSample], UInt64) {
        lock.lock()
        defer { lock.unlock() }

        let total = totalCount
        if total <= after { return ([], total) }

        var count = Int(total - after)
        if count > capacity { count = capacity }

        var samples: [AccelSample] = []
        samples.reserveCapacity(count)
        let startIdx = writeIdx - count
        for i in 0..<count {
            let idx = (startIdx + i) % capacity
            let safeIdx = idx >= 0 ? idx : idx + capacity
            samples.append(buffer[safeIdx])
        }
        return (samples, total)
    }
}

// MARK: - IOKit HID Accelerometer Reader

class AccelReader {
    let ringBuffer: AccelRingBuffer
    // Keep strong references to prevent deallocation during CFRunLoop
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var hidDevices: [IOHIDDevice] = []  // prevent ARC from releasing
    var ready = false
    var sampleCount: Int = 0

    init(ringBuffer: AccelRingBuffer) {
        self.ringBuffer = ringBuffer
    }

    func start() throws {
        // Step 1: Wake up SPU drivers (critical — without this, sensors stay dormant)
        try wakeSPUDrivers()

        // Step 2: Find and register HID devices
        try registerHIDDevices()

        ready = true
    }

    /// Wake up AppleSPUHIDDriver services by setting sensor properties.
    /// This is the critical step the Go library does that enables the sensor.
    private func wakeSPUDrivers() throws {
        guard let matchDict = IOServiceMatching("AppleSPUHIDDriver") else {
            throw SpankError.sensorNotFound
        }

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
        guard kr == KERN_SUCCESS else {
            throw SpankError.sensorOpenFailed(kr)
        }
        defer { IOObjectRelease(iterator) }

        var driverCount = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            // Set properties to wake the driver
            let props: [(String, Int32)] = [
                ("SensorPropertyReportingState", 1),
                ("SensorPropertyPowerState", 1),
                ("ReportInterval", Int32(kReportIntervalUS)),
            ]
            for (key, val) in props {
                var value = val
                if let cfNum = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value) {
                    IORegistryEntrySetCFProperty(service, key as CFString, cfNum)
                }
            }
            driverCount += 1
            debugLog("[sensor] woke SPU driver #\(driverCount)")
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        if driverCount == 0 {
            debugLog("[sensor] warning: no AppleSPUHIDDriver services found")
        }
    }

    /// Find AppleSPUHIDDevice services and register the accelerometer callback.
    private func registerHIDDevices() throws {
        guard let matchDict = IOServiceMatching("AppleSPUHIDDevice") else {
            throw SpankError.sensorNotFound
        }

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
        guard kr == KERN_SUCCESS else {
            throw SpankError.sensorOpenFailed(kr)
        }
        defer { IOObjectRelease(iterator) }

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        var foundAccel = false

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            // Read PrimaryUsagePage and PrimaryUsage
            guard let upRef = IORegistryEntryCreateCFProperty(service, "PrimaryUsagePage" as CFString, kCFAllocatorDefault, 0),
                  let uRef = IORegistryEntryCreateCFProperty(service, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0) else {
                continue
            }
            let usagePage = (upRef.takeRetainedValue() as! NSNumber).intValue
            let usage = (uRef.takeRetainedValue() as! NSNumber).intValue
            debugLog("[sensor] SPU device: usagePage=0x\(String(usagePage, radix: 16)) usage=\(usage)")

            // Only register accel callback
            guard usagePage == kPageVendor && usage == kUsageAccel else { continue }

            // Create IOHIDDevice from service
            guard let hidDevice = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                fputs("spank: [sensor] failed to create HID device\n", stderr)
                continue
            }

            let openResult = IOHIDDeviceOpen(hidDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                fputs("spank: [sensor] failed to open HID device: \(openResult)\n", stderr)
                continue
            }

            // Allocate report buffer (must stay alive for duration of run loop)
            let bufSize = 4096  // ReportBufSize from Go
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            buf.initialize(repeating: 0, count: bufSize)
            reportBuffers.append(buf)

            // Keep strong reference to prevent ARC deallocation
            hidDevices.append(hidDevice)

            IOHIDDeviceRegisterInputReportCallback(
                hidDevice, buf, bufSize,
                accelReportCallback, selfPtr
            )
            IOHIDDeviceScheduleWithRunLoop(
                hidDevice, CFRunLoopGetCurrent(),
                CFRunLoopMode.defaultMode.rawValue
            )

            debugLog("[sensor] accelerometer registered")
            foundAccel = true
        }

        guard foundAccel else {
            fputs("spank: [sensor] no accelerometer device found\n", stderr)
            throw SpankError.sensorNotFound
        }
    }

    func runLoop() {
        CFRunLoopRun()
    }
}

// C-compatible callback for IOKit HID accelerometer reports
private func accelReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context = context else { return }
    let reader = Unmanaged<AccelReader>.fromOpaque(context).takeUnretainedValue()

    // Only process accelerometer reports (22 bytes)
    guard reportLength == kIMUReportLen else { return }

    if debugMode && reader.sampleCount < 3 {
        let bytes = (0..<min(Int(reportLength), 22)).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
        debugLog("[sensor] report: len=\(reportLength) id=\(reportID) bytes: \(bytes)")
    }

    let off = kIMUDataOffset
    let xRaw = Int32(report[off])
        | (Int32(report[off + 1]) << 8)
        | (Int32(report[off + 2]) << 16)
        | (Int32(report[off + 3]) << 24)
    let yRaw = Int32(report[off + 4])
        | (Int32(report[off + 5]) << 8)
        | (Int32(report[off + 6]) << 16)
        | (Int32(report[off + 7]) << 24)
    let zRaw = Int32(report[off + 8])
        | (Int32(report[off + 9]) << 8)
        | (Int32(report[off + 10]) << 16)
        | (Int32(report[off + 11]) << 24)

    let x = Double(xRaw) / kIMUScale
    let y = Double(yRaw) / kIMUScale
    let z = Double(zRaw) / kIMUScale

    let sample = AccelSample(x: x, y: y, z: z)
    reader.ringBuffer.write(sample)
    reader.sampleCount += 1
    if debugMode && reader.sampleCount % 1000 == 0 {
        debugLog("[sensor] \(reader.sampleCount) samples (x=\(String(format:"%.2f",x)) y=\(String(format:"%.2f",y)) z=\(String(format:"%.2f",z)))")
    }
}

// MARK: - Impact Detector (High-Pass Filter + Multi-Timescale STA/LTA)
// Matches the Go detector: high-pass filter (α=0.95) removes gravity,
// then 3 STA/LTA timescales detect impacts at different durations.

class ImpactDetector {
    let fs: Double = 100.0   // effective sample rate after decimation

    // High-pass filter state (1st order, α=0.95 to remove gravity DC component)
    private let hpAlpha: Double = 0.95
    private var hpPrevX: Double = 0
    private var hpPrevY: Double = 0
    private var hpPrevZ: Double = 0
    private var hpOutX: Double = 0
    private var hpOutY: Double = 0
    private var hpOutZ: Double = 0
    private var hpInitialized = false

    // STA/LTA timescales (from Go detector)
    // Timescale 1: fast (3/100, threshold 3.0)
    // Timescale 2: medium (15/500, threshold 2.5)
    // Timescale 3: slow (50/2000, threshold 2.0)
    private struct STALTAState {
        var sta: Double = 0
        var lta: Double = 0
        let staN: Int
        let ltaN: Int
        let thresholdOn: Double
        let thresholdOff: Double
        var triggered: Bool = false
    }
    private var tiers: [STALTAState] = [
        STALTAState(staN: 3, ltaN: 100, thresholdOn: 3.0, thresholdOff: 1.5),
        STALTAState(staN: 15, ltaN: 500, thresholdOn: 2.5, thresholdOff: 1.3),
        STALTAState(staN: 50, ltaN: 2000, thresholdOn: 2.0, thresholdOff: 1.2),
    ]

    private var sampleCount: Int = 0
    private var decimCounter: Int = 0

    // Refractory period: ignore triggers for N samples after an event
    private let refractorySamples: Int = 30  // ~300ms at 100Hz
    private var refractoryCountdown: Int = 0

    // Track recent filtered magnitudes for amplitude estimation
    private var recentFilteredMag: [Double] = []
    private let windowSize = 50

    var events: [ImpactEvent] = []

    func process(x: Double, y: Double, z: Double, timestamp: TimeInterval) {
        decimCounter += 1
        guard decimCounter >= kIMUDecimation else { return }
        decimCounter = 0

        // High-pass filter to remove gravity (DC component)
        // y[n] = α * (y[n-1] + x[n] - x[n-1])
        if !hpInitialized {
            hpPrevX = x; hpPrevY = y; hpPrevZ = z
            hpOutX = 0; hpOutY = 0; hpOutZ = 0
            hpInitialized = true
            sampleCount += 1
            return
        }

        hpOutX = hpAlpha * (hpOutX + x - hpPrevX)
        hpOutY = hpAlpha * (hpOutY + y - hpPrevY)
        hpOutZ = hpAlpha * (hpOutZ + z - hpPrevZ)
        hpPrevX = x; hpPrevY = y; hpPrevZ = z

        // Dynamic acceleration magnitude (gravity removed)
        let dynMag = sqrt(hpOutX * hpOutX + hpOutY * hpOutY + hpOutZ * hpOutZ)
        let energy = dynMag * dynMag

        sampleCount += 1

        // Update all STA/LTA tiers
        var anyTriggered = false
        var triggerCount = 0
        for i in 0..<tiers.count {
            let staAlpha = 1.0 / Double(min(sampleCount, tiers[i].staN))
            let ltaAlpha = 1.0 / Double(min(sampleCount, tiers[i].ltaN))
            tiers[i].sta += (energy - tiers[i].sta) * staAlpha
            tiers[i].lta += (energy - tiers[i].lta) * ltaAlpha

            guard sampleCount > tiers[i].ltaN else { continue }

            let ratio = tiers[i].sta / (tiers[i].lta + 1e-30)
            if !tiers[i].triggered && ratio > tiers[i].thresholdOn {
                tiers[i].triggered = true
                anyTriggered = true
                triggerCount += 1
            } else if tiers[i].triggered && ratio < tiers[i].thresholdOff {
                tiers[i].triggered = false
            }
        }

        // Track filtered magnitudes for amplitude
        recentFilteredMag.append(dynMag)
        if recentFilteredMag.count > windowSize {
            recentFilteredMag.removeFirst()
        }

        // Refractory period countdown
        if refractoryCountdown > 0 {
            refractoryCountdown -= 1
            // Reset any triggers during refractory period
            for i in 0..<tiers.count { tiers[i].triggered = false }
            return
        }

        if anyTriggered {
            let amplitude = recentFilteredMag.max() ?? dynMag

            let severity: String
            switch amplitude {
            case ..<0.02: severity = "light"
            case ..<0.1: severity = "medium"
            default: severity = "heavy"
            }

            let event = ImpactEvent(time: Date(), amplitude: amplitude, severity: severity)
            events.append(event)
            // Keep only latest event to avoid unbounded growth
            if events.count > 10 { events.removeFirst(events.count - 10) }

            debugLog("[detector] impact! amp=\(String(format:"%.5f",amplitude)) severity=\(severity) tiers=\(triggerCount)")

            // Enter refractory period and reset STA
            refractoryCountdown = refractorySamples
            for i in 0..<tiers.count {
                tiers[i].sta = tiers[i].lta
                tiers[i].triggered = false
            }
        }
    }
}

// MARK: - Slap Tracker

class SlapTracker {
    private var score: Double = 0
    private var lastTime: Date?
    private var total: Int = 0
    private let halfLife: Double = decayHalfLife
    private let scale: Double
    private let pack: SoundPack
    private let lock = NSLock()

    init(pack: SoundPack, cooldown: TimeInterval) {
        self.pack = pack
        let ssMax = 1.0 / (1.0 - pow(0.5, cooldown / decayHalfLife))
        self.scale = (ssMax - 1) / log(Double(pack.files.count + 1))
    }

    func record(now: Date) -> (slapNumber: Int, score: Double) {
        lock.lock()
        defer { lock.unlock() }

        if let last = lastTime {
            let elapsed = now.timeIntervalSince(last)
            score *= pow(0.5, elapsed / halfLife)
        }
        score += 1.0
        lastTime = now
        total += 1
        return (total, score)
    }

    func getFile(score: Double) -> String {
        if pack.mode == .random {
            return pack.files[Int.random(in: 0..<pack.files.count)]
        }

        let maxIdx = pack.files.count - 1
        let idx = min(Int(Double(pack.files.count) * (1.0 - exp(-(score - 1) / scale))), maxIdx)
        return pack.files[idx]
    }
}

// MARK: - Audio Playback

func amplitudeToVolume(_ amplitude: Double) -> Float {
    let minAmp = 0.05
    let maxAmp = 0.80
    let minVol: Float = 0.125   // ~1/8 volume
    let maxVol: Float = 1.0

    if amplitude <= minAmp { return minVol }
    if amplitude >= maxAmp { return maxVol }

    var t = (amplitude - minAmp) / (maxAmp - minAmp)
    t = log(1 + t * 99) / log(100)
    return minVol + Float(t) * (maxVol - minVol)
}

class AudioPlayer {
    private var activePlayers: [AVAudioPlayer] = []
    private let lock = NSLock()

    func play(filePath: String, amplitude: Double, volumeScaling: Bool, speedRatio: Double) {
        let url = URL(fileURLWithPath: filePath)
        debugLog("[audio] loading \(filePath)")

        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            fputs("spank: failed to load \(filePath)\n", stderr)
            return
        }

        if volumeScaling {
            let vol = amplitudeToVolume(amplitude)
            player.volume = vol
            debugLog("[audio] volume=\(vol) (amplitude=\(amplitude))")
        }

        if speedRatio != 1.0 && speedRatio > 0 {
            player.enableRate = true
            player.rate = Float(speedRatio)
        }

        player.prepareToPlay()

        lock.lock()
        activePlayers.append(player)
        lock.unlock()

        let ok = player.play()
        debugLog("[audio] play() returned \(ok), duration=\(player.duration)s")

        // Wait for playback to finish, then clean up
        let duration = player.duration / max(speedRatio, 0.1) + 0.5
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.lock.lock()
            self?.activePlayers.removeAll { $0 === player }
            self?.lock.unlock()
        }
    }
}

// MARK: - Stdin Command Handler

func startStdinReader(state: SpankState) {
    DispatchQueue.global(qos: .utility).async {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let data = trimmed.data(using: .utf8),
                  let cmd = try? JSONDecoder().decode(StdinCommand.self, from: data) else {
                if state.stdioMode {
                    print("{\"error\":\"invalid command\"}")
                    fflush(stdout)
                }
                continue
            }

            switch cmd.cmd {
            case "pause":
                state.paused = true
                if state.stdioMode {
                    print("{\"status\":\"paused\"}")
                    fflush(stdout)
                }
            case "resume":
                state.paused = false
                if state.stdioMode {
                    print("{\"status\":\"resumed\"}")
                    fflush(stdout)
                }
            case "set":
                if let amp = cmd.amplitude, amp > 0, amp <= 1 {
                    state.minAmplitude = amp
                }
                if let cd = cmd.cooldown, cd > 0 {
                    state.cooldownMs = cd
                }
                if let spd = cmd.speed, spd > 0 {
                    state.speedRatio = spd
                }
                if state.stdioMode {
                    print(String(format: "{\"status\":\"settings_updated\",\"amplitude\":%.4f,\"cooldown\":%d,\"speed\":%.2f}", state.minAmplitude, state.cooldownMs, state.speedRatio))
                    fflush(stdout)
                }
            case "volume-scaling":
                state.volumeScaling = !state.volumeScaling
                if state.stdioMode {
                    print("{\"status\":\"volume_scaling_toggled\",\"volume_scaling\":\(state.volumeScaling)}")
                    fflush(stdout)
                }
            case "status":
                if state.stdioMode {
                    print(String(format: "{\"status\":\"ok\",\"paused\":%@,\"amplitude\":%.4f,\"cooldown\":%d,\"volume_scaling\":%@,\"speed\":%.2f}", state.paused ? "true" : "false", state.minAmplitude, state.cooldownMs, state.volumeScaling ? "true" : "false", state.speedRatio))
                    fflush(stdout)
                }
            default:
                if state.stdioMode {
                    print("{\"error\":\"unknown command: \(cmd.cmd)\"}")
                    fflush(stdout)
                }
            }
        }
    }
}

// MARK: - CLI Argument Parsing

struct CLIArgs {
    var sexyMode = false
    var haloMode = false
    var customPath: String?
    var customFiles: [String] = []
    var fastMode = false
    var minAmplitude: Double?
    var cooldownMs: Int?
    var speedRatio: Double = defaultSpeedRatio
    var volumeScaling = false
    var stdioMode = false
    var debugMode = false
    var showHelp = false
    var showVersion = false

    var changedAmplitude = false
    var changedCooldown = false
}

func printUsage() {
    let usage = """
    spank - Yells 'ow!' when you slap the laptop

    Reads the Apple Silicon accelerometer directly via IOKit HID
    and plays audio responses when a slap or hit is detected.

    Requires sudo (for IOKit HID access to the accelerometer).

    Use --sexy for a different experience. In sexy mode, the more you slap
    within a minute, the more intense the sounds become.

    Use --halo to play random audio clips from Halo soundtracks on each slap.

    USAGE:
      sudo spank [FLAGS]

    FLAGS:
      -s, --sexy               Enable sexy mode
      -H, --halo               Enable halo mode
      -c, --custom <path>      Path to custom MP3 audio directory
      --custom-files <files>   Comma-separated list of custom MP3 files
      --fast                   Enable faster detection tuning
      --min-amplitude <val>    Minimum amplitude threshold 0.0-1.0 (default: 0.05)
      --cooldown <ms>          Cooldown between responses in ms (default: 750)
      --speed <ratio>          Playback speed multiplier (default: 1.0)
      --volume-scaling         Scale playback volume by slap amplitude
      --stdio                  Enable stdio mode for GUI integration
      --debug                  Enable verbose debug logging to stderr
      -h, --help               Show this help
      -v, --version            Show version
    """
    print(usage)
}

func parseArgs() -> CLIArgs {
    var args = CLIArgs()
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "--sexy", "-s":
            args.sexyMode = true
        case "--halo", "-H":
            args.haloMode = true
        case "--custom", "-c":
            i += 1
            guard i < argv.count else {
                fputs("spank: --custom requires a path argument\n", stderr)
                exit(1)
            }
            args.customPath = argv[i]
        case "--custom-files":
            i += 1
            guard i < argv.count else {
                fputs("spank: --custom-files requires a file list argument\n", stderr)
                exit(1)
            }
            args.customFiles = argv[i].components(separatedBy: ",")
        case "--fast":
            args.fastMode = true
        case "--min-amplitude":
            i += 1
            guard i < argv.count, let val = Double(argv[i]) else {
                fputs("spank: --min-amplitude requires a numeric argument\n", stderr)
                exit(1)
            }
            args.minAmplitude = val
            args.changedAmplitude = true
        case "--cooldown":
            i += 1
            guard i < argv.count, let val = Int(argv[i]) else {
                fputs("spank: --cooldown requires a numeric argument\n", stderr)
                exit(1)
            }
            args.cooldownMs = val
            args.changedCooldown = true
        case "--speed":
            i += 1
            guard i < argv.count, let val = Double(argv[i]) else {
                fputs("spank: --speed requires a numeric argument\n", stderr)
                exit(1)
            }
            args.speedRatio = val
        case "--volume-scaling":
            args.volumeScaling = true
        case "--stdio":
            args.stdioMode = true
        case "--debug":
            args.debugMode = true
        case "--help", "-h":
            args.showHelp = true
        case "--version", "-v":
            args.showVersion = true
        default:
            fputs("spank: unknown flag \(argv[i])\n", stderr)
            exit(1)
        }
        i += 1
    }
    return args
}

// MARK: - Audio Directory Resolution

func resolveAudioDir() -> String {
    // Try relative to the script/binary location
    let execPath = CommandLine.arguments[0]
    let execDir = (execPath as NSString).deletingLastPathComponent

    let candidates = [
        "\(execDir)/audio",
        "\(execDir)/../audio",
        "\(FileManager.default.currentDirectoryPath)/audio",
    ]

    for candidate in candidates {
        let resolved = (candidate as NSString).standardizingPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
            return resolved
        }
    }

    // Last resort
    return "\(FileManager.default.currentDirectoryPath)/audio"
}

// MARK: - FileManager helper

extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Main

func spankMain() {
    let cliArgs = parseArgs()
    debugMode = cliArgs.debugMode

    if cliArgs.showHelp {
        printUsage()
        exit(0)
    }
    if cliArgs.showVersion {
        print("spank \(version)")
        exit(0)
    }

    // Check root
    guard geteuid() == 0 else {
        fputs("spank requires root privileges for accelerometer access, run with: sudo spank\n", stderr)
        exit(1)
    }

    // Validate mutually exclusive modes
    var modeCount = 0
    if cliArgs.sexyMode { modeCount += 1 }
    if cliArgs.haloMode { modeCount += 1 }
    if cliArgs.customPath != nil || !cliArgs.customFiles.isEmpty { modeCount += 1 }
    if modeCount > 1 {
        fputs("--sexy, --halo, and --custom/--custom-files are mutually exclusive; pick one\n", stderr)
        exit(1)
    }

    // Build tuning
    var tuning = RuntimeTuning()
    if cliArgs.fastMode {
        applyFastOverlay(&tuning)
    }
    if cliArgs.changedAmplitude, let amp = cliArgs.minAmplitude {
        tuning.minAmplitude = amp
    }
    if cliArgs.changedCooldown, let cd = cliArgs.cooldownMs {
        tuning.cooldown = Double(cd) / 1000.0
    }

    // Validate
    if tuning.minAmplitude < 0 || tuning.minAmplitude > 1 {
        fputs("--min-amplitude must be between 0.0 and 1.0\n", stderr)
        exit(1)
    }
    if tuning.cooldown <= 0 {
        fputs("--cooldown must be greater than 0\n", stderr)
        exit(1)
    }

    // Load sound pack
    let audioDir = resolveAudioDir()
    var pack: SoundPack

    if !cliArgs.customFiles.isEmpty {
        // Validate custom files
        for f in cliArgs.customFiles {
            guard f.lowercased().hasSuffix(".mp3") else {
                fputs("custom file must be MP3: \(f)\n", stderr)
                exit(1)
            }
            guard FileManager.default.fileExists(atPath: f) else {
                fputs("custom file not found: \(f)\n", stderr)
                exit(1)
            }
        }
        pack = SoundPack(name: "custom", mode: .random, files: cliArgs.customFiles, isCustom: true, dir: "")
    } else if let customPath = cliArgs.customPath {
        pack = SoundPack(name: "custom", mode: .random, files: [], isCustom: true, dir: customPath)
    } else if cliArgs.sexyMode {
        pack = SoundPack(name: "sexy", mode: .escalation, files: [], isCustom: false, dir: "\(audioDir)/sexy")
    } else if cliArgs.haloMode {
        pack = SoundPack(name: "halo", mode: .random, files: [], isCustom: false, dir: "\(audioDir)/halo")
    } else {
        pack = SoundPack(name: "pain", mode: .random, files: [], isCustom: false, dir: "\(audioDir)/pain")
    }

    // Load files if not already set
    if pack.files.isEmpty {
        do {
            try pack.loadFiles()
        } catch {
            fputs("spank: loading \(pack.name) audio: \(error)\n", stderr)
            exit(1)
        }
    }

    // Create shared state
    let state = SpankState(
        minAmplitude: tuning.minAmplitude,
        cooldownMs: Int(tuning.cooldown * 1000),
        speedRatio: cliArgs.speedRatio,
        volumeScaling: cliArgs.volumeScaling,
        stdioMode: cliArgs.stdioMode
    )

    // Start accelerometer
    let accelBuffer = AccelRingBuffer()
    let reader = AccelReader(ringBuffer: accelBuffer)

    let sensorThread = Thread {
        do {
            try reader.start()
            reader.runLoop()
        } catch {
            fputs("spank: sensor failed: \(error)\n", stderr)
            exit(1)
        }
    }
    sensorThread.qualityOfService = QualityOfService.userInteractive
    sensorThread.start()

    // Wait for sensor to be ready
    var waitCount = 0
    while !reader.ready && waitCount < 50 {
        Thread.sleep(forTimeInterval: 0.01)
        waitCount += 1
    }
    guard reader.ready else {
        fputs("spank: sensor failed to start\n", stderr)
        exit(1)
    }

    // Give sensor time to produce data
    Thread.sleep(forTimeInterval: sensorStartupDelay)

    // Start stdin reader if needed
    if cliArgs.stdioMode {
        startStdinReader(state: state)
    }

    // Signal handling
    let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    sigSource.setEventHandler {
        print("\nbye!")
        exit(0)
    }
    sigSource.resume()

    let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signal(SIGTERM, SIG_IGN)
    sigTermSource.setEventHandler {
        print("\nbye!")
        exit(0)
    }
    sigTermSource.resume()

    // Main detection loop
    let tracker = SlapTracker(pack: pack, cooldown: tuning.cooldown)
    let detector = ImpactDetector()
    let audioPlayer = AudioPlayer()
    var lastTotal: UInt64 = 0
    var lastEventTime: Date?
    var lastYell = Date.distantPast

    let presetLabel = cliArgs.fastMode ? "fast" : "default"
    print("spank: listening for slaps in \(pack.name) mode with \(presetLabel) tuning... (ctrl+c to quit)")
    if cliArgs.stdioMode {
        print("{\"status\":\"ready\"}")
        fflush(stdout)
    }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: tuning.pollInterval)
    timer.setEventHandler {
        guard !state.paused else { return }

        let now = Date()
        let (samples, newTotal) = accelBuffer.readNew(after: lastTotal)
        lastTotal = newTotal

        let batch = samples.count > tuning.maxBatch
            ? Array(samples.suffix(tuning.maxBatch))
            : samples

        let tNow = CACurrentMediaTime()
        let nSamples = batch.count
        for (idx, sample) in batch.enumerated() {
            let tSample = tNow - Double(nSamples - idx - 1) / detector.fs
            detector.process(x: sample.x, y: sample.y, z: sample.z, timestamp: tSample)
        }

        guard let event = detector.events.last else { return }
        guard event.time != lastEventTime else { return }
        lastEventTime = event.time

        guard now.timeIntervalSince(lastYell) > state.cooldown else { return }
        guard event.amplitude >= state.minAmplitude else { return }

        lastYell = now
        let (num, score) = tracker.record(now: now)
        let file = tracker.getFile(score: score)

        if state.stdioMode {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let ts = isoFormatter.string(from: now)
            print("{\"timestamp\":\"\(ts)\",\"slapNumber\":\(num),\"amplitude\":\(event.amplitude),\"severity\":\"\(event.severity)\",\"file\":\"\(file)\"}")
            fflush(stdout)
        } else {
            print(String(format: "slap #%d [%@ amp=%.5fg] -> %@", num, event.severity, event.amplitude, file))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            audioPlayer.play(
                filePath: file,
                amplitude: event.amplitude,
                volumeScaling: state.volumeScaling,
                speedRatio: state.speedRatio
            )
        }
    }
    timer.resume()

    // Keep main run loop alive
    dispatchMain()
}

spankMain()
