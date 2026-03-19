import Foundation
import AppleSiliconAccelerometer

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
