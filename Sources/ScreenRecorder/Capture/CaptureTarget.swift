import CoreGraphics
import Foundation
import ScreenCaptureKit

/// What the user chose to record.
enum CaptureTarget {
    /// A whole display, plus every sound playing anywhere on the system.
    case display(SCDisplay)
    /// A single window, plus every sound playing anywhere on the system.
    case window(SCWindow)
    /// One or more applications on a display: only their windows are drawn and — crucially —
    /// only *their* audio is captured.
    case applications([SCRunningApplication], onDisplay: SCDisplay)

    var describedName: String {
        switch self {
        case .display(let display):
            return "Display \(display.displayID) — \(display.width)×\(display.height)"
        case .window(let window):
            let app = window.owningApplication?.applicationName ?? "Window"
            let title = window.title ?? ""
            return title.isEmpty ? app : "\(app) — \(title)"
        case .applications(let apps, _):
            if apps.count == 1 { return apps[0].applicationName }
            return "\(apps.count) applications"
        }
    }

    /// Whether the audio in the recording is limited to the chosen apps.
    var capturesOnlySelectedAppAudio: Bool {
        if case .applications = self { return true }
        return false
    }

    func contentFilter() -> SCContentFilter {
        switch self {
        case .display(let display):
            return SCContentFilter(display: display, excludingWindows: [])
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        case .applications(let apps, let display):
            return SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }
    }

    /// Native pixel dimensions to capture at, rounded down to even numbers because
    /// H.264/HEVC macroblocks require it.
    func pixelSize() -> (width: Int, height: Int) {
        switch self {
        case .display(let display), .applications(_, onDisplay: let display):
            let scale = CaptureTarget.backingScale(for: display)
            return CaptureTarget.evenSize(
                width: Double(display.width) * scale,
                height: Double(display.height) * scale
            )
        case .window(let window):
            let scale = CaptureTarget.backingScale(forWindow: window)
            return CaptureTarget.evenSize(
                width: window.frame.width * scale,
                height: window.frame.height * scale
            )
        }
    }

    private static func evenSize(width: Double, height: Double) -> (width: Int, height: Int) {
        let w = max(2, Int(width.rounded(.down)) & ~1)
        let h = max(2, Int(height.rounded(.down)) & ~1)
        return (w, h)
    }

    /// Ratio between the display's backing pixels and its point size, so Retina screens
    /// are recorded at full native resolution instead of being captured at half size.
    static func backingScale(for display: SCDisplay) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID), display.width > 0 else {
            return 2.0
        }
        let scale = Double(mode.pixelWidth) / Double(display.width)
        return scale > 0 ? scale : 1.0
    }

    private static func backingScale(forWindow window: SCWindow) -> Double {
        // Pick the display whose bounds contain the window's centre.
        let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(centre, 0, nil, &count) == .success, count > 0 else { return 2.0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetDisplaysWithPoint(centre, count, &ids, &count) == .success, let id = ids.first,
              let mode = CGDisplayCopyDisplayMode(id)
        else { return 2.0 }
        let points = Double(CGDisplayBounds(id).width)
        guard points > 0 else { return 2.0 }
        let scale = Double(mode.pixelWidth) / points
        return scale > 0 ? scale : 1.0
    }
}
