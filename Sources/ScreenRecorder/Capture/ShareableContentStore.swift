import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Loads the list of recordable displays, windows and applications, and tracks whether the
/// user has granted Screen Recording permission.
@MainActor
final class ShareableContentStore: ObservableObject {
    @Published private(set) var displays: [SCDisplay] = []
    @Published private(set) var windows: [SCWindow] = []
    @Published private(set) var applications: [SCRunningApplication] = []
    @Published private(set) var hasPermission: Bool = CGPreflightScreenCaptureAccess()
    @Published private(set) var isRefreshing = false
    @Published private(set) var loadError: String?

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        hasPermission = CGPreflightScreenCaptureAccess()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            hasPermission = true
            loadError = nil
            displays = content.displays

            let ownPID = ProcessInfo.processInfo.processIdentifier
            // Only windows a person could meaningfully point at: on-screen, normal layer,
            // big enough to see, and not one of our own.
            windows = content.windows
                .filter { window in
                    window.isOnScreen
                        && window.windowLayer == 0
                        && window.frame.width >= 80
                        && window.frame.height >= 60
                        && window.owningApplication?.processID != ownPID
                }
                .sorted { lhs, rhs in
                    let l = lhs.owningApplication?.applicationName ?? ""
                    let r = rhs.owningApplication?.applicationName ?? ""
                    if l == r { return (lhs.title ?? "") < (rhs.title ?? "") }
                    return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
                }

            // One entry per app that actually owns a visible window.
            let visibleAppIDs = Set(windows.compactMap { $0.owningApplication?.bundleIdentifier })
            var seen = Set<String>()
            applications = content.applications
                .filter { app in
                    app.processID != ownPID
                        && !app.applicationName.isEmpty
                        && visibleAppIDs.contains(app.bundleIdentifier)
                        && seen.insert(app.bundleIdentifier).inserted
                }
                .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
        } catch {
            // SCShareableContent is the canonical permission probe: it throws until the
            // user ticks this app in System Settings.
            hasPermission = false
            displays = []
            windows = []
            applications = []
            loadError = Self.message(for: error)
        }
    }

    func requestPermission() {
        // Puts the app in the Screen & System Audio Recording list and triggers the prompt.
        if !CGRequestScreenCaptureAccess() {
            openPrivacySettings()
        }
        Task { await refresh() }
    }

    func openPrivacySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )!
        NSWorkspace.shared.open(url)
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        // -3801 is SCStreamErrorUserDeclined: the app is not ticked in System Settings.
        if nsError.code == -3801 || nsError.domain.contains("ScreenCaptureKit") {
            return "Screen Recording permission has not been granted yet. "
                + "Enable it in System Settings \u{203A} Privacy & Security \u{203A} Screen & System Audio Recording."
        }
        return nsError.localizedDescription
    }
}
