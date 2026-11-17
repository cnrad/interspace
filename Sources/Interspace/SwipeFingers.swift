import Foundation

/// The number of fingers of a swipe between spaces. The user chooses it in the menu.
///
/// Interspace reads the raw fingers itself, so it must use the same number as macOS: the number in
/// System Settings > Trackpad > "Swipe between full-screen applications". With three finger drag on,
/// macOS switches spaces with four fingers, and a three finger drag of a window must not switch the space.
enum SwipeFingers: Int, CaseIterable {
    case three = 3
    case four = 4

    var title: String {
        switch self {
        case .three: return "Three Fingers"
        case .four: return "Four Fingers"
        }
    }

    /// The finger counts that make a swipe.
    var range: ClosedRange<Int> {
        switch self {
        // A fourth finger that touches down by accident does not stop a three finger swipe.
        case .three: return 3...4
        case .four: return 4...4
        }
    }

    /// The number macOS uses, from the trackpad settings. The choice until the user makes one.
    static var system: SwipeFingers {
        if value("TrackpadThreeFingerHorizSwipeGesture") == fullScreenSwipe {
            return .three
        }
        if value("TrackpadFourFingerHorizSwipeGesture") == fullScreenSwipe || value("TrackpadThreeFingerDrag") == 1 {
            return .four
        }
        return .three
    }

    /// The built-in trackpad, then the Magic Trackpad. System Settings writes both.
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]
    /// The value of a `Trackpad…HorizSwipeGesture` key for "Swipe between full-screen applications".
    private static let fullScreenSwipe = 2

    private static func value(_ key: String) -> Int? {
        for domain in domains {
            if let number = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber {
                return number.intValue
            }
        }
        return nil
    }
}
