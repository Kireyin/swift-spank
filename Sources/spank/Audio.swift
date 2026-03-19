import Foundation
import AVFoundation

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
