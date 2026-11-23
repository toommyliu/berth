import Foundation

struct Snapshot: Identifiable, Hashable, Sendable {
    let id: String
    let vmName: String
    let name: String
    let created: Date
    let url: URL
    let uniqueSize: Int64

    var bundle: URL { url.appending(path: "vm", directoryHint: .isDirectory) }
}

enum SnapshotError: LocalizedError {
    case cloneFailed(String)

    var errorDescription: String? {
        switch self {
        case let .cloneFailed(reason): "Couldn't clone the VM: \(reason). Snapshots need the VM on an APFS volume."
        }
    }
}

struct SnapshotStore: Sendable {
    let root: URL

    static let tart = SnapshotStore(root: Tart.home.appending(path: "berth/snapshots", directoryHint: .isDirectory))

    func directory(for vm: String) -> URL {
        root.appending(path: vm, directoryHint: .isDirectory)
    }

    private struct Info: Codable {
        let name: String
        let created: Date
    }

    func all() -> [String: [Snapshot]] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.filter { !$0.hasPrefix(".") }.map { ($0, list($0)) })
    }

    func list(_ vm: String) -> [Snapshot] {
        let directory = directory(for: vm)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return ids.compactMap { id in
            let url = directory.appending(path: id, directoryHint: .isDirectory)
            guard let data = try? Data(contentsOf: url.appending(path: "info.json")),
                  let info = try? decoder.decode(Info.self, from: data) else { return nil }
            let bundle = url.appending(path: "vm", directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: bundle.path) else { return nil }
            return Snapshot(id: id, vmName: vm, name: info.name, created: info.created, url: url,
                            uniqueSize: uniqueBytes(bundle))
        }
        .sorted { $0.created > $1.created }
    }

    func take(_ vm: VM, name: String) throws {
        let url = directory(for: vm.name).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try clone(vm.url, to: url.appending(path: "vm"))
            try write(Info(name: name, created: .now), to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func revert(_ vm: VM, to snapshot: Snapshot) throws {
        let incoming = vm.url.deletingLastPathComponent()
            .appending(path: ".\(vm.name).revert", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: incoming)
        try clone(snapshot.bundle, to: incoming)
        guard renamex_np(incoming.path, vm.url.path, UInt32(RENAME_SWAP)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: incoming)
            throw error
        }
        let saved = directory(for: vm.name).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: incoming, to: saved.appending(path: "vm"))
        try write(Info(name: "Before reverting to \(snapshot.name)", created: .now), to: saved)
    }

    func delete(_ snapshot: Snapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }

    private func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw SnapshotError.cloneFailed(String(cString: strerror(errno)))
        }
    }

    private func write(_ info: Info, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: url.appending(path: "info.json"))
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func uniqueBytes(_ bundle: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? []
        return files.reduce(0) { $0 + (privateSize(bundle.appending(path: $1).path) ?? 0) }
    }

    private func privateSize(_ path: String) -> Int64? {
        var request = attrlist(
            bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0, volattr: 0,
            dirattr: 0, fileattr: 0, forkattr: attrgroup_t(ATTR_CMNEXT_PRIVATESIZE))
        var buffer = [UInt8](repeating: 0, count: 16)
        let result = buffer.withUnsafeMutableBytes {
            getattrlist(path, &request, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: Int64.self) }
    }
}
