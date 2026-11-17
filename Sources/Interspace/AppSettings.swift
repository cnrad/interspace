import Combine
import Foundation

/// The transitions the user can choose.
enum TransitionStyle: String, CaseIterable, Identifiable {
    /// The transition of macOS. The app does nothing.
    case system = "default"
    /// No animation. The app only switches the space, at once.
    case instant
    case lightweight
    /// Each screen is full size only in the middle. It shrinks as it leaves and grows as it arrives.
    case magnetic
    case hexagon
    /// The spaces are a pile of cards. One slides onto the pile, or off it.
    case stack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "macOS Default"
        case .lightweight: return "Lightweight"
        case .magnetic: return "Magnetic"
        case .hexagon: return "Prism"
        case .stack: return "Stack"
        case .instant: return "Instant"
        }
    }

    var detail: String {
        switch self {
        case .system: return "The standard macOS transition."
        case .lightweight: return "Faster. The screens pull back slightly."
        case .magnetic: return "The screen shrinks and moves aside. The next one moves in and grows."
        case .hexagon: return "The spaces are the sides of a prism that turns."
        case .stack: return "A pile of screens. One slides on top, or off again."
        case .instant: return "No animation. The next space is there at once."
        }
    }

    /// False when macOS does the transition and the app has no effect on it.
    var isCustom: Bool { self != .system }

    /// True when the app draws the transition itself, from images of the spaces.
    var isDrawn: Bool { self == .lightweight || self == .magnetic || self == .hexagon || self == .stack }
}

/// What the user chose, saved between launches. Use from the main thread.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// 1 is the normal speed of a transition. 2 is twice as fast.
    static let speedRange: ClosedRange<Double> = 0.5...2
    /// 1 is the normal travel: a full trackpad width is 90% of the way to the next space.
    /// At 4, the same finger travel goes more than three spaces.
    static let sensitivityRange: ClosedRange<Double> = 0.5...4

    private static let transitionKey = "transition"
    private static let speedKey = "speed"
    private static let sensitivityKey = "sensitivity"
    private static let dockMovesWithSpaceKey = "dockMovesWithSpace"
    private static let roundedCornersKey = "roundedCorners"
    private static let showsMenuBarIconKey = "showsMenuBarIcon"
    private let defaults = UserDefaults.standard

    @Published var transition: TransitionStyle {
        didSet {
            defaults.set(transition.rawValue, forKey: Self.transitionKey)
            if transition.isCustom {
                lastCustomTransition = transition
            }
        }
    }

    @Published var speed: Double {
        didSet { defaults.set(speed, forKey: Self.speedKey) }
    }

    /// How far the screens move for a given finger travel on the trackpad.
    @Published var sensitivity: Double {
        didSet { defaults.set(sensitivity, forKey: Self.sensitivityKey) }
    }

    /// True: the Dock and the menu bar are part of each space and move with it.
    /// False: they stay in place and the spaces move below them, as in the macOS transition.
    @Published var dockMovesWithSpace: Bool {
        didSet { defaults.set(dockMovesWithSpace, forKey: Self.dockMovesWithSpaceKey) }
    }

    /// True: each space has the corner shape of the display during a transition. False: its corners are square.
    @Published var roundedCorners: Bool {
        didSet { defaults.set(roundedCorners, forKey: Self.roundedCornersKey) }
    }

    /// False: the app has no icon in the menu bar. The settings window stays within reach: it opens when
    /// the user opens the app again while it runs.
    @Published var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: Self.showsMenuBarIconKey) }
    }

    /// The transition to go back to when the user turns the custom transition on again.
    private(set) var lastCustomTransition = TransitionStyle.lightweight

    private init() {
        if let stored = defaults.string(forKey: Self.transitionKey), let style = TransitionStyle(rawValue: stored) {
            transition = style
        } else if defaults.object(forKey: "enabled") as? Bool == false {
            // The on/off switch of earlier versions.
            transition = .system
        } else {
            transition = .lightweight
        }

        dockMovesWithSpace = (defaults.object(forKey: Self.dockMovesWithSpaceKey) as? Bool) ?? true
        roundedCorners = (defaults.object(forKey: Self.roundedCornersKey) as? Bool) ?? true
        showsMenuBarIcon = (defaults.object(forKey: Self.showsMenuBarIconKey) as? Bool) ?? true

        let stored = defaults.double(forKey: Self.speedKey)
        speed = stored > 0 ? min(max(stored, Self.speedRange.lowerBound), Self.speedRange.upperBound) : 1

        let storedSensitivity = defaults.double(forKey: Self.sensitivityKey)
        sensitivity = storedSensitivity > 0
            ? min(max(storedSensitivity, Self.sensitivityRange.lowerBound), Self.sensitivityRange.upperBound) : 1
    }
}
