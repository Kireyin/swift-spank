import Foundation
import AVFoundation
import Darwin
import AppleSiliconAccelerometer

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
    let accelBuffer = AccelerometerRingBuffer()
    let reader = AccelerometerReader(ringBuffer: accelBuffer, logHandler: { msg in
        debugLog(msg)
    })

    let sensorThread = Thread {
        do {
            try reader.start()
            reader.runLoop()
        } catch let error as AccelerometerError {
            fputs("spank: sensor failed: \(error)\n", stderr)
            exit(1)
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
