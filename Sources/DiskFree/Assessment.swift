import Foundation

struct Lever: Identifiable {
    let title: String
    let detail: String
    let bytes: Int64
    let risk: Risk
    let category: Category
    var id: String { category.rawValue + title }
}

/// Risk ratings and the biggest wins for a scan result. Shared by the window and the weekly report.
struct Assessment {
    let items: [Item]
    let staleDays: Int

    func isStale(_ item: Item) -> Bool {
        guard let last = item.lastActivity else { return false }
        return last < Date().addingTimeInterval(-Double(staleDays) * 86_400)
    }

    func risk(_ item: Item) -> Risk {
        switch item.category {
        case .projects: item.detail != "Python venv" && isStale(item) ? .safe : .caution
        case .models: item.recommended ? .safe : (item.detail.hasPrefix("Model file in") ? .review : .caution)
        case .duplicates, .agents: .safe
        case .caches: item.recommended ? .safe : .caution
        case .downloads: item.recommended ? .safe : .review
        }
    }

    func riskReason(_ item: Item) -> String {
        switch item.category {
        case .projects:
            if item.lastActivity == nil { return "Not inside a project — check what installed it" }
            if item.detail == "Python venv" { return "Packages must be reinstalled; can fail without a requirements file" }
            if !isStale(item) { return "Project changed recently — you'd reinstall before the next run" }
            return item.detail == "node_modules" ? "Rebuilt by npm install" : "Rebuilt by the next build"
        case .models:
            if item.recommended { return "The model was already removed; these files are orphaned" }
            if item.detail.hasPrefix("Model file in") { return "May be custom or not re-downloadable" }
            return "Re-downloads on next use (\(formatBytes(item.bytes)))"
        case .duplicates: return "Becomes an APFS clone; every path keeps working"
        case .caches: return item.recommended ? "Refills automatically when needed" : "Quit the app first; it rebuilds on next launch"
        case .downloads: return item.recommended ? "Installer — download it again if needed" : "Your file — may not exist anywhere else"
        case .agents: return "Its program is gone; it only fails at every login"
        }
    }

    func items(in category: Category) -> [Item] { items.filter { $0.category == category } }
    func items(at risk: Risk) -> [Item] { items.filter { self.risk($0) == risk } }
    func total(_ items: [Item]) -> Int64 { items.reduce(0) { $0 + $1.bytes } }

    /// The largest wins: project junk grouped, installers grouped, everything else ≥ 1 GB individually.
    var levers: [Lever] {
        var levers: [Lever] = []
        func sum(_ items: [Item]) -> Int64 { items.reduce(0) { $0 + $1.bytes } }
        let projects = items(in: .projects)
        let stale = projects.filter { risk($0) == .safe }
        if !stale.isEmpty {
            levers.append(Lever(title: "Build folders in \(Set(stale.map(\.title)).count) projects untouched for \(staleDays)+ days",
                                detail: "node_modules, .next, .build, target — rebuilt on the next install or build",
                                bytes: sum(stale), risk: .safe, category: .projects))
        }
        let venvs = projects.filter { $0.detail == "Python venv" }
        if !venvs.isEmpty {
            levers.append(Lever(title: "\(venvs.count) Python venvs", detail: "Packages need reinstalling before the project runs again",
                                bytes: sum(venvs), risk: .caution, category: .projects))
        }
        let active = projects.filter { risk($0) == .caution && $0.detail != "Python venv" }
        if !active.isEmpty {
            levers.append(Lever(title: "Build folders in \(Set(active.map(\.title)).count) recently used projects",
                                detail: "Rebuildable, but you are working on these", bytes: sum(active), risk: .caution, category: .projects))
        }
        let installers = items(in: .downloads).filter(\.recommended)
        if !installers.isEmpty {
            levers.append(Lever(title: "\(installers.count) installers in Downloads", detail: installers.map(\.title).joined(separator: ", "),
                                bytes: sum(installers), risk: .safe, category: .downloads))
        }
        for item in items where item.bytes >= 1 << 30 && item.category != .projects && !(item.category == .downloads && item.recommended) {
            levers.append(Lever(title: item.title, detail: riskReason(item), bytes: item.bytes, risk: risk(item), category: item.category))
        }
        return Array(levers.sorted { $0.bytes > $1.bytes }.prefix(12))
    }
}
