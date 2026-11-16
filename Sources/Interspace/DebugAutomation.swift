import AppKit
import CDockSwipe
import QuartzCore
import os

/// Test hooks to measure the transitions with no hands on the trackpad or the keyboard. Off unless
/// `defaults write com.cnrad.interspace debugAutomation -bool true` was set before launch.
///
/// A command is the object of the distributed notification `com.cnrad.interspace.debug`:
/// - `key:1` or `key:-1`: a press of the shortcut for the space to the right or to the left.
/// - `post:1` or `post:-1`: a bare switch of the Dock, with no transition.
/// - `swipe:<dx>:<seconds>[:<hz>[:flick|drag[:<rest>]]]`: three fingers that rest for `rest` reports (2 when
///   not given), move `dx` trackpad widths (negative is to the left) in `seconds`, reported `hz` times a
///   second (90 when not given), then lift. A flick lifts while the fingers still move; a drag slows down
///   before the fingers lift.
///
/// The frames take the same way as the frames of the trackpad: from a thread of their own to the main thread.
enum DebugAutomation {
    private static let log = Logger(subsystem: "com.cnrad.interspace", category: "debug")
    private static let queue = DispatchQueue(label: "com.cnrad.interspace.debug", qos: .userInteractive)
    private static var keyStep: ((Int) -> Void)?
    private static var observer: NSObjectProtocol?

    static func installIfEnabled(keyStep: @escaping (Int) -> Void) {
        guard UserDefaults.standard.bool(forKey: "debugAutomation") else { return }
        self.keyStep = keyStep
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cnrad.interspace.debug"), object: nil, queue: .main
        ) { notification in
            guard let command = notification.object as? String else { return }
            run(command)
        }
        log.notice("debug automation is on")
    }

    private static func run(_ command: String) {
        let parts = command.split(separator: ":").map(String.init)
        switch parts.first {
        case "key":
            guard parts.count > 1, let step = Int(parts[1]) else { return }
            keyStep?(step)
        case "post":
            // A bare switch of the Dock, with no transition: to measure what the switch alone costs.
            guard parts.count > 1, let step = Int(parts[1]), step != 0 else { return }
            _ = ds_post_switch(step > 0 ? DSDirectionRight : DSDirectionLeft)
        case "swipe":
            guard parts.count >= 3, let dx = Double(parts[1]), let duration = Double(parts[2]), duration > 0 else { return }
            let hz = parts.count > 3 ? Double(parts[3]) ?? 90 : 90
            let flick = parts.count > 4 ? parts[4] != "drag" : true
            let rest = parts.count > 5 ? max(Int(parts[5]) ?? 2, 0) : 2
            swipe(dx: CGFloat(dx), duration: duration, hz: max(hz, 20), flick: flick, rest: rest)
        default:
            log.error("unknown debug command \(command, privacy: .public)")
        }
    }

    private static func swipe(dx: CGFloat, duration: Double, hz: Double, flick: Bool, rest: Int) {
        queue.async {
            let interval = 1 / hz
            let start = CACurrentMediaTime()
            var index = 0

            func send(_ points: [CGPoint]) {
                let frame = TouchFrame(device: 0xDEB06, timestamp: CACurrentMediaTime(), points: points)
                DispatchQueue.main.async { MultitouchMonitor.shared.onFrame?(frame) }
            }
            func fingers(_ offset: CGFloat) -> [CGPoint] {
                [0.38, 0.5, 0.62].map { CGPoint(x: $0 + offset, y: 0.45) }
            }
            func waitForNextFrame() {
                index += 1
                let next = start + Double(index) * interval
                let delay = next - CACurrentMediaTime()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            }

            // The fingers land, and rest for a few frames.
            send(fingers(0))
            for _ in 0..<rest {
                waitForNextFrame()
                send(fingers(0))
            }
            let moveStart = Double(index)
            while true {
                waitForNextFrame()
                let fraction = min((Double(index) - moveStart) * interval / duration, 1)
                // A flick keeps its speed to the lift. A drag eases out and stops before it.
                let eased = flick ? fraction : 1 - pow(1 - fraction, 3)
                send(fingers(dx * CGFloat(eased)))
                if fraction >= 1 { break }
            }
            waitForNextFrame()
            send([])
        }
    }
}
