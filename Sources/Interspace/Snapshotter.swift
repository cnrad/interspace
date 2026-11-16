import AppKit
import ScreenCaptureKit

/// A full-screen image of one space.
struct Snapshot {
    /// The screen as it looks, window shadows included.
    let image: CGImage
    /// The area around the camera with the island removed. It goes on top of `image`.
    var patch: CGImage?
    /// Where `patch` goes, in points from the top left of the screen.
    var patchFrame = CGRect.zero
    /// False when the image stops below the Dock: it has no Dock, no menu bar and no island.
    /// The overlay must then be below the Dock too, so the real ones show on top of it.
    var includesDock = true

}

/// A snapshot that uses less memory: the same pixels, compressed with no loss. Use from any thread.
///
/// A full-screen image is about 34 MB on a 3600 x 2364 display. The app keeps one for each space, and it
/// draws only the spaces near the current one. The others wait in this form.
struct PackedSnapshot {
    private let data: NSData
    private let width: Int
    private let height: Int
    private let bitsPerComponent: Int
    private let bitsPerPixel: Int
    private let bytesPerRow: Int
    private let colorSpace: CGColorSpace
    private let bitmapInfo: CGBitmapInfo
    private let shouldInterpolate: Bool
    private let intent: CGColorRenderingIntent
    private let patch: CGImage?
    private let patchFrame: CGRect
    let includesDock: Bool

    /// Bytes in memory, and bytes of the image this was made from.
    var byteCount: Int { data.length }
    var fullByteCount: Int { bytesPerRow * height }

    /// Nil when the pixels cannot be read, or when the result is not much smaller.
    init?(_ snapshot: Snapshot) {
        let image = snapshot.image
        guard let colorSpace = image.colorSpace,
              let pixels = image.dataProvider?.data as NSData?,
              pixels.length >= image.bytesPerRow * image.height,
              let compressed = try? pixels.compressed(using: .lz4),
              compressed.length * 4 < pixels.length * 3
        else { return nil }
        data = compressed
        width = image.width
        height = image.height
        bitsPerComponent = image.bitsPerComponent
        bitsPerPixel = image.bitsPerPixel
        bytesPerRow = image.bytesPerRow
        self.colorSpace = colorSpace
        bitmapInfo = image.bitmapInfo
        shouldInterpolate = image.shouldInterpolate
        intent = image.renderingIntent
        patch = snapshot.patch
        patchFrame = snapshot.patchFrame
        includesDock = snapshot.includesDock
    }

    /// The snapshot this was made from, with the same pixels. About 15 ms for a full-screen image.
    func unpacked() -> Snapshot? {
        guard let pixels = try? data.decompressed(using: .lz4),
              pixels.length >= bytesPerRow * height,
              let provider = CGDataProvider(data: pixels),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
                  bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                  decode: nil, shouldInterpolate: shouldInterpolate, intent: intent
              )
        else { return nil }
        return Snapshot(image: image, patch: patch, patchFrame: patchFrame, includesDock: includesDock)
    }

    /// True when both are the same stored data, not only equal data.
    func isSame(as other: PackedSnapshot) -> Bool {
        data === other.data
    }
}

/// Captures displays with ScreenCaptureKit. Use from the main thread.
///
/// Two captures run at the same time, because no single one gives the right image:
/// - a capture of the screen rectangle has window shadows, but also the island around the camera;
/// - a capture with a window filter can leave the island out, but has no window shadows.
/// The first is the image. A small piece of the second covers the island.
final class Snapshotter {
    /// The system process that draws the island, in a full-screen window above the menu bar.
    /// The island does not move with a space, so it must not be in the image of one.
    private static let islandOwnerBundleID = "com.apple.MenuBarAgent"
    private static let menuBarWindowLayer = 24

    private var displays: [CGDirectDisplayID: SCDisplay] = [:]
    private var islandWindows: [SCWindow] = []
    /// Windows of this app that are on screen (the overlay).
    private var ownWindows: [SCWindow] = []
    private var waiters: [CGDirectDisplayID: [(Snapshot?) -> Void]] = [:]
    /// The capture that runs for each display. A result with a different number is from a capture that
    /// was given up, and it is ignored.
    private var running: [CGDirectDisplayID: Int] = [:]
    /// When the capture that runs for each display started.
    private var runningSince: [CGDirectDisplayID: CFTimeInterval] = [:]
    private var lastCaptureNumber = 0
    /// A capture takes much less than 0.1 s. The capture service can stop answering, and then the
    /// callers must not wait with no end.
    private static let captureTimeout: Double = 2
    /// A capture that runs longer than this is not shared with a new caller, who would wait on it with the
    /// gesture in progress: a new capture starts, and every caller gets its result. Measured: 30 to 140 ms.
    private static let staleCapture: Double = 0.3

    /// Loads the display and window lists. It is slow, so do it before the first swipe.
    func refreshDisplays(_ completion: (() -> Void)? = nil) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                if let self, let content {
                    self.displays = content.displays.reduce(into: [:]) { $0[$1.displayID] = $1 }
                    self.islandWindows = content.windows.filter {
                        $0.owningApplication?.bundleIdentifier == Self.islandOwnerBundleID
                            && $0.windowLayer > Self.menuBarWindowLayer
                    }
                    let pid = ProcessInfo.processInfo.processIdentifier
                    self.ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
                }
                completion?()
            }
        }
    }

    /// Captures one display. Calls made while a capture of the same display runs share its result.
    ///
    /// With `includeDock` false the image has only what is below the Dock. If that is not possible,
    /// the result is the full screen: look at `includesDock` of the snapshot.
    func capture(screen: NSScreen, includeDock: Bool = true, completion: @escaping (Snapshot?) -> Void) {
        let displayID = screen.displayID
        if waiters[displayID] != nil {
            waiters[displayID]?.append(completion)
            guard CACurrentMediaTime() - (runningSince[displayID] ?? 0) > Self.staleCapture else { return }
            // The capture that runs is late. Its result, if it comes, is ignored: see `finish`.
        } else {
            waiters[displayID] = [completion]
        }
        lastCaptureNumber += 1
        let number = lastCaptureNumber
        running[displayID] = number
        runningSince[displayID] = CACurrentMediaTime()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureTimeout) { [weak self] in
            guard let self, self.running[displayID] == number else { return }
            // The display and window lists can be the cause, so the next capture loads them again.
            self.displays[displayID] = nil
            self.finish(displayID, nil, number)
        }

        if includeDock {
            captureScreen(screen, number)
        } else {
            captureBelowDock(screen: screen) { [weak self] snapshot in
                guard let self, self.running[displayID] == number else { return }
                if let snapshot {
                    self.finish(displayID, snapshot, number)
                } else {
                    self.captureScreen(screen, number)
                }
            }
        }
    }

    /// The full screen, as it looks.
    private func captureScreen(_ screen: NSScreen, _ number: Int) {
        let displayID = screen.displayID
        let scale = screen.backingScaleFactor
        let islandFrame = Self.islandFrame(on: screen)
        if let display = displays[displayID] {
            run(display: display, scale: scale, islandFrame: islandFrame, number: number)
        } else {
            refreshDisplays { [weak self] in
                guard let self else { return }
                if let display = self.displays[displayID] {
                    self.run(display: display, scale: scale, islandFrame: islandFrame, number: number)
                } else {
                    self.finish(displayID, nil, number)
                }
            }
        }
    }

    private func run(display: SCDisplay, scale: CGFloat, islandFrame: CGRect?, number: Int) {
        let displayID = display.displayID
        let group = DispatchGroup()
        var screenImage: CGImage?
        var filteredImage: CGImage?

        var needsFiltered = true
        if #available(macOS 15.2, *) {
            needsFiltered = islandFrame != nil && !islandWindows.isEmpty
            group.enter()
            SCScreenshotManager.captureImage(in: display.frame) { image, _ in
                DispatchQueue.main.async {
                    screenImage = image
                    group.leave()
                }
            }
        }

        if needsFiltered {
            let filter = SCContentFilter(display: display, excludingWindows: islandWindows)
            let configuration = filteredConfiguration(for: display, scale: scale)
            group.enter()
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                DispatchQueue.main.async {
                    filteredImage = image
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard let image = screenImage ?? filteredImage else {
                // The display and window lists can be stale after a display change.
                self.displays[displayID] = nil
                self.finish(displayID, nil, number)
                return
            }
            var snapshot = Snapshot(image: image)
            if screenImage != nil, let filteredImage, let islandFrame {
                Self.addPatch(to: &snapshot, from: filteredImage, islandFrame: islandFrame, scale: scale)
            }
            self.finish(displayID, snapshot, number)
        }
    }

    private func filteredConfiguration(for display: SCDisplay, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((CGFloat(display.width) * scale).rounded())
        configuration.height = Int((CGFloat(display.height) * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        // Wide gamut, so the snapshot matches the live desktop on a P3 panel.
        configuration.colorSpaceName = CGColorSpace.displayP3
        return configuration
    }

    private static func addPatch(to snapshot: inout Snapshot, from filtered: CGImage, islandFrame: CGRect, scale: CGFloat) {
        let pixels = CGRect(
            x: islandFrame.minX * scale, y: islandFrame.minY * scale,
            width: islandFrame.width * scale, height: islandFrame.height * scale
        ).integral
        guard let crop = filtered.cropping(to: pixels) else { return }
        // A cropped image keeps the whole image it was cut from in memory: one more full screen for each
        // snapshot. The copy has only its own pixels.
        snapshot.patch = Self.copy(of: crop) ?? crop
        snapshot.patchFrame = CGRect(
            x: pixels.minX / scale, y: pixels.minY / scale,
            width: pixels.width / scale, height: pixels.height / scale
        )
    }

    /// The same pixels in memory of their own.
    private static func copy(of image: CGImage) -> CGImage? {
        guard let colorSpace = image.colorSpace, colorSpace.model == .rgb, image.bitsPerComponent == 8,
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: - Capture below the overlay

    private typealias WindowListImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage`. It is not in the current SDK, but it is the one capture that can take
    /// "everything below this window" with window shadows.
    private static let windowListImage: WindowListImageFn? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(pointer, to: WindowListImageFn.self)
    }()

    // MARK: - Capture below the Dock

    private static let captureQueue = DispatchQueue(label: "com.cnrad.interspace.capture", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private static let dockBundleID = "com.apple.dock"
    private static let dockWindowLayer = Int(CGWindowLevelForKey(.dockWindow))

    /// Everything below the Dock window, window shadows included. The menu bar and the island are above
    /// the Dock, so they are not in the image either. Nil when the Dock has no window on screen.
    func captureBelowDock(screen: NSScreen, completion: @escaping (Snapshot?) -> Void) {
        let bounds = CGDisplayBounds(screen.displayID)
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first?.processIdentifier
        Self.captureQueue.async {
            let onScreenBelowWindow: UInt32 = 1 << 2
            var snapshot: Snapshot?
            if let dockPID, let window = Self.dockWindow(ownedBy: dockPID, on: bounds),
               let image = Self.windowListImage?(bounds, onScreenBelowWindow, window, 0)?.takeRetainedValue() {
                snapshot = Snapshot(image: image, includesDock: false)
            }
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
    }

    /// The window the Dock draws itself in. The order of windows is the same on all displays, so a Dock
    /// window on a different display is also a correct limit for this one.
    private static func dockWindow(ownedBy pid: pid_t, on bounds: CGRect) -> UInt32? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var onDisplay: UInt32?
        var anywhere: UInt32?
        // The list goes from front to back. The last match is the lowest, so no Dock window is below it.
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == dockWindowLayer,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            anywhere = number
            if let frame = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
               frame.intersects(bounds) {
                onDisplay = number
            }
        }
        return onDisplay ?? anywhere
    }

    private static let sampleQueue = DispatchQueue(label: "com.cnrad.interspace.sample", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private static let sampleWidth = 96
    private static let sampleHeight = 60

    /// A very small grey copy of the screen below one of our windows, to tell if the screen still changes.
    /// It runs off the main thread, so the gesture stays responsive.
    func sampleBelow(windowNumber: Int, screen: NSScreen, completion: @escaping ([UInt8]?) -> Void) {
        let bounds = CGDisplayBounds(screen.displayID)
        Self.sampleQueue.async {
            let onScreenBelowWindow: UInt32 = 1 << 2
            let nominalResolution: UInt32 = 1 << 4
            var sample: [UInt8]?
            if windowNumber > 0,
               let image = Self.windowListImage?(bounds, onScreenBelowWindow, UInt32(windowNumber), nominalResolution)?
                   .takeRetainedValue() {
                var pixels = [UInt8](repeating: 0, count: Self.sampleWidth * Self.sampleHeight)
                let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                    guard let context = CGContext(
                        data: buffer.baseAddress, width: Self.sampleWidth, height: Self.sampleHeight,
                        bitsPerComponent: 8, bytesPerRow: Self.sampleWidth, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue
                    ) else { return false }
                    context.interpolationQuality = .medium
                    context.draw(image, in: CGRect(x: 0, y: 0, width: Self.sampleWidth, height: Self.sampleHeight))
                    return true
                }
                if drawn {
                    sample = pixels
                }
            }
            DispatchQueue.main.async {
                completion(sample)
            }
        }
    }

    /// True when two samples show the same screen. A text cursor that blinks does not count as a change.
    ///
    /// `sameDesktop` asks a different question: are the two samples of the same desktop, with some time
    /// between them? Small changes (a clock, text that is being written) are then allowed. Two different
    /// desktops differ in most of the picture, so this test is safe to make much less strict.
    static func samplesMatch(_ a: [UInt8], _ b: [UInt8], sameDesktop: Bool = false) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var total = 0
        var changed = 0
        for index in a.indices {
            let difference = abs(Int(a[index]) - Int(b[index]))
            total += difference
            if difference > 16 { changed += 1 }
        }
        if sameDesktop {
            return Double(total) / Double(a.count) < 6 && changed * 12 < a.count
        }
        return Double(total) / Double(a.count) < 0.6 && changed * 400 < a.count
    }

    /// Captures a screen as it is below one of our windows, while that window covers it.
    /// Call `refreshDisplays` after the window is on screen and before this, so the window is known.
    /// `includesDock` says if that window is above the Dock. If it is not, the image has no island to cover.
    func captureBelow(windowNumber: Int, screen: NSScreen, includesDock: Bool = true, completion: @escaping (Snapshot?) -> Void) {
        let displayID = screen.displayID
        let scale = screen.backingScaleFactor
        let onScreenBelowWindow: UInt32 = 1 << 2
        guard windowNumber > 0,
              let image = Self.windowListImage?(CGDisplayBounds(displayID), onScreenBelowWindow, UInt32(windowNumber), 0)?
                  .takeRetainedValue()
        else {
            completion(nil)
            return
        }

        var snapshot = Snapshot(image: image, includesDock: includesDock)
        guard includesDock, let islandFrame = Self.islandFrame(on: screen), !islandWindows.isEmpty, !ownWindows.isEmpty,
              let display = displays[displayID]
        else {
            completion(snapshot)
            return
        }

        let filter = SCContentFilter(display: display, excludingWindows: islandWindows + ownWindows)
        let configuration = filteredConfiguration(for: display, scale: scale)
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { filtered, _ in
            DispatchQueue.main.async {
                if let filtered {
                    Self.addPatch(to: &snapshot, from: filtered, islandFrame: islandFrame, scale: scale)
                }
                completion(snapshot)
            }
        }
    }

    private func finish(_ displayID: CGDirectDisplayID, _ snapshot: Snapshot?, _ number: Int) {
        guard running[displayID] == number else { return }
        running[displayID] = nil
        runningSince[displayID] = nil
        let callbacks = waiters.removeValue(forKey: displayID) ?? []
        for callback in callbacks {
            callback(snapshot)
        }
    }

    /// The area that can hold the island, in points from the top left of the screen. Nil when the screen has no camera housing.
    private static func islandFrame(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }
        let minX = left.maxX - screen.frame.minX
        let maxX = right.minX - screen.frame.minX
        let width = maxX - minX
        guard width > 0 else { return nil }
        // One housing width more on each side, in case the island is wider than the housing.
        return CGRect(x: minX - width, y: 0, width: width * 3, height: screen.safeAreaInsets.top)
            .intersection(CGRect(origin: .zero, size: screen.frame.size))
    }

    /// What a desktop picture is made from. Read on the main thread, used on any thread.
    private struct WallpaperRequest {
        let url: URL
        let width: Int
        let height: Int
    }

    private static let wallpaperQueue = DispatchQueue(label: "com.cnrad.interspace.wallpaper", qos: .userInitiated, autoreleaseFrequency: .workItem)

    private static func wallpaperRequest(for screen: NSScreen) -> WallpaperRequest? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let scale = screen.backingScaleFactor
        let width = Int((screen.frame.width * scale).rounded())
        let height = Int((screen.frame.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        return WallpaperRequest(url: url, width: width, height: height)
    }

    /// The desktop picture, for a space we have not seen yet.
    ///
    /// It takes more than 0.1 s for a large picture, so this is only for when the picture was not made
    /// ahead of time: see the version with a completion.
    func wallpaper(for screen: NSScreen) -> Snapshot? {
        Self.wallpaperRequest(for: screen).flatMap(Self.renderWallpaper)
    }

    /// The same picture, made off the main thread. `completion` is called on the main thread.
    func wallpaper(for screen: NSScreen, completion: @escaping (Snapshot?) -> Void) {
        guard let request = Self.wallpaperRequest(for: screen) else {
            completion(nil)
            return
        }
        Self.wallpaperQueue.async {
            let snapshot = Self.renderWallpaper(request)
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
    }

    private static func renderWallpaper(_ request: WallpaperRequest) -> Snapshot? {
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = request.width
        let height = request.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let bitmap = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        // Aspect fill.
        let fill = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * fill, height: CGFloat(image.height) * fill)
        let rect = CGRect(
            x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2,
            width: size.width, height: size.height
        )
        bitmap.interpolationQuality = .high
        bitmap.draw(image, in: rect)
        return bitmap.makeImage().map { Snapshot(image: $0) }
    }
}
