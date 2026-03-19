import Foundation
import IOKit
import IOKit.hid

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
