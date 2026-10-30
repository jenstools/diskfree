import AppKit
import SwiftUI

enum Page: Hashable {
    case overview
    case category(Category)
}

extension Risk {
    var color: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .review: .purple
        }
    }
}

struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Label(risk.title, systemImage: risk.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(risk.color)
    }
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @State private var page: Page? = .overview

    var body: some View {
        NavigationSplitView {
            Sidebar(page: $page)
                .navigationSplitViewColumnWidth(min: 260, ideal: 280)
        } detail: {
            switch page {
            case .overview, nil: OverviewView(page: $page)
            case .category(let category): CategoryView(category: category, page: $page).id(category)
            }
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if store.lastScan == nil { store.scan() }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @Binding var page: Page?

    var body: some View {
        List(selection: $page) {
            Section {
                DiskSummary()
            }
            Section {
                Label("Overview", systemImage: "square.grid.2x2").tag(Page.overview)
            }
            Section("Found") {
                ForEach(Category.allCases) { category in
                    HStack {
                        Label(category.title, systemImage: category.symbol)
                        Spacer()
                        Text(countLabel(category)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(Page.category(category))
                }
            }
        }
        .safeAreaInset(edge: .bottom) { TrashFooter() }
    }

    func countLabel(_ category: Category) -> String {
        guard store.lastScan != nil else { return "" }
        if category == .agents { return "\(store.items(in: category).count)" }
        return formatBytes(store.total(category))
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: Store
    @Binding var page: Page?
    @State private var confirmingSafe = false

    var safeItems: [Item] { store.items(at: .safe) }
    var safeBytes: Int64 { safeItems.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let message = store.message {
                    Banner(text: message) { store.message = nil }.padding(.horizontal, -16)
                }
                if store.scanning || store.lastScan == nil {
                    HStack { ProgressView().controlSize(.small); Text(store.status.isEmpty ? "Scanning…" : store.status) }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    headline
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Risk.allCases) { RiskCard(risk: $0, page: $page) }
                    }
                    WeeklyCard()
                    levers
                }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
        .confirmationDialog("Clean all \(safeItems.count) risk-free items (\(formatBytes(safeBytes)))?",
                            isPresented: $confirmingSafe) {
            Button("Move to Trash") { store.clean(safeItems, permanently: false) }
            Button("Delete Permanently", role: .destructive) { store.clean(safeItems, permanently: true) }
        } message: {
            Text("Duplicate model files become APFS clones and dead login agents are unloaded. Everything else goes to the Trash unless you choose Delete Permanently.")
        }
    }

    var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(formatBytes(store.reclaimable)) can be freed — \(formatBytes(safeBytes)) of it risk-free")
                .font(.largeTitle.weight(.bold))
            Text("You have \(formatBytes(store.free)) free of \(formatBytes(store.capacity)). Cleaning the risk-free part alone would bring you to about \(formatBytes(store.free + safeBytes)).")
                .foregroundStyle(.secondary)
            Label("DiskFree never deletes anything on its own. Nothing happens until you click Clean and confirm, and by default everything goes to the Trash first.",
                  systemImage: "hand.raised.fill")
                .font(.callout)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Clean All Risk-Free…") { confirmingSafe = true }
                    .controlSize(.large)
                    .disabled(safeItems.isEmpty || store.busy)
                if store.working {
                    ProgressView().controlSize(.small)
                    Text(store.status).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    var levers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Biggest levers").font(.title2.weight(.semibold))
            ForEach(Array(store.levers.enumerated()), id: \.element.id) { index, lever in
                HStack(spacing: 12) {
                    Text("\(index + 1)").font(.title3.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lever.title).lineLimit(1).truncationMode(.middle)
                        Text(lever.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                    RiskBadge(risk: lever.risk).frame(width: 120, alignment: .leading)
                    Text(formatBytes(lever.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Button("Show") { page = .category(lever.category) }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }
}

struct WeeklyCard: View {
    @EnvironmentObject var store: Store
    @State private var draft = Schedule.Config()

    var enabled: Binding<Bool> {
        Binding(get: { store.schedule != nil }, set: { store.setSchedule($0 ? draft : nil) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Weekly report", systemImage: "calendar.badge.clock").font(.headline)
                Spacer()
                Toggle("", isOn: enabled).toggleStyle(.switch).labelsHidden()
            }
            Text("A read-only scan once a week. You get a notification and a report with what you can do to free space. Nothing is ever deleted by it.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Picker("Every", selection: $draft.weekday) {
                    ForEach(1...7, id: \.self) { Text(Schedule.weekdays[$0]!).tag($0) }
                }
                .fixedSize()
                Picker("at", selection: $draft.hour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .fixedSize()
                Spacer()
                Button("Create Report Now") { store.reportNow() }.disabled(store.lastScan == nil || store.busy)
            }
            if let latest = store.latestReport {
                HStack {
                    Text("Last report \(latest.summary.date.formatted(.relative(presentation: .named))): \(formatBytes(latest.summary.total)) could be freed, \(formatBytes(latest.summary.safe)) risk-free.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open") { NSWorkspace.shared.open(latest.markdown) }.buttonStyle(.link)
                    Button("All Reports") { NSWorkspace.shared.open(URL(fileURLWithPath: WeeklyReport.directory)) }.buttonStyle(.link)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .onAppear {
            store.reloadWeekly()
            if let schedule = store.schedule { draft = schedule }
        }
        .onChange(of: draft) { _, config in
            if store.schedule != nil { store.setSchedule(config) }
        }
    }
}

struct RiskCard: View {
    @EnvironmentObject var store: Store
    let risk: Risk
    @Binding var page: Page?

    var items: [Item] { store.items(at: risk) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(risk.title, systemImage: risk.symbol).font(.headline).foregroundStyle(risk.color)
            Text(formatBytes(items.reduce(0) { $0 + $1.bytes })).font(.title.weight(.semibold)).monospacedDigit()
            Text(risk.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(Category.allCases) { category in
                let inCategory = items.filter { $0.category == category }
                if !inCategory.isEmpty {
                    Button {
                        page = .category(category)
                    } label: {
                        HStack {
                            Text(category.title)
                            Spacer()
                            Text(category == .agents ? "\(inCategory.count)" : formatBytes(inCategory.reduce(0) { $0 + $1.bytes }))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(risk.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(risk.color.opacity(0.25)))
    }
}

struct DiskSummary: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(formatBytes(store.free)) free").font(.title2.weight(.semibold))
            ProgressView(value: Double(max(store.capacity - store.free, 0)), total: Double(max(store.capacity, 1)))
                .tint(store.lowOnSpace ? .red : .accentColor)
            Text("of \(formatBytes(store.capacity))").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(store.scanning ? "Scanning…" : (store.lastScan == nil ? "Scan" : "Rescan")) { store.scan() }
                    .disabled(store.busy)
                if let lastScan = store.lastScan {
                    Text("\(formatBytes(store.reclaimable)) found · \(lastScan.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct TrashFooter: View {
    @EnvironmentObject var store: Store
    @State private var confirming = false

    var body: some View {
        if store.trashedBytes > 0 {
            HStack {
                Image(systemName: "trash")
                VStack(alignment: .leading) {
                    Text("\(formatBytes(store.trashedBytes)) in Trash")
                    Text("moved there by DiskFree").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Empty") { confirming = true }.disabled(store.busy)
            }
            .padding(10)
            .background(.bar)
            .confirmationDialog("Permanently delete \(formatBytes(store.trashedBytes)) that DiskFree moved to the Trash?",
                                isPresented: $confirming) {
                Button("Delete Permanently", role: .destructive) { store.emptyTrash() }
            } message: {
                Text("Other files in your Trash are not touched.")
            }
        }
    }
}

struct CategoryView: View {
    @EnvironmentObject var store: Store
    let category: Category
    @Binding var page: Page?
    @State private var sortOrder = [KeyPathComparator(\Item.bytes, order: .reverse)]
    @State private var confirming = false

    var rows: [Item] { store.items(in: category).sorted(using: sortOrder) }
    var selected: [Item] { store.selected(in: category) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let message = store.message {
                Banner(text: message) { store.message = nil }
            }
            if store.scanning {
                Spacer()
                HStack { Spacer(); ProgressView(); Text(store.status).foregroundStyle(.secondary); Spacer() }
                Spacer()
            } else if rows.isEmpty {
                Spacer()
                Text(store.lastScan == nil ? "Not scanned yet" : "Nothing found here")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                table
            }
            footer
        }
        .navigationTitle(category.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    page = .overview
                } label: {
                    Label("Overview", systemImage: "chevron.left")
                }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Overview (⌘[)")
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.blurb).foregroundStyle(.secondary).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if category == .projects {
                    Picker("Preselect projects untouched for", selection: $store.staleDays) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("6 months").tag(180)
                        Text("1 year").tag(365)
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Select Risk-Free") { store.selectRecommended(in: category) }
                Button("Select None") { store.selectNone(in: category) }
            }
            .disabled(store.busy || rows.isEmpty)
        }
        .padding()
    }

    var table: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: store.binding(for: item.id)).toggleStyle(.checkbox).labelsHidden()
            }
            .width(22)
            TableColumn("Name", value: \.title) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .help(item.path)
            }
            TableColumn("Risk") { item in
                VStack(alignment: .leading, spacing: 2) {
                    RiskBadge(risk: store.risk(item))
                    Text(store.riskReason(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                .help(store.riskReason(item))
            }
            .width(min: 150, ideal: 230)
            TableColumn(category == .projects ? "Last change" : "Modified", value: \.activityKey) { item in
                Text(item.lastActivity?.formatted(.relative(presentation: .named)) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Size", value: \.bytes) { item in
                Text(formatBytes(item.bytes)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("") { item in
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            .width(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var footer: some View {
        HStack {
            if store.working {
                ProgressView().controlSize(.small)
                Text(store.status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("\(selected.count) selected · \(formatBytes(selected.reduce(0) { $0 + $1.bytes }))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button(actionTitle) { confirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || store.busy)
        }
        .padding()
        .background(.bar)
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            if category == .duplicates {
                Button("Replace with Clones") { store.clean(selected, permanently: false) }
            } else {
                Button("Move to Trash") { store.clean(selected, permanently: false) }
                Button("Delete Permanently", role: .destructive) { store.clean(selected, permanently: true) }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    var actionTitle: String {
        switch category {
        case .duplicates: "Deduplicate…"
        case .agents: "Unload & Remove…"
        default: "Clean…"
        }
    }

    var confirmTitle: String {
        let size = formatBytes(selected.reduce(0) { $0 + $1.bytes })
        switch category {
        case .duplicates: return "Replace \(selected.count) duplicate files (\(size)) with APFS clones?"
        case .agents: return "Unload and remove \(selected.count) launch agents?"
        default: return "Remove \(selected.count) items (\(size))?"
        }
    }

    var confirmMessage: String {
        switch category {
        case .duplicates: "Each file is compared byte for byte first. All paths keep working."
        case .agents: "They are stopped with launchctl, then their plist is removed."
        default: "Moving to the Trash frees no space until you empty it; DiskFree can empty just its own items."
        }
    }
}

struct Banner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "info.circle")
            Text(text).textSelection(.enabled).lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(formatBytes(store.free)) free of \(formatBytes(store.capacity))")
        if store.lastScan != nil { Text("\(formatBytes(store.reclaimable)) found to clean") }
        if store.trashedBytes > 0 { Text("\(formatBytes(store.trashedBytes)) waiting in Trash") }
        Divider()
        Button("Open DiskFree…") { open() }
        Button(store.scanning ? "Scanning…" : "Scan Now") { store.scan(); open() }.disabled(store.busy)
        Divider()
        Button("Quit DiskFree") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
