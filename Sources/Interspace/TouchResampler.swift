import QuartzCore

/// The last few finger positions of a drag, to give the position at the time of a display frame.
///
/// The trackpad reports on its own clock, about 90 to 120 times a second, and the display shows a frame
/// 120 times a second on its clock. A picture that moves when a report arrives moves unevenly: some frames
/// get two reports, some none. So each frame takes the position at a fixed short time before it, on a
/// straight line between the two reports around that time. Ahead of the newest report it goes on in the
/// same direction for a few milliseconds at most, as the touch input of iOS and Android does.
struct TouchResampler {
    private var times: [CFTimeInterval] = []
    private var values: [CGFloat] = []
    private static let kept = 6
    /// The longest time to go on past the newest report.
    private static let maxPrediction: CFTimeInterval = 0.008

    /// The newest position, as the fingers left it.
    var latest: CGFloat { values.last ?? 0 }

    mutating func reset(at time: CFTimeInterval, value: CGFloat) {
        times = [time]
        values = [value]
    }

    /// `time` is when the report arrived, on the clock of `CACurrentMediaTime`.
    mutating func add(at time: CFTimeInterval, value: CGFloat) {
        if let last = times.last, time <= last {
            // Two reports with the same time: the newer position counts.
            values[values.count - 1] = value
            return
        }
        times.append(time)
        values.append(value)
        if times.count > Self.kept {
            times.removeFirst()
            values.removeFirst()
        }
    }

    func value(at time: CFTimeInterval) -> CGFloat {
        guard let lastTime = times.last, let lastValue = values.last else { return 0 }
        let count = times.count
        if time >= lastTime {
            guard count >= 2 else { return lastValue }
            let interval = lastTime - times[count - 2]
            // A report that came alone after a pause says nothing about the speed.
            guard interval > 0.002, interval < 0.03 else { return lastValue }
            let ahead = min(time - lastTime, Self.maxPrediction, interval / 2)
            return lastValue + (lastValue - values[count - 2]) * CGFloat(ahead / interval)
        }
        for index in stride(from: count - 1, to: 0, by: -1) where time >= times[index - 1] {
            let fraction = (time - times[index - 1]) / (times[index] - times[index - 1])
            return values[index - 1] + (values[index] - values[index - 1]) * CGFloat(fraction)
        }
        return values[0]
    }
}
