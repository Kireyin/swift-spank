# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

swift-spank is a macOS utility that detects physical slaps on Apple Silicon MacBooks via the accelerometer (Bosch BMI286 IMU accessed through IOKit HID) and plays audio responses. It's a single-file Swift application with no external dependencies.

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

> **Direct compilation** (no SPM): `swiftc -O -o spank Sources/spank/spank.swift -framework IOKit -framework AVFoundation`

There are no tests, no Makefile, and no CI pipeline.

## Architecture

The entire application lives in `Sources/spank/spank.swift` (~1100 lines), organized into these logical sections:

- **AccelReader / AccelRingBuffer** — IOKit HID device registration, raw 22-byte IMU report parsing, thread-safe ring buffer (NSLock) for accelerometer samples
- **ImpactDetector** — High-pass filter (α=0.95) to remove gravity, multi-timescale STA/LTA (short-term/long-term average) detection across 3 tiers, amplitude estimation, severity classification, 300ms refractory period
- **AudioPlayer / SoundPack** — AVAudioPlayer wrapper with volume scaling (amplitude-based) and playback rate control; manages audio file collections from `audio/` subdirectories (pain, sexy, halo, custom)
- **SlapTracker** — Rolling window slap frequency tracking with exponential decay (30s half-life), drives escalation logic for sexy mode (60 levels)
- **CLIArgs** — Command-line argument parser
- **SpankState** — Thread-safe state container (DispatchQueue-protected)
- **Main loop** — DispatchSourceTimer for detection polling, CFRunLoop for IOKit HID event delivery, SIGINT/SIGTERM signal handling

## Key Conventions

- Thread safety uses NSLock (ring buffer) and DispatchQueue (state mutations)
- IOKit HID callbacks use C-compatible function pointers with Unmanaged/toOpaque for bridging Swift objects
- Audio files are stored via Git LFS (see `.gitattributes`)
- The binary targets Apple Silicon (arm64) specifically — sensor constants are tuned for M-series IMU hardware
