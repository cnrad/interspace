import Foundation

/// The swipe between spaces that macOS uses: System Settings > Trackpad > More Gestures >
/// Swipe between full-screen applications.
///
/// Interspace reads the raw fingers itself, so it takes that swipe and no other. With three finger drag on,
/// macOS swipes between spaces with four fingers, and a three finger drag of a window must stay a drag.
/// Use from the main thread.
enum SwipeFingers {
    /// The finger counts of a swipe. `nil` when the swipe is off in System Settings.
    private(set) static var range: ClosedRange<Int>? = read()

    /// For the log.
    static var description: String {
        range.map { "\($0.lowerBound)" } ?? "off"
    }

    /// Reads the trackpad settings again. They change in System Settings: see `AppDelegate.updatePolling`.
    static func refresh() {
        for domain in domains {
            CFPreferencesAppSynchronize(domain as CFString)
        }
        range = read()
    }

    /// The built-in trackpad, then the Magic Trackpad. System Settings writes both.
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]
    /// The value of a `Trackpad…HorizSwipeGesture` key for "Swipe between full-screen applications".
    private static let fullScreenSwipe = 2

    private static func read() -> ClosedRange<Int>? {
        let three = value("TrackpadThreeFingerHorizSwipeGesture")
        let four = value("TrackpadFourFingerHorizSwipeGesture")
        if three == fullScreenSwipe {
            // A fourth finger that touches down by accident does not stop the swipe.
            return 3...4
        }
        if four == fullScreenSwipe {
            return 4...4
        }
        if three == nil, four == nil {
            // Settings that were never written: the swipe of macOS is on, with four fingers when three are a drag.
            return value("TrackpadThreeFingerDrag") == 1 ? 4...4 : 3...4
        }
        // Off, or three fingers swipe between pages.
        return nil
    }

    private static func value(_ key: String) -> Int? {
        for domain in domains {
            if let number = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber {
                return number.intValue
            }
        }
        return nil
    }
}
