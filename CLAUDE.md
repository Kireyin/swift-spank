# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

swift-spank is a macOS utility that detects physical slaps on Apple Silicon MacBooks via the accelerometer (Bosch BMI286 IMU accessed through IOKit HID) and plays audio responses. It's a Swift application with no external dependencies.

## Build & Run

```bash
# Build (debug)
swift build

# Build (release)
swift build -c release

# Run (requires sudo for IOKit HID accelerometer access)
sudo swift run spank

# Run with options
sudo swift run spank --sexy          # Escalation mode
sudo swift run spank --halo          # Halo death sounds
sudo swift run spank --fast          # Faster polling (4ms), higher sensitivity
sudo swift run spank --debug         # Verbose stderr logging
sudo swift run spank --stdio         # JSON-based stdio control for GUI integration

# Or run the release binary directly
sudo .build/release/spank
```

> **Direct compilation** (no SPM): `swiftc -O -o spank Sources/spank/*.swift -framework IOKit -framework AVFoundation`

There are no tests, no Makefile, and no CI pipeline.

## Architecture

The application lives in `Sources/spank/`, split across 7 files in a single SPM target (all types use `internal` access):

- **`Constants.swift`** — Version, detection constants, IOKit HID constants, `debugMode` flag and `debugLog()` helper
- **`Types.swift`** — Value types (`PlayMode`, `RuntimeTuning`, `SoundPack`, `AccelSample`, `ImpactEvent`, `StdinCommand`, `SpankError`), `FileManager.isDirectory` extension
- **`Accelerometer.swift`** — `SpankState` (DispatchQueue-protected thread-safe state), `AccelRingBuffer` (NSLock ring buffer), `AccelReader` (IOKit HID device registration, raw 22-byte IMU report parsing)
- **`ImpactDetector.swift`** — High-pass filter (α=0.95) to remove gravity, multi-timescale STA/LTA detection across 3 tiers, amplitude estimation, severity classification, 300ms refractory period
- **`Audio.swift`** — `SlapTracker` (exponential decay scoring, escalation logic), `amplitudeToVolume()`, `AudioPlayer` (AVAudioPlayer wrapper with volume/rate control)
- **`CLI.swift`** — `CLIArgs` struct, `parseArgs()`, `printUsage()`, `startStdinReader()` (JSON stdin commands), `resolveAudioDir()`
- **`main.swift`** — Entry point: `spankMain()` orchestration (sensor startup, signal handling, DispatchSourceTimer detection loop, CFRunLoop for IOKit HID)

## Key Conventions

- Thread safety uses NSLock (ring buffer) and DispatchQueue (state mutations)
- IOKit HID callbacks use C-compatible function pointers with Unmanaged/toOpaque for bridging Swift objects
- Audio files are stored via Git LFS (see `.gitattributes`)
- The binary targets Apple Silicon (arm64) specifically — sensor constants are tuned for M-series IMU hardware
