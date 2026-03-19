import Foundation

/// Thread-safe ring buffer for accelerometer samples.
/// Uses NSLock for synchronization between the IOKit HID callback thread and consumer threads.
public class AccelRingBuffer {
    private let capacity = 2048
    private var buffer: [AccelSample]
    private var writeIdx: Int = 0
    private var totalCount: UInt64 = 0
    private let lock = NSLock()

    public init() {
        buffer = [AccelSample](repeating: AccelSample(x: 0, y: 0, z: 0), count: capacity)
    }

    public func write(_ sample: AccelSample) {
        lock.lock()
        buffer[writeIdx % capacity] = sample
        writeIdx += 1
        totalCount += 1
        lock.unlock()
    }

    public func readNew(after: UInt64) -> ([AccelSample], UInt64) {
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
