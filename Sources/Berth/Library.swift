import AppKit
import Observation

enum VMState: Equatable {
    case stopped, running, starting, stopping, stashed

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .running: "Running"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .stashed: "Stashed"
        }
    }
}

struct Transfer {
    let name: String
    let destination: Shelf
    var done: Int64 = 0
    var total: Int64 = 0
}

@MainActor
@Observable
final class Library {
    private(set) var vms: [VM] = []
    private(set) var tartVolume: VolumeUsage?
    private(set) var stashVolume: VolumeUsage?
    private(set) var transfer: Transfer?
    private(set) var snapshotsByVM: [String: [Snapshot]] = [:]
    var errorMessage: String?

    private var running: Set<String> = []
    private var pending: [String: VMState] = [:]
    private var transferTask: Task<Void, Error>?

    var stashURL: URL? {
        didSet {
            UserDefaults.standard.set(stashURL?.path, forKey: "stashPath")
            Task { await refresh() }
        }
    }

    init() {
        stashURL = UserDefaults.standard.string(forKey: "stashPath").map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    func state(of vm: VM) -> VMState {
        if vm.shelf == .stash { return .stashed }
        if let pending = pending[vm.name] { return pending }
        return running.contains(vm.name) ? .running : .stopped
    }

    func refresh() async {
        let stash = stashURL
        let scan = await Task.detached {
            (
                running: try? Tart.runningVMs(),
                snapshots: SnapshotStore.tart.all(),
                local: Bundles.scan(Tart.vmsDirectory, shelf: .tart),
                stashed: stash.map { Bundles.scan($0, shelf: .stash) } ?? [],
                tartVolume: Bundles.volume(containing: Tart.vmsDirectory),
                stashVolume: stash.flatMap(Bundles.volume(containing:))
            )
        }.value
        if let running = scan.running {
            self.running = running
            pending = pending.filter { name, state in
                state == .starting ? !running.contains(name) : running.contains(name)
            }
        }
        vms = scan.local + scan.stashed
        tartVolume = scan.tartVolume
        stashVolume = scan.stashVolume
        snapshotsByVM = scan.snapshots
    }

    func start(_ vm: VM) {
        do {
            try Tart.start(vm.name) { error in
                Task { @MainActor in
                    if let error { self.errorMessage = error.localizedDescription }
                    self.pending[vm.name] = nil
                    await self.refresh()
                }
            }
            pending[vm.name] = .starting
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(_ vm: VM) {
        pending[vm.name] = .stopping
        Task {
            do {
                try await Task.detached { try Tart.stop(vm.name) }.value
            } catch {
                errorMessage = error.localizedDescription
                pending[vm.name] = nil
            }
            await refresh()
        }
    }

    func canEdit(_ vm: VM) -> Bool {
        vm.resources != nil && state(of: vm) == .stopped && transfer?.name != vm.name
    }

    func configure(_ vm: VM, cpus: Int, memoryMB: Int64) async {
        do {
            try await Task.detached { try Tart.set(vm.name, cpus: cpus, memoryMB: memoryMB) }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    func canMove(_ vm: VM) -> Bool {
        transfer == nil && stashVolume != nil && [.stopped, .stashed].contains(state(of: vm))
    }

    func move(_ vm: VM) {
        guard canMove(vm), let stashURL else { return }
        if !snapshots(of: vm).isEmpty {
            errorMessage = "Delete \(vm.name)'s snapshots before moving it. They share its disk blocks, so they'd stay behind and keep that space in use."
            return
        }
        let destination: Shelf = vm.shelf == .tart ? .stash : .tart
        let target = (destination == .tart ? Tart.vmsDirectory : stashURL).appending(path: vm.name)
        transfer = Transfer(name: vm.name, destination: destination)
        let work = Task.detached {
            if vm.shelf == .tart, try Tart.runningVMs().contains(vm.name) {
                throw TartError.failed(command: "list", message: "\(vm.name) started running.")
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try BundleMover.move(vm.url, to: target) { done, total in
                Task { @MainActor in
                    self.transfer?.done = done
                    self.transfer?.total = total
                }
            }
        }
        transferTask = work
        Task {
            do {
                try await work.value
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            transfer = nil
            transferTask = nil
            await refresh()
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
    }

    func trash(_ vm: VM) {
        do {
            try FileManager.default.trashItem(at: vm.url, resultingItemURL: nil)
            if !snapshots(of: vm).isEmpty {
                try FileManager.default.trashItem(at: SnapshotStore.tart.directory(for: vm.name), resultingItemURL: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        Task { await refresh() }
    }

    func snapshots(of vm: VM) -> [Snapshot] {
        vm.shelf == .tart ? snapshotsByVM[vm.name] ?? [] : []
    }

    func canSnapshot(_ vm: VM) -> Bool {
        vm.shelf == .tart && state(of: vm) == .stopped && transfer?.name != vm.name
    }

    func takeSnapshot(_ vm: VM, name: String) {
        let name = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? Date.now.formatted(date: .abbreviated, time: .shortened) : name
        whileStopped(vm) { try SnapshotStore.tart.take(vm, name: name) }
    }

    func revert(_ vm: VM, to snapshot: Snapshot) {
        whileStopped(vm) { try SnapshotStore.tart.revert(vm, to: snapshot) }
    }

    func deleteSnapshot(_ snapshot: Snapshot) {
        Task {
            do {
                try await Task.detached { try SnapshotStore.tart.delete(snapshot) }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    private func whileStopped(_ vm: VM, _ work: @escaping @Sendable () throws -> Void) {
        guard canSnapshot(vm) else { return }
        Task {
            do {
                try await Task.detached {
                    if try Tart.runningVMs().contains(vm.name) {
                        throw TartError.failed(command: "list", message: "\(vm.name) started running.")
                    }
                    try work()
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh()
        }
    }

    func reveal(_ vm: VM) {
        NSWorkspace.shared.activateFileViewerSelecting([vm.url])
    }
}
