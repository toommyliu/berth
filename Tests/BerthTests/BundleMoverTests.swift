import Foundation
import Testing
@testable import Berth

struct BundleMoverTests {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let payload = Data((0..<(4 << 20)).map { UInt8($0 % 251) })
    let config = Data(#"{"cpuCount": 4, "cpuCountMin": 2, "memorySize": 8589934592, "memorySizeMin": 4294967296}"#.utf8)

    func makeBundle(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try config.write(to: url.appending(path: "config.json"))
        let disk = url.appending(path: "disk.img")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 1 << 30)
        try handle.seek(toOffset: 512 << 20)
        try handle.write(contentsOf: payload)
        try handle.close()
    }

    @Test func copyKeepsContentsAndHoles() throws {
        let source = root.appending(path: "vm")
        let copy = root.appending(path: "copy")
        try makeBundle(source)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)

        let plan = try BundleMover.planCopy(source)
        try BundleMover.copy(plan, into: copy, total: plan.reduce(0) { $0 + $1.bytes }) { _, _ in }

        let disk = copy.appending(path: "disk.img")
        let values = try disk.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        #expect(values.fileSize == 1 << 30)
        #expect(values.totalFileAllocatedSize! < 64 << 20)
        let handle = try FileHandle(forReadingFrom: disk)
        #expect(try handle.read(upToCount: 4096) == Data(count: 4096))
        try handle.seek(toOffset: 512 << 20)
        #expect(try handle.read(upToCount: payload.count) == payload)
        #expect(try Data(contentsOf: copy.appending(path: "config.json")) == config)
        try FileManager.default.removeItem(at: root)
    }

    @Test func refusesExistingDestination() throws {
        let source = root.appending(path: "vm")
        let taken = root.appending(path: "taken")
        try makeBundle(source)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)

        #expect(throws: MoveError.self) { try BundleMover.move(source, to: taken) { _, _ in } }
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "disk.img").path))
        try FileManager.default.removeItem(at: root)
    }

    @Test func scanReportsAllocatedSize() throws {
        try makeBundle(root.appending(path: "vm"))
        let vms = Bundles.scan(root, shelf: .stash)
        #expect(vms.map(\.name) == ["vm"])
        #expect(vms[0].diskSize == 1 << 30)
        #expect(vms[0].used < 64 << 20)
        #expect(vms[0].resources == Resources(cpus: 4, minCPUs: 2, memory: 8 << 30, minMemory: 4 << 30))
        try FileManager.default.removeItem(at: root)
    }
}
