import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Disk-changing operations. Each throws a readable error and leaves the original untouched on failure.
enum Cleaner {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Replaces `copy` with an APFS clone of `keeper` after a full byte comparison.
    static func replaceWithClone(_ copy: String, of keeper: String) throws {
        guard filesIdentical(copy, keeper) else { throw Failure("files differ, left as is") }
        let temporary = parentPath(copy) + "/.diskfree-\(UUID().uuidString)"
        guard clonefile(keeper, temporary, 0) == 0 else { throw Failure("clone failed: \(String(cString: strerror(errno)))") }
        if let mode = try? FileManager.default.attributesOfItem(atPath: copy)[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary)
        }
        guard rename(temporary, copy) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw Failure("replace failed: \(reason)")
        }
    }

    static func unloadAgent(_ label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Moves to the Trash and returns the path inside it, or deletes for good and returns nil.
    static func remove(_ url: URL, permanently: Bool) throws -> String? {
        if permanently {
            try FileManager.default.removeItem(at: url)
            return nil
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed?.path
    }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published var selection: Set<String> = []
    @Published private(set) var scanning = false
    @Published private(set) var working = false
    @Published private(set) var status = ""
    @Published private(set) var lastScan: Date?
    @Published private(set) var free: Int64 = 0
    @Published private(set) var capacity: Int64 = 0
    @Published var message: String?
    @Published var staleDays: Int = UserDefaults.standard.object(forKey: "staleDays") as? Int ?? 90 {
        didSet {
            UserDefaults.standard.set(staleDays, forKey: "staleDays")
            for item in items(in: .projects) {
                if isRecommended(item) { selection.insert(item.id) } else { selection.remove(item.id) }
            }
        }
    }
    /// Paths inside the Trash that DiskFree put there, with their size.
    @Published private(set) var trashed: [String: Int64] =
        UserDefaults.standard.dictionary(forKey: "trashed") as? [String: Int64] ?? [:] {
        didSet { UserDefaults.standard.set(trashed, forKey: "trashed") }
    }

    private var timer: Timer?

    init() {
        trashed = trashed.filter { exists($0.key) }
        refreshFree()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFree() }
        }
    }

    var busy: Bool { scanning || working }
    var trashedBytes: Int64 { trashed.values.reduce(0, +) }
    var reclaimable: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var lowOnSpace: Bool { capacity > 0 && free < capacity / 10 }

    func items(in category: Category) -> [Item] { items.filter { $0.category == category } }
    func total(_ category: Category) -> Int64 { items(in: category).reduce(0) { $0 + $1.bytes } }
    func selected(in category: Category) -> [Item] { items(in: category).filter { selection.contains($0.id) } }

    var assessment: Assessment { Assessment(items: items, staleDays: staleDays) }
    func risk(_ item: Item) -> Risk { assessment.risk(item) }
    func riskReason(_ item: Item) -> String { assessment.riskReason(item) }
    func items(at risk: Risk) -> [Item] { assessment.items(at: risk) }
    var levers: [Lever] { assessment.levers }

    /// Only risk-free items are preselected.
    func isRecommended(_ item: Item) -> Bool { risk(item) == .safe }

    func binding(for id: String) -> Binding<Bool> {
        Binding(get: { self.selection.contains(id) },
                set: { if $0 { self.selection.insert(id) } else { self.selection.remove(id) } })
    }

    func selectRecommended(in category: Category) {
        for item in items(in: category) {
            if isRecommended(item) { selection.insert(item.id) } else { selection.remove(item.id) }
        }
    }

    func selectNone(in category: Category) {
        selection.subtract(items(in: category).map(\.id))
    }

    func refreshFree() {
        (free, capacity) = volumeSpace()
    }

    // MARK: Weekly report

    @Published private(set) var schedule: Schedule.Config? = Schedule.current()
    @Published private(set) var latestReport: WeeklyReport.Latest? = WeeklyReport.latest()

    /// Turns the weekly report on (nil turns it off) and reloads the login agent.
    func setSchedule(_ config: Schedule.Config?) {
        do {
            if let config {
                try Schedule.install(config)
                // Ask for notification permission now, while the user is looking, not at the first scheduled run.
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            } else {
                Schedule.uninstall()
            }
        } catch {
            message = "Couldn't change the weekly schedule: \(error.localizedDescription)"
        }
        schedule = Schedule.current()
    }

    /// Picks up changes made outside the window, e.g. a scheduled run that just wrote a report.
    func reloadWeekly() {
        schedule = Schedule.current()
        latestReport = WeeklyReport.latest()
    }

    /// Writes a report from the current scan, without rescanning, and opens it.
    func reportNow() {
        guard lastScan != nil else { return }
        let report = WeeklyReport.write(assessment)
        latestReport = report
        NSWorkspace.shared.open(report.markdown)
    }

    func scan() {
        guard !busy else { return }
        scanning = true
        message = nil
        Task.detached(priority: .userInitiated) {
            let scanner = Scanner(report: { text in Task { @MainActor in self.status = text } })
            let found = scanner.scanAll()
            await MainActor.run {
                self.items = found
                self.selection = Set(found.filter(self.isRecommended).map(\.id))
                self.lastScan = Date()
                self.scanning = false
                self.status = ""
                self.refreshFree()
            }
        }
    }

    func clean(_ targets: [Item], permanently: Bool) {
        guard !busy, !targets.isEmpty else { return }
        working = true
        message = nil
        let freeBefore = free
        Task.detached(priority: .userInitiated) {
            var done: Set<String> = []
            var movedToTrash: [String: Int64] = [:]
            var failures: [String] = []
            for (index, item) in targets.enumerated() {
                await MainActor.run { self.status = "(\(index + 1)/\(targets.count)) \(item.title)" }
                do {
                    switch item.action {
                    case .trash:
                        if let path = try Cleaner.remove(item.url, permanently: permanently) { movedToTrash[path] = item.bytes }
                        for extra in item.extraPaths where exists(extra) {
                            if let path = try Cleaner.remove(URL(fileURLWithPath: extra), permanently: permanently) {
                                movedToTrash[path] = 0
                            }
                        }
                    case .cloneFrom(let keeper):
                        try Cleaner.replaceWithClone(item.path, of: keeper)
                    case .unloadAgent(let label):
                        Cleaner.unloadAgent(label)
                        if let path = try Cleaner.remove(item.url, permanently: permanently) { movedToTrash[path] = item.bytes }
                    }
                    done.insert(item.id)
                } catch {
                    failures.append("\(item.title): \(error.localizedDescription)")
                }
            }
            await MainActor.run { [done, movedToTrash, failures] in
                self.items.removeAll { done.contains($0.id) }
                self.selection.subtract(done)
                self.trashed.merge(movedToTrash) { $1 }
                self.working = false
                self.status = ""
                self.refreshFree()
                var lines: [String] = []
                if !movedToTrash.isEmpty {
                    lines.append("Moved \(formatBytes(movedToTrash.values.reduce(0, +))) to the Trash. Empty DiskFree's Trash to get the space back.")
                } else if !done.isEmpty {
                    lines.append("Done. Free space went from \(formatBytes(freeBefore)) to \(formatBytes(self.free)).")
                }
                if !failures.isEmpty { lines.append("\(failures.count) failed:\n" + failures.prefix(8).joined(separator: "\n")) }
                self.message = lines.joined(separator: "\n")
            }
        }
    }

    /// Permanently deletes only what DiskFree moved to the Trash; anything else in the Trash stays.
    func emptyTrash() {
        let paths = Array(trashed.keys)
        guard !busy, !paths.isEmpty else { return }
        working = true
        message = nil
        let freeBefore = free
        Task.detached(priority: .userInitiated) {
            var removed: [String] = []
            var failures: [String] = []
            for (index, path) in paths.enumerated() {
                await MainActor.run { self.status = "Emptying (\(index + 1)/\(paths.count)) \(lastComponent(path))" }
                do {
                    try FileManager.default.removeItem(atPath: path)
                    removed.append(path)
                } catch {
                    if exists(path) { failures.append(lastComponent(path)) } else { removed.append(path) }
                }
            }
            await MainActor.run { [removed, failures] in
                for path in removed { self.trashed.removeValue(forKey: path) }
                self.working = false
                self.status = ""
                self.refreshFree()
                self.message = failures.isEmpty
                    ? "Trash emptied. Free space went from \(formatBytes(freeBefore)) to \(formatBytes(self.free))."
                    : "macOS blocked deleting \(failures.count) item(s) from the Trash. Empty the Trash in Finder instead."
            }
        }
    }
}
