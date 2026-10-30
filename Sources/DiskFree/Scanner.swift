import Foundation

/// Finds cleanable things. Read-only: nothing here modifies the disk.
struct Scanner {
    var report: (String) -> Void = { _ in }

    struct Artifact { let path: String; let project: String; let kind: String }
    struct BigFile { let path: String; let size: Int64 }

    // Top-level home folders that never hold projects, or that sync to the cloud (deleting there deletes everywhere).
    static let skippedTopLevel: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public",
                                               "Google Drive", "Dropbox", "OneDrive"]
    static let packageExtensions: Set<String> = ["app", "framework", "bundle", "photoslibrary", "xcarchive", "mlpackage",
                                                 "mlmodelc", "fcpbundle", "logicx", "imovielibrary", "rtfd", "pkg"]
    static let modelExtensions: Set<String> = ["safetensors", "ckpt", "pt", "pth", "bin", "gguf", "onnx", "h5", "npz"]
    static let minModelFile: Int64 = 200 << 20
    static let minLooseModel: Int64 = 1 << 30
    static let minCache: Int64 = 100 << 20
    static let minDownload: Int64 = 200 << 20
    /// st_flags bit for iCloud files that are not downloaded; reading them would trigger a download.
    static let datalessFlag: UInt32 = 0x4000_0000

    func scanAll() -> [Item] {
        report("Scanning project folders…")
        let (artifacts, looseModels) = walkHome()
        report("Measuring \(artifacts.count) build folders…")
        var items = projectItems(artifacts)

        report("Scanning AI models…")
        let (models, modelFiles) = modelItems()
        items += models

        report("Comparing large model files…")
        let duplicates = duplicateItems(modelFiles + looseModels)
        items += duplicates
        let duplicatePaths = Set(duplicates.map(\.path) + duplicates.compactMap {
            if case .cloneFrom(let keeper) = $0.action { keeper } else { nil }
        })
        items += looseModels
            .filter { $0.size >= Self.minLooseModel && !duplicatePaths.contains($0.path) }
            .map { Item(category: .models, path: $0.path, title: lastComponent($0.path),
                        detail: "Model file in \(tildePath(parentPath($0.path)))", bytes: $0.size,
                        lastActivity: modificationTime($0.path).map(Date.init(timeIntervalSince1970:))) }

        report("Scanning caches…")
        items += cacheItems()
        report("Scanning Downloads…")
        items += downloadItems()
        items += agentItems()

        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: Projects

    func artifactKind(_ name: String, at path: String) -> String? {
        let parent = parentPath(path)
        switch name {
        case "node_modules": return "node_modules"
        case ".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache", ".angular": return name
        case ".build": return exists(parent + "/Package.swift") ? "SwiftPM .build" : nil
        case "target": return exists(parent + "/Cargo.toml") ? "Rust target" : nil
        case "Pods": return exists(parent + "/Podfile") ? "CocoaPods" : nil
        default: return exists(path + "/pyvenv.cfg") ? "Python venv" : nil
        }
    }

    /// One pass over the home folder: collects build artifacts (without descending into them)
    /// and large model files lying around in projects.
    func walkHome() -> ([Artifact], [BigFile]) {
        var artifacts: [Artifact] = []
        var models: [BigFile] = []
        var folders = 0
        walk(homePath, maxDepth: 8) { entry in
            guard entry.level > 0 else { return .descend }
            let path = entry.path
            let name = lastComponent(path)
            switch entry.info {
            case FTS_D:
                if entry.level == 1 && (name.hasPrefix(".") || Self.skippedTopLevel.contains(name)
                    || name.hasPrefix("iCloud") || name.hasPrefix("Creative Cloud Files")) { return .skip }
                if name == ".git" || Self.packageExtensions.contains((name as NSString).pathExtension.lowercased()) { return .skip }
                if let kind = artifactKind(name, at: path) {
                    artifacts.append(Artifact(path: path, project: parentPath(path), kind: kind))
                    return .skip
                }
                folders += 1
                if folders % 5000 == 0 { report("Scanning project folders… \(folders.formatted()) checked") }
            case FTS_F:
                if let st = entry.st, Int64(st.st_size) >= Self.minModelFile, st.st_flags & Self.datalessFlag == 0,
                   Self.modelExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    models.append(BigFile(path: path, size: Int64(st.st_size)))
                }
            default: break
            }
            return .descend
        }
        return (artifacts, models)
    }

    static let ignoredForActivity: Set<String> = ["node_modules", ".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache",
                                                  ".angular", ".build", "target", "Pods", "__pycache__", ".git", ".DS_Store"]

    /// When the project's own files last changed, ignoring build output and Finder's .DS_Store writes.
    func lastActivity(_ project: String) -> Date? {
        guard project != homePath else { return nil }
        var newest: Double = 0
        var visited = 0
        walk(project, maxDepth: 5) { entry in
            guard entry.level > 0 else { return .descend }
            visited += 1
            if visited > 20_000 || Self.ignoredForActivity.contains(lastComponent(entry.path)) { return .skip }
            if entry.info == FTS_D { return exists(entry.path + "/pyvenv.cfg") ? .skip : .descend }
            if entry.info == FTS_F, let st = entry.st { newest = max(newest, Double(st.st_mtimespec.tv_sec)) }
            return .descend
        }
        for file in ["/.git/index", "/.git/HEAD", "/.git/FETCH_HEAD", "/.git/logs/HEAD"] {
            if let m = modificationTime(project + file) { newest = max(newest, m) }
        }
        return newest > 0 ? Date(timeIntervalSince1970: newest) : nil
    }

    func projectItems(_ artifacts: [Artifact]) -> [Item] {
        let projects = Array(Set(artifacts.map(\.project)))
        let activity = Dictionary(uniqueKeysWithValues: zip(projects, concurrentMap(projects, lastActivity)))
        let sizes = concurrentMap(artifacts) { allocatedSize($0.path) }
        return zip(artifacts, sizes).compactMap { artifact, size in
            guard size >= 1 << 20 else { return nil }
            return Item(category: .projects, path: artifact.path, title: tildePath(artifact.project),
                        detail: artifact.kind, bytes: size, lastActivity: activity[artifact.project] ?? nil)
        }
    }

    // MARK: Models

    /// Model caches as one item per model, plus their big files for duplicate detection.
    /// "org/name" from a Hugging Face cache folder name like "models--org--name".
    func repoName(_ folder: String) -> String {
        let name = folder.split(separator: "--", maxSplits: 1).last.map(String.init) ?? folder
        return name.replacingOccurrences(of: "--", with: "/")
    }

    /// Newer huggingface_hub versions keep large files in hub/blobs/<xx>/<sha256>, with a .refs file listing the
    /// repo blobs that symlink to it. Returns the pool files used by exactly one repo (keyed by repo folder),
    /// and the files whose repos have all been deleted.
    func sharedBlobs(_ hub: String) -> (owned: [String: [String]], orphaned: [String: [String]]) {
        var owned: [String: [String]] = [:], orphaned: [String: [String]] = [:]
        let pool = hub + "/blobs"
        for shard in children(pool) where !shard.hasPrefix(".") {
            for name in children(pool + "/" + shard) where name.hasSuffix(".refs") {
                let blob = pool + "/" + shard + "/" + name.dropLast(".refs".count)
                guard exists(blob), let refs = try? String(contentsOfFile: blob + ".refs", encoding: .utf8) else { continue }
                let repos = Set(refs.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: "/").first.map(String.init) })
                let files = [blob, blob + ".refs", blob + ".lock"].filter(exists)
                let living = repos.filter { exists(hub + "/" + $0) }
                if living.isEmpty, let repo = repos.sorted().first {
                    orphaned[repo, default: []] += files
                } else if living.count == 1 {
                    owned[living.first!, default: []] += files
                }
            }
        }
        return (owned, orphaned)
    }

    func modelItems() -> ([Item], [BigFile]) {
        var targets: [(path: String, title: String, detail: String, extras: [String])] = []
        let hub = homePath + "/.cache/huggingface/hub"
        let shared = sharedBlobs(hub)
        for name in children(hub) {
            for (prefix, kind) in [("models--", "Hugging Face model"), ("datasets--", "Hugging Face dataset"),
                                   ("spaces--", "Hugging Face space")] where name.hasPrefix(prefix) {
                targets.append((hub + "/" + name, repoName(name), kind, shared.owned[name] ?? []))
            }
        }
        for (repo, files) in shared.orphaned.sorted(by: { $0.key < $1.key }) {
            targets.append((files[0], repoName(repo), "Leftover Hugging Face files — the model itself was already deleted",
                            Array(files.dropFirst())))
        }
        for root in [homePath + "/.cache/lm-studio/models", homePath + "/.lmstudio/models"] {
            for publisher in children(root) where !publisher.hasPrefix(".") {
                for model in children(root + "/" + publisher) where !model.hasPrefix(".") {
                    targets.append((root + "/" + publisher + "/" + model, publisher + "/" + model, "LM Studio model", []))
                }
            }
        }
        for root in [homePath + "/.cache/whisper", homePath + "/.cache/whisper-cpp"] {
            for file in children(root) where !file.hasPrefix(".") {
                targets.append((root + "/" + file, file, "Whisper model", []))
            }
        }

        let measured = concurrentMap(targets) { target -> (Int64, Date?, [BigFile]) in
            var files: [BigFile] = []
            for path in [target.path] + target.extras {
                walk(path) { entry in
                    if entry.info == FTS_F, let st = entry.st, Int64(st.st_size) >= Self.minModelFile {
                        files.append(BigFile(path: entry.path, size: Int64(st.st_size)))
                    }
                    return .descend
                }
            }
            let size = ([target.path] + target.extras).reduce(0) { $0 + allocatedSize($1) }
            return (size, newestModification(target.path, maxDepth: 3), files)
        }
        let items = zip(targets, measured).compactMap { target, m -> Item? in
            guard m.0 >= 1 << 20 else { return nil }
            return Item(category: .models, path: target.path, title: target.title, detail: target.detail,
                        bytes: m.0, lastActivity: m.1, recommended: target.detail.hasPrefix("Leftover"),
                        extraPaths: target.extras)
        }
        return (items, measured.flatMap(\.2))
    }

    /// "org/name" for a Hugging Face blob, the file name otherwise.
    func displayName(_ path: String) -> String {
        if let range = path.range(of: "/hub/models--"), let end = path.range(of: "/", range: range.upperBound..<path.endIndex) {
            return path[range.upperBound..<end.lowerBound].replacingOccurrences(of: "--", with: "/") + " (HF blob)"
        }
        return lastComponent(path)
    }

    func duplicateItems(_ files: [BigFile]) -> [Item] {
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.path).inserted }
        var items: [Item] = []
        for group in Dictionary(grouping: unique, by: \.size).values where group.count > 1 {
            let hashes = concurrentMap(group) { sampleHash($0.path, size: $0.size) }
            var byHash: [String: [BigFile]] = [:]
            for (file, hash) in zip(group, hashes) { if let hash { byHash[hash, default: []].append(file) } }
            for copies in byHash.values where copies.count > 1 {
                // Keep the copy in a model cache; the extra copies in projects become clones of it.
                let sorted = copies.sorted { ($0.path.contains("/.cache/") ? 0 : 1, $0.path) < ($1.path.contains("/.cache/") ? 0 : 1, $1.path) }
                let keeper = sorted[0]
                for copy in sorted.dropFirst() {
                    if sameInode(copy.path, keeper.path) { continue }
                    if let unshared = privateSize(copy.path), unshared < copy.size / 2 { continue }  // already a clone
                    items.append(Item(category: .duplicates, path: copy.path, title: displayName(copy.path),
                                      detail: "\(tildePath(parentPath(copy.path))) — same as \(tildePath(keeper.path))",
                                      bytes: copy.size,
                                      lastActivity: modificationTime(copy.path).map(Date.init(timeIntervalSince1970:)),
                                      action: .cloneFrom(keeper.path), recommended: true))
                }
            }
        }
        return items
    }

    // MARK: Caches

    static let modelCaches: Set<String> = ["huggingface", "lm-studio", "whisper", "whisper-cpp"]
    static let packageCaches: Set<String> = ["uv", "pip", "pnpm", "Homebrew", "Yarn", "yarn", "electron", "ms-playwright",
                                             "node-gyp", "pypoetry", "go-build", "prisma", "puppeteer", "bun", "deno",
                                             "typescript", "org.swift.swiftpm", "_cacache", "_npx", "DerivedData"]

    func isPackageCache(_ name: String) -> Bool {
        Self.packageCaches.contains(name) || name.contains("ShipIt") || name.hasSuffix("-updater")
    }

    func cacheItems() -> [Item] {
        var targets: [(path: String, title: String, kind: String, recommended: Bool)] = []
        func add(_ path: String, _ title: String, recommended: Bool? = nil) {
            let name = lastComponent(path)
            let package = recommended ?? isPackageCache(name)
            targets.append((path, title, package ? "Package cache" : "App cache", package))
        }
        let dotCache = homePath + "/.cache"
        for name in children(dotCache) where !Self.modelCaches.contains(name) { add(dotCache + "/" + name, "~/.cache/" + name) }
        for name in children(dotCache + "/huggingface") where !["hub", "token", "stored_tokens"].contains(name) {
            add(dotCache + "/huggingface/" + name, "~/.cache/huggingface/" + name, recommended: false)
        }
        let libraryCaches = homePath + "/Library/Caches"
        for name in children(libraryCaches) where !name.hasPrefix("com.apple.") {
            add(libraryCaches + "/" + name, name)
        }
        for name in ["_cacache", "_npx"] { add(homePath + "/.npm/" + name, "npm " + name) }
        add(homePath + "/Library/Developer/Xcode/DerivedData", "Xcode DerivedData")
        add(homePath + "/Library/Developer/CoreSimulator/Caches", "Simulator caches", recommended: true)
        add(homePath + "/Library/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport", recommended: false)

        let present = targets.filter { exists($0.path) }
        let sizes = concurrentMap(present) { allocatedSize($0.path) }
        return zip(present, sizes).compactMap { target, size in
            guard size >= Self.minCache else { return nil }
            return Item(category: .caches, path: target.path, title: target.title, detail: target.kind, bytes: size,
                        lastActivity: modificationTime(target.path).map(Date.init(timeIntervalSince1970:)),
                        recommended: target.recommended)
        }
    }

    // MARK: Downloads

    static let installerExtensions: Set<String> = ["dmg", "pkg", "iso", "xip", "mpkg"]

    func downloadItems() -> [Item] {
        let root = homePath + "/Downloads"
        let entries = children(root).filter { !$0.hasPrefix(".") }.map { root + "/" + $0 }
        let sizes = concurrentMap(entries, allocatedSize)
        return zip(entries, sizes).compactMap { path, size in
            guard size >= Self.minDownload else { return nil }
            let added = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
            let ext = (path as NSString).pathExtension.lowercased()
            return Item(category: .downloads, path: path, title: lastComponent(path),
                        detail: Self.installerExtensions.contains(ext) ? "Installer" : "Added to Downloads",
                        bytes: size,
                        lastActivity: added ?? modificationTime(path).map(Date.init(timeIntervalSince1970:)),
                        recommended: Self.installerExtensions.contains(ext))
        }
    }

    // MARK: Launch agents

    static let interpreters: Set<String> = ["sh", "bash", "zsh", "env", "python", "python3", "node", "ruby", "perl", "osascript"]

    /// The program (or interpreted script) a launch agent runs, if it has disappeared.
    func missingProgram(_ arguments: [String]) -> String? {
        guard let program = arguments.first else { return nil }
        func gone(_ path: String) -> String? {
            let expanded = (path as NSString).expandingTildeInPath
            return (path.hasPrefix("/") || path.hasPrefix("~/")) && !exists(expanded) ? expanded : nil
        }
        if let missing = gone(program) { return missing }
        guard Self.interpreters.contains(lastComponent(program)) else { return nil }
        var skipNext = false
        for argument in arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if argument == "-c" || argument == "-e" { skipNext = true; continue }
            if argument.hasPrefix("-") { continue }
            return gone(argument)  // the first operand is the script
        }
        return nil
    }

    func agentItems() -> [Item] {
        let directory = homePath + "/Library/LaunchAgents"
        return children(directory).filter { $0.hasSuffix(".plist") }.compactMap { name in
            let path = directory + "/" + name
            guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
            var arguments = plist["ProgramArguments"] as? [String] ?? []
            if let program = plist["Program"] as? String { arguments.insert(program, at: 0) }
            guard let missing = missingProgram(arguments) else { return nil }
            let label = plist["Label"] as? String ?? String(name.dropLast(".plist".count))
            return Item(category: .agents, path: path, title: label,
                        detail: "Runs \(tildePath(missing)), which no longer exists",
                        bytes: allocatedSize(path),
                        lastActivity: modificationTime(path).map(Date.init(timeIntervalSince1970:)),
                        action: .unloadAgent(label), recommended: true)
        }
    }
}
