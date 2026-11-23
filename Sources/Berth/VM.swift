import Foundation

enum Shelf: String, Sendable {
    case tart = "Tart"
    case stash = "Stash"
}

struct VM: Identifiable, Hashable, Sendable {
    let name: String
    let shelf: Shelf
    let url: URL
    let used: Int64
    let diskSize: Int64
    let lastUsed: Date
    let resources: Resources?
    let os: GuestOS

    var id: URL { url }
}

enum GuestOS: Sendable {
    case macOS, linux, unknown

    var label: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .unknown: "VM"
        }
    }

    var symbol: String {
        switch self {
        case .macOS: "macwindow"
        case .linux: "terminal"
        case .unknown: "shippingbox"
        }
    }
}

struct Resources: Hashable, Sendable {
    let cpus: Int
    let minCPUs: Int
    let memory: Int64
    let minMemory: Int64
}

struct VolumeUsage: Sendable {
    let name: String
    let capacity: Int64
    let available: Int64

    var usedFraction: Double {
        capacity > 0 ? Double(capacity - available) / Double(capacity) : 0
    }
}

enum Bundles {
    static func scan(_ directory: URL, shelf: Shelf) -> [VM] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { load(directory.appending(path: $0, directoryHint: .isDirectory), shelf: shelf) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func load(_ url: URL, shelf: Shelf) -> VM? {
        guard FileManager.default.fileExists(atPath: url.appending(path: "config.json").path) else { return nil }
        let disk = try? url.appending(path: "disk.img")
            .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let bundleDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let config = (try? Data(contentsOf: url.appending(path: "config.json")))
            .flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        let os: GuestOS = switch config?.os {
        case "darwin": .macOS
        case "linux": .linux
        default: .unknown
        }
        return VM(
            name: url.lastPathComponent,
            shelf: shelf,
            url: url,
            used: allocatedBytes(url),
            diskSize: Int64(disk?.fileSize ?? 0),
            lastUsed: disk?.contentModificationDate ?? bundleDate ?? .distantPast,
            resources: config.map {
                Resources(cpus: $0.cpuCount, minCPUs: $0.cpuCountMin ?? 1,
                          memory: $0.memorySize, minMemory: $0.memorySizeMin ?? 1 << 30)
            },
            os: os
        )
    }

    private struct Config: Decodable {
        let cpuCount: Int
        let cpuCountMin: Int?
        let memorySize: Int64
        let memorySizeMin: Int64?
        let os: String?
    }

    private static func allocatedBytes(_ bundle: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: bundle, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        return files.reduce(0) { total, file in
            let size = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
            return total + Int64(size ?? 0)
        }
    }

    static func volume(containing url: URL) -> VolumeUsage? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]) else { return nil }
        let available = max(
            values.volumeAvailableCapacityForImportantUsage ?? 0,
            Int64(values.volumeAvailableCapacity ?? 0))
        return VolumeUsage(
            name: values.volumeName ?? url.path,
            capacity: Int64(values.volumeTotalCapacity ?? 0),
            available: available)
    }
}
