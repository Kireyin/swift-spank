import Foundation

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
