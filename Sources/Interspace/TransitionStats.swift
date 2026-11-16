import QuartzCore

/// What happened in one showing of the overlay, for one line in the log. A swipe that catches the overlay
/// adds to the same line. Times are on the clock of `CACurrentMediaTime`.
struct TransitionStats {
    var start: CFTimeInterval = 0
    /// When the overlay came on screen, and how far the fingers had gone by then, in spaces.
    var presented: CFTimeInterval = 0
    var presentedProgress: CGFloat = 0
    var released: CFTimeInterval = 0
    var revealed: CFTimeInterval = 0
    var revealIsCut = false
    var catches = 0
    /// The first switch posted to the Dock, and the first time the Dock was seen on the space of a switch.
    var firstPost: CFTimeInterval = 0
    var dockLanded: CFTimeInterval = 0
    /// Every switch posted to the Dock, and every time the Dock was seen on the space of a switch.
    private var dockEvents: [(name: String, time: CFTimeInterval)] = []

    /// Frames of the display link, frames that came more than half a frame late, and the longest gap.
    private(set) var ticks = 0
    private(set) var lateTicks = 0
    private(set) var longestGap: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    /// The longest time one frame of work took on the main thread, and in which phase.
    private(set) var longestWork: CFTimeInterval = 0
    private var longestWorkPhase = ""
    /// When each phase began, on the clock of `CACurrentMediaTime`: to line the log up with a recording of
    /// the screen, which uses the same clock.
    private var phases: [(name: String, time: CFTimeInterval)] = []
    /// Reports of the trackpad during drags, to know its rate.
    private var touches = 0
    private var touchTime: CFTimeInterval = 0
    private var lastTouch: CFTimeInterval = 0

    init(start: CFTimeInterval = 0) {
        self.start = start
    }

    mutating func tick(at timestamp: CFTimeInterval, frame: CFTimeInterval) {
        if lastTick > 0 {
            let gap = timestamp - lastTick
            longestGap = max(longestGap, gap)
            if gap > frame * 1.5 { lateTicks += 1 }
        }
        lastTick = timestamp
        ticks += 1
    }

    mutating func work(_ seconds: CFTimeInterval, phase: String) {
        guard seconds > longestWork else { return }
        longestWork = seconds
        longestWorkPhase = phase
    }

    mutating func enter(_ phase: String, at time: CFTimeInterval) {
        guard phases.count < 40 else { return }
        phases.append((phase, time))
    }

    mutating func dock(_ event: String, at time: CFTimeInterval) {
        guard dockEvents.count < 20 else { return }
        dockEvents.append((event, time))
    }

    mutating func touch(at time: CFTimeInterval) {
        // A pause of more than 50 ms is the gap between two drags, not the rate of the trackpad.
        if lastTouch > 0, time - lastTouch < 0.05 {
            touches += 1
            touchTime += time - lastTouch
        }
        lastTouch = time
    }

    mutating func endTouches() {
        lastTouch = 0
    }

    func summary(end: CFTimeInterval) -> String {
        func ms(_ time: CFTimeInterval, from origin: CFTimeInterval) -> String {
            time > 0 && origin > 0 ? "\(Int(((time - origin) * 1000).rounded()))" : "-"
        }
        var text = "shown at \(ms(presented, from: start)) ms (fingers at \(String(format: "%.3f", presentedProgress))), "
            + "released at \(ms(released, from: start)) ms, revealed at \(ms(revealed, from: start)) ms (\(revealIsCut ? "cut" : "fade")), "
            + "ended at \(ms(end, from: start)) ms, catches \(catches), frames \(ticks), late frames \(lateTicks), "
            + "longest gap \(Int((longestGap * 1000).rounded())) ms, "
            + "longest frame work \(String(format: "%.1f", longestWork * 1000)) ms (\(longestWorkPhase))"
        if firstPost > 0 {
            text += ", Dock landed \(ms(dockLanded, from: firstPost)) ms after the first switch"
        }
        if touches > 0 {
            text += ", trackpad every \(String(format: "%.1f", touchTime / Double(touches) * 1000)) ms"
        }
        if !phases.isEmpty {
            text += ", phases " + phases.map { "\($0.name)@\(String(format: "%.4f", $0.time))" }.joined(separator: " ")
                + " end@\(String(format: "%.4f", end))"
        }
        if !dockEvents.isEmpty {
            text += ", Dock " + dockEvents.map { "\($0.name)#\(String(format: "%.4f", $0.time))" }.joined(separator: " ")
        }
        return text
    }
}
