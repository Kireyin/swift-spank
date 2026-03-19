import Foundation
import IOKit
import IOKit.hid

// MARK: - Public API

/// Optional logging closure. Library consumers provide their own logging.
public typealias LogHandler = (String) -> Void

/// Errors thrown by the accelerometer reader.
public enum AccelerometerError: Error, CustomStringConvertible {
    case sensorNotFound
    case sensorOpenFailed(Int32)

    public var description: String {
        switch self {
        case .sensorNotFound:
            return "accelerometer not found (Apple Silicon required)"
        case .sensorOpenFailed(let code):
            return "failed to open accelerometer (IOKit error \(code))"
        }
    }
}

// MARK: - IOKit HID Constants (file-private)

private let kPageVendor: Int = 0xFF00
private let kUsageAccel: Int = 3
private let kIMUReportLen: Int = 22
private let kIMUDataOffset: Int = 6
private let kIMUScale: Double = 65536.0

// MARK: - AccelReader

/// Reads raw accelerometer data from the Apple Silicon Bosch BMI286 IMU via IOKit HID.
/// Writes parsed samples into an `AccelRingBuffer`.
public class AccelReader {
    public let ringBuffer: AccelRingBuffer
    private let reportIntervalUS: Int
    internal let logHandler: LogHandler?

    // Keep strong references to prevent deallocation during CFRunLoop
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var hidDevices: [IOHIDDevice] = []  // prevent ARC from releasing
    public var ready = false
    public var sampleCount: Int = 0

    public init(ringBuffer: AccelRingBuffer, reportIntervalUS: Int = 1000, logHandler: LogHandler? = nil) {
        self.ringBuffer = ringBuffer
        self.reportIntervalUS = reportIntervalUS
        self.logHandler = logHandler
    }

    public func start() throws {
        // Step 1: Wake up SPU drivers (critical — without this, sensors stay dormant)
        try wakeSPUDrivers()

        // Step 2: Find and register HID devices
        try registerHIDDevices()

        ready = true
    }

    /// Wake up AppleSPUHIDDriver services by setting sensor properties.
    private func wakeSPUDrivers() throws {
        guard let matchDict = IOServiceMatching("AppleSPUHIDDriver") else {
            throw AccelerometerError.sensorNotFound
        }

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
        guard kr == KERN_SUCCESS else {
            throw AccelerometerError.sensorOpenFailed(kr)
        }
        defer { IOObjectRelease(iterator) }

        var driverCount = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let props: [(String, Int32)] = [
                ("SensorPropertyReportingState", 1),
                ("SensorPropertyPowerState", 1),
                ("ReportInterval", Int32(reportIntervalUS)),
            ]
            for (key, val) in props {
                var value = val
                if let cfNum = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value) {
                    IORegistryEntrySetCFProperty(service, key as CFString, cfNum)
                }
            }
            driverCount += 1
            logHandler?("[sensor] woke SPU driver #\(driverCount)")
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        if driverCount == 0 {
            logHandler?("[sensor] warning: no AppleSPUHIDDriver services found")
        }
    }

    /// Find AppleSPUHIDDevice services and register the accelerometer callback.
    private func registerHIDDevices() throws {
        guard let matchDict = IOServiceMatching("AppleSPUHIDDevice") else {
            throw AccelerometerError.sensorNotFound
        }

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
        guard kr == KERN_SUCCESS else {
            throw AccelerometerError.sensorOpenFailed(kr)
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

            guard let upRef = IORegistryEntryCreateCFProperty(service, "PrimaryUsagePage" as CFString, kCFAllocatorDefault, 0),
                  let uRef = IORegistryEntryCreateCFProperty(service, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0) else {
                continue
            }
            let usagePage = (upRef.takeRetainedValue() as! NSNumber).intValue
            let usage = (uRef.takeRetainedValue() as! NSNumber).intValue
            logHandler?("[sensor] SPU device: usagePage=0x\(String(usagePage, radix: 16)) usage=\(usage)")

            guard usagePage == kPageVendor && usage == kUsageAccel else { continue }

            guard let hidDevice = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                logHandler?("[sensor] failed to create HID device")
                continue
            }

            let openResult = IOHIDDeviceOpen(hidDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                logHandler?("[sensor] failed to open HID device: \(openResult)")
                continue
            }

            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            buf.initialize(repeating: 0, count: bufSize)
            reportBuffers.append(buf)

            hidDevices.append(hidDevice)

            IOHIDDeviceRegisterInputReportCallback(
                hidDevice, buf, bufSize,
                accelReportCallback, selfPtr
            )
            IOHIDDeviceScheduleWithRunLoop(
                hidDevice, CFRunLoopGetCurrent(),
                CFRunLoopMode.defaultMode.rawValue
            )

            logHandler?("[sensor] accelerometer registered")
            foundAccel = true
        }

        guard foundAccel else {
            logHandler?("[sensor] no accelerometer device found")
            throw AccelerometerError.sensorNotFound
        }
    }

    public func runLoop() {
        CFRunLoopRun()
    }
}

// MARK: - IOKit HID Callback

/// C-compatible callback for IOKit HID accelerometer reports.
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

    guard reportLength == kIMUReportLen else { return }

    if let log = reader.logHandler, reader.sampleCount < 3 {
        let bytes = (0..<min(Int(reportLength), 22)).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
        log("[sensor] report: len=\(reportLength) id=\(reportID) bytes: \(bytes)")
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
    if let log = reader.logHandler, reader.sampleCount % 1000 == 0 {
        log("[sensor] \(reader.sampleCount) samples (x=\(String(format:"%.2f",x)) y=\(String(format:"%.2f",y)) z=\(String(format:"%.2f",z)))")
    }
}

