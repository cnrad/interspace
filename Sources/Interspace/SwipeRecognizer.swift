import Foundation
import CoreGraphics

/// Turns raw touch frames into a horizontal drag with the finger count of a swipe between spaces.
/// All distances are fractions of the trackpad width; positive is to the right.
final class SwipeRecognizer {
    /// The fingers of a swipe are down, direction not known yet.
    var onArm: (() -> Void)?
    /// The touch ended, or became something else, before a horizontal drag started.
    var onDisarm: (() -> Void)?
    var onBegin: (() -> Void)?
    var onChange: ((_ dx: CGFloat) -> Void)?
    /// `velocity` is trackpad widths per second. `cancelled` means the drag must snap back.
    var onEnd: ((_ velocity: CGFloat, _ cancelled: Bool) -> Void)?

    private enum State {
        case idle
        case pending
        case active
        /// Wait for the fingers to lift.
        case ignored
    }

    /// The finger counts of a swipe between spaces, as chosen in the menu. It is read when a touch
    /// starts, so it does not change in the middle of one.
    private var fingerRange = AppSettings.shared.swipeFingers.range

    private var state = State.idle
    private var device: UInt = 0
    private var fingerCount = 0
    private var start = CGPoint.zero
    private var origin: CGFloat = 0
    private var lastDX: CGFloat = 0
    private var history: [(time: Double, dx: CGFloat)] = []

    func handle(_ frame: TouchFrame) {
        if state != .idle, frame.device != device { return }

        let count = frame.points.count
        let centroid = Self.centroid(of: frame.points)

        switch state {
        case .idle:
            fingerRange = AppSettings.shared.swipeFingers.range
            guard count >= fingerRange.lowerBound else { return }
            device = frame.device
            guard count <= fingerRange.upperBound else {
                state = .ignored
                return
            }
            state = .pending
            fingerCount = count
            start = centroid
            onArm?()

        case .pending:
            if count < fingerRange.lowerBound {
                state = .idle
                onDisarm?()
                return
            }
            if count > fingerRange.upperBound {
                state = .ignored
                onDisarm?()
                return
            }
            if count != fingerCount {
                fingerCount = count
                start = centroid
                return
            }
            let dx = centroid.x - start.x
            let dy = centroid.y - start.y
            if abs(dx) >= Config.directionSlop, abs(dx) > abs(dy) * 1.2 {
                state = .active
                // Measure from here so the first frame does not jump by the slop distance.
                origin = centroid.x
                lastDX = 0
                history = [(frame.timestamp, 0)]
                onBegin?()
            } else if abs(dy) >= Config.directionSlop {
                state = .ignored
                onDisarm?()
            }

        case .active:
            if count < fingerRange.lowerBound {
                // The lift frame is not used for position: the centroid jumps when a finger leaves.
                let velocity = releaseVelocity(at: frame.timestamp)
                state = .idle
                onEnd?(velocity, false)
                return
            }
            if count > fingerRange.upperBound {
                state = .ignored
                onEnd?(0, true)
                return
            }
            if count != fingerCount {
                fingerCount = count
                origin = centroid.x - lastDX
            }
            let dx = centroid.x - origin
            lastDX = dx
            history.append((frame.timestamp, dx))
            while let first = history.first, frame.timestamp - first.time > 0.1, history.count > 2 {
                history.removeFirst()
            }
            onChange?(dx)

        case .ignored:
            if count < fingerRange.lowerBound {
                state = .idle
            }
        }
    }

    /// Ends an active drag from outside, for example when frames stop arriving.
    func reset() {
        state = .idle
        history.removeAll()
    }

    private func releaseVelocity(at time: Double) -> CGFloat {
        guard let first = history.first, let last = history.last else { return 0 }
        let span = last.time - first.time
        // Fingers that stopped before the lift have no velocity.
        guard span > 0.012, time - last.time < 0.08 else { return 0 }
        return (last.dx - first.dx) / CGFloat(span)
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for point in points {
            x += point.x
            y += point.y
        }
        return CGPoint(x: x / CGFloat(points.count), y: y / CGFloat(points.count))
    }
}
