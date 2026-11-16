import AppKit

/// The ordered spaces of one display.
struct SpaceLayout {
    let displayUUID: String
    let spaceIDs: [UInt64]
    var currentIndex: Int
    /// Normal desktops, without the spaces of full-screen apps.
    let desktopIDs: [UInt64]
    let screen: NSScreen

    var displayID: CGDirectDisplayID { screen.displayID }
}

/// The spaces of one display and the one it shows, with no AppKit in it, so any thread can have it.
struct SpaceState {
    let spaceIDs: [UInt64]
    let currentID: UInt64
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static var underCursor: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main ?? screens.first
    }
}

/// Read-only access to the space list through private CoreGraphics services.
enum Spaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static let mainConnection: MainConnectionFn? = {
        guard let pointer = dlsym(rtldDefault, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(pointer, to: MainConnectionFn.self)
    }()

    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let copySpacesForWindows: CopySpacesForWindowsFn? = {
        guard let pointer = dlsym(rtldDefault, "CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(pointer, to: CopySpacesForWindowsFn.self)
    }()

    /// The spaces a window is on. Empty when unknown, or when the window was never on screen.
    static func spaces(ofWindow windowNumber: Int) -> [UInt64] {
        guard windowNumber > 0, let mainConnection, let copySpacesForWindows else { return [] }
        let allSpaces: Int32 = 7
        let windows = [NSNumber(value: windowNumber)] as CFArray
        let spaces = copySpacesForWindows(mainConnection(), allSpaces, windows)?.takeRetainedValue() as? [NSNumber]
        return spaces?.map { $0.uint64Value } ?? []
    }

    // MARK: A space of our own

    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Void
    private typealias MoveWindowsToSpaceFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void

    /// The level of our space among the spaces of the window server. The spaces of the user (desktops and
    /// full-screen apps) are at 0, with the Dock and the menu bar in them. The spaces of the system above them
    /// start at 299; the cursor is at 800.
    private static let ownSpaceLevel: Int32 = 100

    /// A space of this app, shown at all times above the spaces of the user. Nil when the calls are missing.
    /// The window server removes it when the app quits.
    private static let ownSpace: UInt64? = {
        guard let mainConnection,
              let create = dlsym(rtldDefault, "SLSSpaceCreate").map({ unsafeBitCast($0, to: SpaceCreateFn.self) }),
              let setLevel = dlsym(rtldDefault, "SLSSpaceSetAbsoluteLevel").map({ unsafeBitCast($0, to: SpaceSetAbsoluteLevelFn.self) }),
              let show = dlsym(rtldDefault, "SLSShowSpaces").map({ unsafeBitCast($0, to: ShowSpacesFn.self) })
        else { return nil }
        let connection = mainConnection()
        let space = create(connection, 1, nil)
        guard space != 0 else { return nil }
        setLevel(connection, space, ownSpaceLevel)
        show(connection, [NSNumber(value: space)] as CFArray)
        return space
    }()

    private static let moveWindowsToSpace: MoveWindowsToSpaceFn? = {
        guard let pointer = dlsym(rtldDefault, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { return nil }
        return unsafeBitCast(pointer, to: MoveWindowsToSpaceFn.self)
    }()

    /// Moves a window out of the spaces of the user, into the space of this app. False when the calls are
    /// missing. Call it after the window is ordered in: the window server takes both in order, but reports
    /// where the window is only a moment later.
    ///
    /// When the Dock switches to or from the space of a full-screen app, the window server draws one frame
    /// with no window that is on all spaces, whatever its level: a window that covers the screen lets the
    /// space below show through for that frame (measured: about every second switch). A window in a space
    /// of its own is not part of the switch. It stays there when it is ordered out and in again.
    static func moveToOwnSpace(windowNumber: Int) -> Bool {
        guard windowNumber > 0, let mainConnection, let ownSpace, let moveWindowsToSpace else { return false }
        let userSpaces: Int32 = 7
        moveWindowsToSpace(mainConnection(), ownSpace, [NSNumber(value: windowNumber)] as CFArray, userSpaces)
        return true
    }

    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = {
        guard let pointer = dlsym(rtldDefault, "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(pointer, to: CopyManagedDisplaySpacesFn.self)
    }()

    static var isAvailable: Bool {
        mainConnection != nil && copyManagedDisplaySpaces != nil
    }

    static func layout(for screen: NSScreen) -> SpaceLayout? {
        guard let entry = displayEntry(for: screen.displayID),
              let spaces = entry.entry["Spaces"] as? [[String: Any]],
              let state = state(of: entry.entry),
              let index = state.spaceIDs.firstIndex(of: state.currentID)
        else { return nil }

        let desktops = spaces.compactMap { space -> UInt64? in
            guard (space["type"] as? NSNumber)?.intValue == 0 else { return nil }
            return (space["id64"] as? NSNumber)?.uint64Value
        }

        return SpaceLayout(
            displayUUID: (entry.entry["Display Identifier"] as? String) ?? entry.uuid ?? "Main",
            spaceIDs: state.spaceIDs,
            currentIndex: index,
            desktopIDs: desktops,
            screen: screen
        )
    }

    /// The spaces of a display and the one it shows. Safe to call from any thread: it uses no AppKit.
    static func state(displayID: CGDirectDisplayID) -> SpaceState? {
        displayEntry(for: displayID).flatMap { state(of: $0.entry) }
    }

    private static func state(of entry: [String: Any]) -> SpaceState? {
        guard let spaces = entry["Spaces"] as? [[String: Any]] else { return nil }
        let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard !ids.isEmpty,
              let current = ((entry["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value,
              ids.contains(current)
        else { return nil }
        return SpaceState(spaceIDs: ids, currentID: current)
    }

    private static func displayEntry(for displayID: CGDirectDisplayID) -> (entry: [String: Any], uuid: String?)? {
        guard let mainConnection, let copyManagedDisplaySpaces else { return nil }
        let connection = mainConnection()
        guard connection != 0,
              let displays = copyManagedDisplaySpaces(connection, nil)?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty
        else { return nil }

        let uuid = displayUUID(for: displayID)
        // With "Displays have separate Spaces" off there is one entry, named "Main".
        let entry = displays.first { ($0["Display Identifier"] as? String) == uuid } ?? displays[0]
        return (entry, uuid)
    }

    private static func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
