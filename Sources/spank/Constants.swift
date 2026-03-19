import Foundation

// MARK: - Version

let version = "0.1.0"

// MARK: - Constants

let decayHalfLife: Double = 30.0
let defaultMinAmplitude: Double = 0.05
let defaultCooldownMs: Int = 750
let defaultSpeedRatio: Double = 1.0
let defaultSensorPollInterval: TimeInterval = 0.01   // 10ms
let defaultMaxSampleBatch: Int = 200
let sensorStartupDelay: TimeInterval = 0.1            // 100ms

// IMU decimation factor (used by ImpactDetector, not the library)
let kIMUDecimation: Int = 8

// MARK: - Debug Logging

var debugMode = false

func debugLog(_ msg: @autoclosure () -> String) {
    guard debugMode else { return }
    fputs("spank: \(msg())\n", stderr)
}
