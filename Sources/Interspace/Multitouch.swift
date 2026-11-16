import Foundation
import CoreGraphics
import QuartzCore

/// One trackpad report. `points` are the fingers in contact, normalized 0...1 (x: left to right, y: bottom to top).
struct TouchFrame {
    let device: UInt
    let timestamp: Double
    let points: [CGPoint]
    /// When the report reached the app, on the clock of `CACurrentMediaTime`. Taken on the thread of the
    /// callback, so time the report waits for the main thread does not count.
    var arrival: CFTimeInterval = CACurrentMediaTime()
}

/// Raw trackpad contacts through the private MultitouchSupport framework.
final class MultitouchMonitor {
    static let shared = MultitouchMonitor()

    /// Called on the main thread. Only frames with 3+ fingers, plus the first frame after, are delivered.
    var onFrame: ((TouchFrame) -> Void)?

    private typealias DeviceRef = UnsafeMutableRawPointer
    fileprivate typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (DeviceRef, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (DeviceRef, Int32) -> Int32
    private typealias StopFn = @convention(c) (DeviceRef) -> Int32

    private var createList: CreateListFn?
    private var register: RegisterFn?
    private var unregister: RegisterFn?
    private var startDevice: StartFn?
    private var stopDevice: StopFn?

    private var deviceList: CFArray?
    private var devices: [DeviceRef] = []

    // Touched from the multitouch threads only, under `lock`.
    fileprivate var lock = os_unfair_lock()
    fileprivate var lastCount: [UInt: Int] = [:]

    private(set) var deviceCount = 0

    private init() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        createList = symbol("MTDeviceCreateList", CreateListFn.self)
        register = symbol("MTRegisterContactFrameCallback", RegisterFn.self)
        unregister = symbol("MTUnregisterContactFrameCallback", RegisterFn.self)
        startDevice = symbol("MTDeviceStart", StartFn.self)
        stopDevice = symbol("MTDeviceStop", StopFn.self)
    }

    var isAvailable: Bool {
        createList != nil && register != nil && startDevice != nil
    }

    /// Starts (or restarts) listening on every multitouch device. Returns false when no device is found.
    @discardableResult
    func start() -> Bool {
        stop()
        guard let createList, let register, let startDevice, let list = createList()?.takeRetainedValue() else {
            return false
        }
        deviceList = list
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, contactCallback)
            _ = startDevice(device, 0)
            devices.append(device)
        }
        deviceCount = devices.count
        return !devices.isEmpty
    }

    func stop() {
        for device in devices {
            unregister?(device, contactCallback)
            _ = stopDevice?(device)
        }
        devices.removeAll()
        deviceList = nil
        deviceCount = 0
        os_unfair_lock_lock(&lock)
        lastCount.removeAll()
        os_unfair_lock_unlock(&lock)
    }
}

// Layout of one contact in the frame callback (MTTouch, 96 bytes):
//   20: int32 state (3 = making contact, 4 = touching)
//   32: float normalized x, 36: float normalized y
private let touchStride = 96
private let stateOffset = 20
private let xOffset = 32
private let yOffset = 36

private let contactCallback: MultitouchMonitor.ContactCallback = { device, touches, count, timestamp, _ in
    let arrival = CACurrentMediaTime()
    let monitor = MultitouchMonitor.shared
    let deviceID = UInt(bitPattern: device)

    var points: [CGPoint] = []
    if let touches, count > 0 {
        points.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let touch = touches + index * touchStride
            let state = touch.load(fromByteOffset: stateOffset, as: Int32.self)
            guard state == 3 || state == 4 else { continue }
            let x = touch.load(fromByteOffset: xOffset, as: Float.self)
            let y = touch.load(fromByteOffset: yOffset, as: Float.self)
            points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
        }
    }

    // Normal one and two finger use never reaches the main thread.
    os_unfair_lock_lock(&monitor.lock)
    let previous = monitor.lastCount[deviceID] ?? 0
    monitor.lastCount[deviceID] = points.count
    os_unfair_lock_unlock(&monitor.lock)
    guard points.count >= 3 || previous >= 3 else { return 0 }

    let frame = TouchFrame(device: deviceID, timestamp: timestamp, points: points, arrival: arrival)
    DispatchQueue.main.async {
        monitor.onFrame?(frame)
    }
    return 0
}
