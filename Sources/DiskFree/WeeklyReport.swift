import AppKit
import Foundation
import UserNotifications

/// The weekly, read-only scan: writes a Markdown report with what can be cleaned and posts a notification.
/// It never deletes anything.
enum WeeklyReport {
    static let directory = homePath + "/Library/Application Support/DiskFree/Reports"
    static let keptReports = 12

    struct Summary: Codable {
        let date: Date
        let free: Int64
        let capacity: Int64
        let byRisk: [String: Int64]
        let byCategory: [String: Int64]

        var safe: Int64 { byRisk[Risk.safe.title] ?? 0 }
        var total: Int64 { byRisk.values.reduce(0, +) }
    }

    struct Latest {
        let summary: Summary
        let markdown: URL
    }

    /// Entry point for `DiskFree --weekly-report`, run by the login agent.
    static func runScheduled() {
        let items = Scanner().scanAll()
        let staleDays = UserDefaults.standard.object(forKey: "staleDays") as? Int ?? 90
        let latest = write(Assessment(items: items, staleDays: staleDays))
        notify(latest)
    }

    /// Writes the report for a finished scan and returns it. Older reports beyond `keptReports` are removed.
    @discardableResult
    static func write(_ assessment: Assessment) -> Latest {
        let previous = latest()?.summary
        let (free, capacity) = volumeSpace()
        let summary = Summary(
            date: Date(), free: free, capacity: capacity,
            byRisk: Dictionary(uniqueKeysWithValues: Risk.allCases.map { ($0.title, assessment.total(assessment.items(at: $0))) }),
            byCategory: Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0.rawValue, assessment.total(assessment.items(in: $0))) }))

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: summary.date, timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "")
        let markdown = URL(fileURLWithPath: directory + "/DiskFree \(stamp).md")
        try? render(assessment, summary, previous: previous).write(to: markdown, atomically: true, encoding: .utf8)
        try? encoder.encode(summary).write(to: markdown.deletingPathExtension().appendingPathExtension("json"))

        for old in reportFiles().dropLast(keptReports) {
            try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.removeItem(atPath: (old as NSString).deletingPathExtension + ".md")
        }
        return Latest(summary: summary, markdown: markdown)
    }

    /// JSON summaries, oldest first.
    static func reportFiles() -> [String] {
        children(directory).filter { $0.hasSuffix(".json") }.map { directory + "/" + $0 }
    }

    static func latest() -> Latest? {
        guard let path = reportFiles().last,
              let data = FileManager.default.contents(atPath: path),
              let summary = try? decoder.decode(Summary.self, from: data) else { return nil }
        return Latest(summary: summary, markdown: URL(fileURLWithPath: (path as NSString).deletingPathExtension + ".md"))
    }

    static func render(_ assessment: Assessment, _ summary: Summary, previous: Summary?) -> String {
        let safe = assessment.items(at: .safe), caution = assessment.items(at: .caution), review = assessment.items(at: .review)
        let safeBytes = assessment.total(safe)
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }

        var md = "# DiskFree weekly report — \(summary.date.formatted(date: .long, time: .shortened))\n\n"
        md += "**\(formatBytes(summary.free)) free** of \(formatBytes(summary.capacity))"
        if let previous {
            let delta = summary.free - previous.free
            md += " (\(delta >= 0 ? "+" : "−")\(formatBytes(abs(delta))) since \(previous.date.formatted(date: .abbreviated, time: .omitted)))"
        }
        md += "\n\n\(formatBytes(summary.total)) can be freed: **\(formatBytes(safeBytes)) risk-free**, "
        md += "\(formatBytes(assessment.total(caution))) small risk, \(formatBytes(assessment.total(review))) to check yourself.\n\n"

        md += "## What you can do\n\n"
        var steps: [String] = []
        if safeBytes > 0 {
            steps.append("**Clean everything risk-free (\(formatBytes(safeBytes)), \(safe.count) items).** Open DiskFree → Overview → *Clean All Risk-Free…*. That brings you to about \(formatBytes(summary.free + safeBytes)) free. Then empty DiskFree's Trash in the sidebar.")
        }
        for lever in assessment.levers.filter({ $0.risk == .caution }).prefix(3) {
            steps.append("Consider **\(lever.title)** (\(formatBytes(lever.bytes))): \(lever.detail). Review it under *\(lever.category.title)*.")
        }
        if !review.isEmpty {
            steps.append("Go through **\(review.count) items only you can judge** (\(formatBytes(assessment.total(review)))) — your own downloads and model files.")
        }
        md += steps.isEmpty ? "Nothing worth cleaning right now.\n" : steps.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n") + "\n"

        md += "\n## Biggest levers\n\n| # | What | Size | Risk | Why |\n|---:|---|---:|---|---|\n"
        for (index, lever) in assessment.levers.enumerated() {
            md += "| \(index + 1) | \(cell(lever.title)) | \(formatBytes(lever.bytes)) | \(lever.risk.title) | \(cell(lever.detail)) |\n"
        }

        md += "\n## By category\n\n| Category | Now |\(previous == nil ? "" : " Last report | Change |")\n|---|---:|\(previous == nil ? "" : "---:|---:|")\n"
        for category in Category.allCases {
            let now = summary.byCategory[category.rawValue] ?? 0
            md += "| \(category.title) | \(formatBytes(now)) |"
            if let before = previous?.byCategory[category.rawValue] {
                let change = now - before
                md += " \(formatBytes(before)) | \(change == 0 ? "—" : (change > 0 ? "+" : "−") + formatBytes(abs(change))) |"
            } else if previous != nil {
                md += " — | — |"
            }
            md += "\n"
        }
        md += "\n---\nThis report only scanned the disk. Nothing was deleted: every clean needs your click and confirmation in DiskFree.\n"
        return md
    }

    static func notify(_ latest: Latest) {
        let summary = latest.summary
        var body = "\(formatBytes(summary.total)) can be freed, \(formatBytes(summary.safe)) of it risk-free. \(formatBytes(summary.free)) free now."
        if let previous = reportFiles().dropLast().last.flatMap({ FileManager.default.contents(atPath: $0) })
            .flatMap({ try? decoder.decode(Summary.self, from: $0) }) {
            let delta = summary.free - previous.free
            body += " (\(delta >= 0 ? "+" : "−")\(formatBytes(abs(delta))) since last report)"
        }
        let center = UNUserNotificationCenter.current()
        let delivered = DispatchSemaphore(value: 0)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { delivered.signal(); return }
            let content = UNMutableNotificationContent()
            content.title = "DiskFree weekly report"
            content.body = body
            content.userInfo = ["report": latest.markdown.path]
            center.add(UNNotificationRequest(identifier: "weekly-\(Int(summary.date.timeIntervalSince1970))",
                                             content: content, trigger: nil)) { _ in delivered.signal() }
        }
        _ = delivered.wait(timeout: .now() + 30)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The login agent that runs the weekly report.
enum Schedule {
    static let label = "com.jenspolomski.diskfree.weekly"
    static var plistPath: String { homePath + "/Library/LaunchAgents/\(label).plist" }
    /// launchd numbering: 1 = Monday … 7 = Sunday.
    static let weekdays = [1: "Monday", 2: "Tuesday", 3: "Wednesday", 4: "Thursday", 5: "Friday", 6: "Saturday", 7: "Sunday"]

    struct Config: Equatable {
        var weekday = 1
        var hour = 9
    }

    static func current() -> Config? {
        guard let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
              let interval = plist["StartCalendarInterval"] as? [String: Int] else { return nil }
        return Config(weekday: interval["Weekday"] ?? 1, hour: interval["Hour"] ?? 9)
    }

    static func install(_ config: Config) throws {
        guard let executable = Bundle.main.executablePath else { throw Cleaner.Failure("can't locate the DiskFree binary") }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--weekly-report"],
            "StartCalendarInterval": ["Weekday": config.weekday, "Hour": config.hour, "Minute": 0],
            "Nice": 10,
            "StandardOutPath": "/tmp/diskfree-weekly.log",
            "StandardErrorPath": "/tmp/diskfree-weekly.log",
        ]
        try FileManager.default.createDirectory(atPath: parentPath(plistPath), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: plistPath))
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        guard launchctl(["bootstrap", "gui/\(getuid())", plistPath]) == 0 else { throw Cleaner.Failure("launchctl couldn't load the schedule") }
    }

    static func uninstall() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Opens the report when its notification is clicked.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["report"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
