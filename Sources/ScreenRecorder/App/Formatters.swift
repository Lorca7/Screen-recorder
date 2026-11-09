import Foundation

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func bytes(_ count: Int64) -> String {
        guard count > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: count)
    }

    static func bitrate(_ bitsPerSecond: Int) -> String {
        guard bitsPerSecond > 0 else { return "intra-frame (very high)" }
        return String(format: "%.0f Mbps", Double(bitsPerSecond) / 1_000_000)
    }
}
