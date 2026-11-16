import CoreGraphics

/// Every value you may want to tune is here. Rebuild with `scripts/bundle.sh` after a change.
enum Config {
    // MARK: Gesture

    /// Transition progress for one full trackpad width of finger travel.
    static let travelPerTrackpadWidth: CGFloat = 0.9
    /// Release past this progress commits to the next space.
    static let commitThreshold: CGFloat = 0.25
    /// A release faster than this (progress per second) commits below the threshold,
    /// or cancels above it when the flick goes backwards. Set to `.infinity` to disable.
    static let flickVelocity: CGFloat = 1.5
    /// A flick must travel at least this far to commit.
    static let flickMinProgress: CGFloat = 0.03
    /// Finger travel (fraction of trackpad width) before the swipe direction is decided.
    static let directionSlop: CGFloat = 0.015
    /// Maximum travel past the first or last space.
    static let edgeRubberBand: CGFloat = 0.12

    // MARK: Snap animation

    /// Spring response in seconds for the snap after release, at speed 1 in the settings. Lower is faster.
    static let springResponse: CGFloat = 0.19
    /// 1 = no overshoot.
    static let springDamping: CGFloat = 1.0
    /// Fade from the snapshot to the live desktop after the snap.
    static let revealDuration: CGFloat = 0.08
    /// The overlay fades out only when it was on screen for less than this, in seconds. Longer, and macOS
    /// has stopped drawing the desktop below it: the overlay is then removed in one step. See `Overlay.canFadeOut`.
    static let fadeSafeTime: Double = 0.8
    /// The fade can start when the screen is this close to its final place. The spring finishes below the fade.
    /// The live desktop is already at the final place, so a larger value shows as a small jump at the end:
    /// 0.01 is 18 points on a 1800 point wide screen and is visible, 0.0015 is under 3 points.
    static let revealStartDistance: CGFloat = 0.0015
    /// The check of the live desktop starts when the screen is this close to its final place,
    /// so the answer is ready when the snap ends. Each look takes about 20 ms of work in the window server,
    /// which also draws the transition, and can make it miss a frame. This close to the end the picture
    /// moves a few points a frame, so a missed frame does not show, and the answer still comes about when
    /// the snap ends.
    static let liveCheckStartDistance: CGFloat = 0.01

    /// The real switch of the space, below the overlay, is sent when the screen is this close to its final
    /// place. A switch makes the window server miss a frame of everything on screen (measured: about one for
    /// each switch), and a missed frame shows only while the picture moves fast. Here it moves about 5 points
    /// a frame, and it takes the snap about 55 ms more to come to rest: the Dock lands in 15 to 70 ms, so the
    /// fade seldom has to wait for it. At rest (0.0015) the fade waited about 100 ms with a still picture.
    /// A swipe that catches the picture before this point, and goes back, needs no switch at all.
    static let switchDistance: CGFloat = 0.01

    /// After a switch, the fade waits until the live desktop below has stopped changing,
    /// so it never shows a space that is still drawing. This is the longest it waits, in seconds.
    static let revealMaxWait: Double = 0.6

    // MARK: Look

    /// How much each screen shrinks during the transition (0.06 = 94% size).
    static let scaleInset: CGFloat = 0.06
    /// Corner radius of each screen, used only when macOS does not report the radius of the display.
    static let fallbackCornerRadius: CGFloat = 12
    /// Space between two screens, in points. It does not change during the transition.
    static let gap: CGFloat = 28
    /// Progress over which the screens ease down to their smallest size, and back up before landing.
    /// 0.5 is the whole way to the middle (no hold at the smallest size). Lower values scale faster, then hold.
    static let scaleDistance: CGFloat = 0.36
    /// 0...1, darkening for a screen that is fully off-centre.
    static let dimAmount: CGFloat = 0.3

    // MARK: Hexagon

    /// How far the eye is from the screen, in screen widths. Lower makes the turn look deeper.
    static let hexPerspective: CGFloat = 2.0
    /// How far the hexagon moves back during the turn, in screen widths, so its near edge stays on screen.
    static let hexPushback: CGFloat = 0.2
    /// 0...1, darkening of a side that is turned one full step away.
    static let hexDim: CGFloat = 0.45

    // MARK: Magnetic

    /// How much a screen shrinks when it is one full step away from the middle (0.22 = 78% size).
    static let magneticInset: CGFloat = 0.22

    // MARK: Stack

    /// How much a screen shrinks when another screen is fully on top of it (0.05 = 95% size).
    static let stackInset: CGFloat = 0.05
    /// 0...1, darkening of a screen that is fully covered.
    static let stackDim: CGFloat = 0.4
    /// 0...1, strength of the shadow of the screen that slides.
    static let stackShadow: CGFloat = 0.5
    /// Blur radius of that shadow, in points.
    static let stackShadowRadius: CGFloat = 40

    // MARK: Capture

    /// Take the snapshot when three fingers touch down, before the direction is known.
    /// Removes most of the delay at the start of a swipe.
    static let captureOnTouchDown = true
    /// A snapshot older than this (seconds) is taken again when the swipe starts.
    static let snapshotMaxAge: Double = 0.25
    /// After each switch, capture the new space again when the overlay is gone,
    /// so a quick swipe back uses an image that is seconds old.
    static let refreshAfterSwitch = true
    /// Number of space snapshots kept in memory.
    static let snapshotCacheLimit = 16
    /// Spaces further than this from the current one keep their image compressed, with no loss of pixels.
    /// An image is made full again when its space comes this near, one step before it can show.
    /// So this must be more than `Overlay.reach`.
    static let fullImageRadius = 3
    /// At launch, visit every space one time behind a frozen image of the screen and capture it,
    /// so the first swipe to a space already shows its real content.
    static let captureSpacesAtLaunch = true
    /// Seconds a space gets to draw itself during that visit before it is captured.
    static let visitSettleTime: Double = 0.35
}
