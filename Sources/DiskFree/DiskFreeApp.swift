import SwiftUI

@main
struct DiskFreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store()

    init() {
        // `DiskFree --report` prints what a scan finds; `--weekly-report` is the scheduled run that writes a
        // report and notifies. Both exit without touching anything and without a Dock icon.
        if CommandLine.arguments.contains("--report") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            printReport()
            exit(0)
        }
        if CommandLine.arguments.contains("--weekly-report") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            WeeklyReport.runScheduled()
            exit(0)
        }
    }

    var body: some Scene {
        Window("DiskFree", id: "main") {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 960, idealWidth: 1180, minHeight: 600, idealHeight: 760)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            Label(formatBytes(store.free), systemImage: store.lowOnSpace ? "externaldrive.badge.exclamationmark" : "internaldrive")
                .labelStyle(.titleAndIcon)
        }
    }
}

func printReport() {
    let started = Date()
    let items = Scanner(report: { FileHandle.standardError.write(Data("\($0)\n".utf8)) }).scanAll()
    for category in Category.allCases {
        let rows = items.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
        let total = rows.reduce(0) { $0 + $1.bytes }
        let preselected = rows.filter { $0.category == .projects
            ? ($0.lastActivity.map { $0 < Date().addingTimeInterval(-90 * 86_400) } ?? false)
            : $0.recommended }
        print("\n## \(category.title): \(rows.count) items, \(formatBytes(total)) (preselected \(formatBytes(preselected.reduce(0) { $0 + $1.bytes })))")
        for item in rows.prefix(12) {
            let when = item.lastActivity?.formatted(date: .abbreviated, time: .omitted) ?? "—"
            print("  \(formatBytes(item.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(when.padding(toLength: 14, withPad: " ", startingAt: 0)) \(item.title)  [\(item.detail)]")
        }
    }
    print("\nScanned in \(Int(Date().timeIntervalSince(started)))s")
}
