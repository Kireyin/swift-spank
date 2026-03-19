import Foundation

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

// MARK: - FileManager helper

extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
