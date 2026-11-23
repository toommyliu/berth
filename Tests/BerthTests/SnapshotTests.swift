import Foundation
import Testing
@testable import Berth

struct SnapshotTests {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)

    func makeVM() throws -> VM {
        let url = root.appending(path: "vms/test", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"cpuCount": 4, "memorySize": 8589934592}"#.utf8).write(to: url.appending(path: "config.json"))
        try Data(repeating: 1, count: 1 << 20).write(to: url.appending(path: "disk.img"))
        return try #require(Bundles.scan(url.deletingLastPathComponent(), shelf: .tart).first)
    }

    @Test func revertRestoresSnapshotAndSavesCurrentState() throws {
        let store = SnapshotStore(root: root.appending(path: "snapshots"))
        let vm = try makeVM()
        let disk = vm.url.appending(path: "disk.img")

        try store.take(vm, name: "clean")
        #expect(store.list("test").map(\.name) == ["clean"])
        #expect(store.list("test")[0].uniqueSize == 0)

        try Data(repeating: 2, count: 1 << 20).write(to: disk)
        try store.revert(vm, to: store.list("test")[0])

        #expect(try Data(contentsOf: disk) == Data(repeating: 1, count: 1 << 20))
        let snapshots = store.list("test")
        #expect(Set(snapshots.map(\.name)) == ["clean", "Before reverting to clean"])
        let saved = try #require(snapshots.first { $0.name == "Before reverting to clean" })
        #expect(try Data(contentsOf: saved.bundle.appending(path: "disk.img")) == Data(repeating: 2, count: 1 << 20))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "vms/.test.revert").path))

        try store.delete(saved)
        #expect(store.list("test").map(\.name) == ["clean"])
        try FileManager.default.removeItem(at: root)
    }
}
