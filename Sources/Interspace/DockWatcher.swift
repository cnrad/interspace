import Foundation
import QuartzCore
import os

/// Reads which space the Dock shows, on a thread of its own, while a transition needs to know it.
///
/// The read is a call to the window server. It usually takes 0.1 ms, but about one in a hundred takes 5 ms
/// or more, and 17 ms was measured on an idle Mac. On the main thread that is one or two frames the
/// transition does not draw, and the transition reads it at the worst time: while the Dock switches.
/// Measured: reading it every 8 ms from another thread costs the transition no frame, and does not make
/// the main thread's own calls to the window server wait.
final class DockWatcher {
    struct Reading {
        let state: SpaceState
        /// When the read started. A read that started before a switch was posted cannot show that switch.
        let started: CFTimeInterval
    }

    private struct Shared {
        /// Counts the starts and stops, so a read that was under way at a stop is not kept.
        var generation = 0
        var reading: Reading?
    }

    private let queue = DispatchQueue(label: "com.cnrad.interspace.dock", qos: .userInteractive)
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    /// Main thread only.
    private var timer: DispatchSourceTimer?
    private var displayID: CGDirectDisplayID = 0

    var isRunning: Bool { timer != nil }

    /// The newest reading of the watch in progress. Any thread.
    var latest: Reading? { shared.withLock { $0.reading } }

    /// Reads every 8 ms until `stop`. Call on the main thread.
    func start(displayID: CGDirectDisplayID) {
        if timer != nil, displayID == self.displayID { return }
        stop()
        self.displayID = displayID
        let generation = shared.withLock { $0.generation }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [shared] in
            let started = CACurrentMediaTime()
            guard let state = Spaces.state(displayID: displayID) else { return }
            shared.withLock {
                guard $0.generation == generation else { return }
                $0.reading = Reading(state: state, started: started)
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// Call on the main thread.
    func stop() {
        timer?.cancel()
        timer = nil
        shared.withLock {
            $0.generation += 1
            $0.reading = nil
        }
    }
}
