import Foundation

enum Category: String, CaseIterable, Identifiable {
    case projects, models, duplicates, caches, downloads, agents

    var id: Self { self }

    var title: String {
        switch self {
        case .projects: "Stale project junk"
        case .models: "AI models"
        case .duplicates: "Duplicate model files"
        case .caches: "Caches"
        case .downloads: "Large downloads"
        case .agents: "Orphaned background agents"
        }
    }

    var symbol: String {
        switch self {
        case .projects: "shippingbox"
        case .models: "cpu"
        case .duplicates: "doc.on.doc"
        case .caches: "archivebox"
        case .downloads: "arrow.down.circle"
        case .agents: "gearshape.2"
        }
    }

    var blurb: String {
        switch self {
        case .projects:
            "node_modules, Python venvs, SwiftPM/Rust build folders and framework caches. All of it is rebuilt by npm install, pip install or a fresh build."
        case .models:
            "Downloaded models from Hugging Face, LM Studio and Whisper, plus big model files inside project folders. They download again on next use."
        case .duplicates:
            "Byte-identical model files stored more than once. DiskFree replaces each extra copy with an APFS clone: every path keeps working, but the data is stored only once."
        case .caches:
            "Package-manager and app caches. Package caches refill on demand; quit an app before removing its cache."
        case .downloads:
            "Files and folders over 200 MB in ~/Downloads. Installers (.dmg, .pkg, .iso) are preselected."
        case .agents:
            "Login agents in ~/Library/LaunchAgents whose program no longer exists. DiskFree unloads them and removes the plist."
        }
    }
}

enum Risk: Int, CaseIterable, Identifiable, Comparable {
    case safe, caution, review

    var id: Self { self }
    static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .safe: "Risk-free"
        case .caution: "Small risk"
        case .review: "Check yourself"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .review: "eye.fill"
        }
    }

    var explanation: String {
        switch self {
        case .safe:
            "Rebuilt or re-downloaded automatically, or already orphaned. Deleting costs nothing beyond a reinstall or download the next time something needs it."
        case .caution:
            "Comes back, but costs time: a multi-GB model download, reinstalling a Python venv, or a cold app cache. Glance over it before cleaning."
        case .review:
            "Your own files. DiskFree can't tell whether you still need them, so decide item by item."
        }
    }
}

enum CleanAction: Hashable {
    case trash
    case cloneFrom(String)
    case unloadAgent(String)
}

struct Item: Identifiable, Hashable {
    let category: Category
    let path: String
    let title: String
    let detail: String
    let bytes: Int64
    let lastActivity: Date?
    var action: CleanAction = .trash
    var recommended = false
    /// Removed together with `path`, e.g. shared Hugging Face blobs only this model uses.
    var extraPaths: [String] = []

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var activityKey: Double { lastActivity?.timeIntervalSince1970 ?? 0 }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
