import SwiftUI

enum SortKey: String, CaseIterable {
    case name = "Name"
    case used = "Size"
    case lastUsed = "Last Used"

    func sorted(_ vms: [VM]) -> [VM] {
        switch self {
        case .name: vms.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .used: vms.sorted { $0.used > $1.used }
        case .lastUsed: vms.sorted { $0.lastUsed > $1.lastUsed }
        }
    }
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var selection: VM.ID?
    @AppStorage("sort") private var sort = SortKey.name
    @State private var pendingTrash: VM?
    @State private var editing: VM?
    @State private var showSnapshots = true
    @State private var selectedOnLaunch = false

    private var selected: VM? {
        library.vms.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if Tart.executable == nil {
                ContentUnavailableView(
                    "tart isn't installed", systemImage: "shippingbox",
                    description: Text("Install it with `brew install cirruslabs/cli/tart`."))
            } else {
                list
            }
        }
        .overlay(alignment: .bottom) { StatusBar().padding(12) }
        .inspector(isPresented: $showSnapshots) {
            SnapshotsPanel(vm: selected)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar { toolbar }
        .task {
            while !Task.isCancelled {
                await library.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } }),
            presenting: library.errorMessage
        ) { _ in
        } message: { Text($0) }
        .confirmationDialog(
            "Move “\(pendingTrash?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { vm in
            Button("Move to Trash", role: .destructive) { library.trash(vm) }
        } message: { vm in
            let count = library.snapshots(of: vm).count
            let snapshots = count == 0 ? "" : " Its \(count) snapshot\(count == 1 ? "" : "s") go to the Trash too."
            Text("This frees \(vm.used.formatted(.byteCount(style: .file))) once you empty the Trash.\(snapshots)")
        }
        .sheet(item: $editing) { vm in
            if let resources = vm.resources {
                EditSheet(vm: vm, resources: resources)
            }
        }
    }

    private var ordered: [VM] {
        [Shelf.tart, .stash].flatMap { shelf in sort.sorted(library.vms.filter { $0.shelf == shelf }) }
    }

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach([Shelf.tart, .stash], id: \.self) { shelf in
                    let vms = sort.sorted(library.vms.filter { $0.shelf == shelf })
                    if !vms.isEmpty {
                        Text(shelf.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, shelf == .tart ? 4 : 14)
                        ForEach(vms) { vm in
                            VMRow(vm: vm, state: library.state(of: vm), snapshots: library.snapshots(of: vm).count,
                                  selected: vm.id == selection)
                                .contentShape(.rect(cornerRadius: 12))
                                .gesture(TapGesture(count: 2).onEnded {
                                    if library.canEdit(vm) { editing = vm }
                                })
                                .simultaneousGesture(TapGesture().onEnded { selection = vm.id })
                                .contextMenu { actions(for: vm) }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 80)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onChange(of: library.vms) {
            guard !selectedOnLaunch, let first = ordered.first else { return }
            selectedOnLaunch = true
            selection = first.id
        }
        .overlay {
            if library.vms.isEmpty {
                ContentUnavailableView("No VMs", systemImage: "shippingbox",
                                       description: Text("Create one with `tart create` or `tart clone`."))
            }
        }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let vms = ordered
        guard !vms.isEmpty else { return .ignored }
        let current = vms.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : vms.count)
        selection = vms[min(max(current + offset, 0), vms.count - 1)].id
        return .handled
    }

    @ViewBuilder
    private func actions(for vm: VM) -> some View {
        switch library.state(of: vm) {
        case .stopped:
            Button("Start", systemImage: "play.fill") { library.start(vm) }
        case .running:
            Button("Stop", systemImage: "stop.fill") { library.stop(vm) }
        case .starting, .stopping, .stashed:
            EmptyView()
        }
        Button(vm.shelf == .tart ? "Move to Stash" : "Move to Tart",
               systemImage: vm.shelf == .tart ? "archivebox" : "tray.and.arrow.down") { library.move(vm) }
            .disabled(!library.canMove(vm))
        Button("Edit CPU and Memory…", systemImage: "slider.horizontal.3") { editing = vm }
            .disabled(!library.canEdit(vm))
        Button("Show in Finder", systemImage: "folder") { library.reveal(vm) }
        Divider()
        Button("Move to Trash…", systemImage: "trash") { pendingTrash = vm }
            .disabled(![.stopped, .stashed].contains(library.state(of: vm)) || library.transfer?.name == vm.name)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let vm = selected {
            let state = library.state(of: vm)
            ToolbarItemGroup {
                if state == .running || state == .stopping {
                    Button("Stop", systemImage: "stop.fill") { library.stop(vm) }
                        .disabled(state == .stopping)
                } else {
                    Button("Start", systemImage: "play.fill") { library.start(vm) }
                        .disabled(state != .stopped)
                }
                Button("Edit CPU and Memory…", systemImage: "slider.horizontal.3") { editing = vm }
                    .disabled(!library.canEdit(vm))
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button(vm.shelf == .tart ? "Move to Stash" : "Move to Tart",
                       systemImage: vm.shelf == .tart ? "archivebox" : "tray.and.arrow.down") { library.move(vm) }
                    .disabled(!library.canMove(vm))
                Button("Move to Trash…", systemImage: "trash") { pendingTrash = vm }
                    .disabled(![.stopped, .stashed].contains(state) || library.transfer?.name == vm.name)
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                Picker("Sort By", selection: $sort) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Toggle("Snapshots", systemImage: "clock.arrow.circlepath", isOn: $showSnapshots)
        }
    }
}

private struct VMRow: View {
    let vm: VM
    let state: VMState
    let snapshots: Int
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VMIcon(vm: vm, state: state)

            VStack(alignment: .leading, spacing: 3) {
                Text(vm.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 3) {
                    Text(vm.used.formatted(.byteCount(style: .file))).fontWeight(.medium)
                    Text("of \(vm.diskSize.formatted(.byteCount(style: .file)))").foregroundStyle(.secondary)
                }
                .font(.callout)
                .monospacedDigit()
                ProgressView(value: Double(vm.used), total: Double(max(vm.diskSize, vm.used, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 130)
                    .tint(state == .stashed ? .blue : .accentColor)
            }
            .help("\(vm.used.formatted(.byteCount(style: .file))) on disk of a \(vm.diskSize.formatted(.byteCount(style: .file))) virtual disk")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.accentColor.opacity(0.18)) }
        if hovering { return AnyShapeStyle(.quaternary.opacity(0.5)) }
        return AnyShapeStyle(.quaternary.opacity(0.22))
    }

    private var details: String {
        var parts = [state.label]
        if let resources = vm.resources {
            parts.append("\(resources.cpus) CPUs")
            parts.append(resources.memory.formatted(.byteCount(style: .memory)))
        }
        if snapshots > 0 {
            parts.append("\(snapshots) snapshot\(snapshots == 1 ? "" : "s")")
        }
        parts.append("used \(vm.lastUsed.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }
}

private struct VMIcon: View {
    let vm: VM
    let state: VMState
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: vm.os.symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: size * 0.24))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(state.color)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
                    .offset(x: 3, y: 3)
            }
    }
}

private extension VMState {
    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping: .orange
        case .stopped: .gray
        case .stashed: .blue
        }
    }
}

private struct StatusBar: View {
    @Environment(Library.self) private var library

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if let transfer = library.transfer {
                    TransferPill(transfer: transfer) { library.cancelTransfer() }
                        .glassEffect(.regular, in: .capsule)
                        .transition(.blurReplace)
                }
                HStack(spacing: 14) {
                    shelfSummary(.tart, volume: library.tartVolume)
                    Divider().frame(height: 14)
                    stashSummary
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .animation(.smooth, value: library.transfer == nil)
    }

    @ViewBuilder
    private var stashSummary: some View {
        if library.stashURL == nil {
            Button("Choose Stash Folder…", action: chooseStash)
                .buttonStyle(.link)
        } else if library.stashVolume == nil {
            HStack(spacing: 6) {
                Text("**Stash** folder not found").foregroundStyle(.secondary)
                Button("Change…", action: chooseStash).buttonStyle(.link)
            }
        } else {
            HStack(spacing: 6) {
                shelfSummary(.stash, volume: library.stashVolume)
                Button("Change…", action: chooseStash).buttonStyle(.link)
            }
        }
    }

    private func shelfSummary(_ shelf: Shelf, volume: VolumeUsage?) -> some View {
        let vms = library.vms.filter { $0.shelf == shelf }
        let used = vms.reduce(0) { $0 + $1.used }.formatted(.byteCount(style: .file))
        return HStack(spacing: 8) {
            Text(shelf.rawValue).fontWeight(.semibold)
            Text("\(used) in \(vms.count) VM\(vms.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            if let volume {
                Gauge(value: volume.usedFraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .frame(width: 44)
                    .tint(volume.usedFraction > 0.9 ? .red : .accentColor)
                Text("\(volume.available.formatted(.byteCount(style: .file))) free")
                    .foregroundStyle(.secondary)
            }
        }
        .help(volume.map { "\($0.name): \($0.available.formatted(.byteCount(style: .file))) free" } ?? "")
    }

    private func chooseStash() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Stash"
        panel.message = "Choose where stashed VMs are kept, such as a folder on an external drive."
        if panel.runModal() == .OK, let url = panel.url {
            library.stashURL = url
        }
    }
}

private struct TransferPill: View {
    let transfer: Transfer
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Moving \(transfer.name) to \(transfer.destination.rawValue)")
                    .font(.callout.weight(.medium))
                ProgressView(value: Double(transfer.done), total: Double(max(transfer.total, 1)))
                    .frame(width: 240)
                Text("\(transfer.done.formatted(.byteCount(style: .file))) of \(transfer.total.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Cancel", systemImage: "xmark", action: cancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }
}

private struct SnapshotsPanel: View {
    let vm: VM?
    @Environment(Library.self) private var library
    @State private var naming = false
    @State private var newName = ""
    @State private var pendingRevert: Snapshot?
    @State private var pendingDelete: Snapshot?

    var body: some View {
        if let vm, vm.shelf == .tart {
            content(vm)
        } else if vm != nil {
            ContentUnavailableView("Stashed", systemImage: "archivebox",
                                   description: Text("Move this VM back to Tart to take or restore snapshots."))
        } else {
            ContentUnavailableView("No VM Selected", systemImage: "clock.arrow.circlepath",
                                   description: Text("Select a VM to see its snapshots."))
        }
    }

    private func content(_ vm: VM) -> some View {
        let snapshots = library.snapshots(of: vm)
        let canSnapshot = library.canSnapshot(vm)
        return List {
            Section {
                ForEach(snapshots) { snapshot in
                    SnapshotRow(snapshot: snapshot, canRevert: canSnapshot,
                                revert: { pendingRevert = snapshot }, delete: { pendingDelete = snapshot })
                }
            } header: {
                Text("Snapshots of \(vm.name)")
            }
        }
        .overlay {
            if snapshots.isEmpty {
                ContentUnavailableView(
                    "No Snapshots", systemImage: "clock.arrow.circlepath",
                    description: Text("A snapshot saves \(vm.name) as it is now. It takes no extra space until the VM changes."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button {
                    newName = ""
                    naming = true
                } label: {
                    Label("Take Snapshot", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canSnapshot)
                if !canSnapshot {
                    Text("Stop \(vm.name) to take or revert snapshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .alert("Take Snapshot of \(vm.name)", isPresented: $naming) {
            TextField("Name", text: $newName, prompt: Text(Date.now.formatted(date: .abbreviated, time: .shortened)))
            Button("Take Snapshot") { library.takeSnapshot(vm, name: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give it a name you'll recognize, like “Before Xcode update”.")
        }
        .confirmationDialog(
            "Revert \(vm.name) to “\(pendingRevert?.name ?? "")”?",
            isPresented: Binding(get: { pendingRevert != nil }, set: { if !$0 { pendingRevert = nil } }),
            presenting: pendingRevert
        ) { snapshot in
            Button("Revert") { library.revert(vm, to: snapshot) }
        } message: { _ in
            Text("Its current state is saved as a new snapshot first, so you can undo this.")
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { snapshot in
            Button("Delete Snapshot", role: .destructive) { library.deleteSnapshot(snapshot) }
        } message: { snapshot in
            Text("This frees \(snapshot.uniqueSize.formatted(.byteCount(style: .file))) and can't be undone.")
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: Snapshot
    let canRevert: Bool
    let revert: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(snapshot.created.formatted(.relative(presentation: .named))) · \(size)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help("\(snapshot.created.formatted(date: .complete, time: .shortened))\nSpace only this snapshot uses: \(size)")
            Spacer(minLength: 0)
            if hovering {
                Button("Delete", systemImage: "trash", action: delete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .transition(.opacity)
            }
            Button("Revert", systemImage: "arrow.uturn.backward", action: revert)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(!canRevert)
                .help("Revert to this snapshot")
        }
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button("Revert…", systemImage: "arrow.uturn.backward", action: revert).disabled(!canRevert)
            Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    private var size: String {
        snapshot.uniqueSize == 0 ? "No extra space" : snapshot.uniqueSize.formatted(.byteCount(style: .file))
    }
}

private struct EditSheet: View {
    let vm: VM
    let resources: Resources
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var cpus: Int
    @State private var memoryGB: Int
    @State private var saving = false
    private let initialMemoryGB: Int

    private static let gib: Int64 = 1 << 30
    private let hostCPUs = ProcessInfo.processInfo.processorCount
    private let hostMemoryGB = Int(Int64(ProcessInfo.processInfo.physicalMemory) / gib)

    init(vm: VM, resources: Resources) {
        self.vm = vm
        self.resources = resources
        let memoryGB = max(Int((resources.memory + Self.gib / 2) / Self.gib), Self.minMemoryGB(resources))
        initialMemoryGB = memoryGB
        _cpus = State(initialValue: resources.cpus)
        _memoryGB = State(initialValue: memoryGB)
    }

    private static func minMemoryGB(_ resources: Resources) -> Int {
        Int((resources.minMemory + gib - 1) / gib)
    }

    private var changed: Bool {
        cpus != resources.cpus || memoryGB != initialMemoryGB
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                VMIcon(vm: vm, state: .stopped, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.name).font(.title3.weight(.semibold))
                    Text("\(vm.os.label) · changes apply the next time it starts")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 12) {
                ResourceCard(
                    title: "CPUs", symbol: "cpu", value: $cpus,
                    range: resources.minCPUs...max(hostCPUs, resources.cpus),
                    format: { "\($0)" }, unit: "cores",
                    warning: cpus == hostCPUs ? "Uses every core on your Mac." : nil)
                ResourceCard(
                    title: "Memory", symbol: "memorychip", value: $memoryGB,
                    range: Self.minMemoryGB(resources)...max(hostMemoryGB, initialMemoryGB),
                    format: { "\($0)" }, unit: "GB",
                    warning: memoryGB * 4 > hostMemoryGB * 3
                        ? "Leaves \(max(hostMemoryGB - memoryGB, 0)) GB for macOS and your apps." : nil)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        await library.configure(vm, cpus: cpus, memoryMB: Int64(memoryGB) * 1024)
                        dismiss()
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!changed || saving)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct ResourceCard: View {
    let title: String
    let symbol: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let format: (Int) -> String
    let unit: String
    let warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(format(value))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(value)))
                    Text(unit)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            slider
                .labelsHidden()
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14))
        .animation(.snappy(duration: 0.2), value: value)
        .animation(.easeOut(duration: 0.15), value: warning)
    }

    @ViewBuilder
    private var slider: some View {
        let binding = Binding(get: { Double(value) }, set: { value = Int($0.rounded()) })
        let bounds = Double(range.lowerBound)...Double(range.upperBound)
        let low = Text(format(range.lowerBound)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        let high = Text(format(range.upperBound)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        if range.count <= 16 {
            Slider(value: binding, in: bounds, step: 1) { Text(title) } minimumValueLabel: { low } maximumValueLabel: { high }
        } else {
            Slider(value: binding, in: bounds) { Text(title) } minimumValueLabel: { low } maximumValueLabel: { high }
        }
    }
}
