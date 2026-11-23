import Foundation

enum TartError: LocalizedError {
    case notInstalled
    case failed(command: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "tart isn't installed."
        case let .failed(command, message): "`tart \(command)` failed: \(message)"
        }
    }
}

enum Tart {
    static let executable: URL? = ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"]
        .map { URL(filePath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    static let home: URL = ProcessInfo.processInfo.environment["TART_HOME"]
        .map { URL(filePath: $0, directoryHint: .isDirectory) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".tart", directoryHint: .isDirectory)

    static let vmsDirectory = home.appending(path: "vms", directoryHint: .isDirectory)

    private struct Listed: Decodable {
        let Name: String
        let Running: Bool
    }

    static func runningVMs() throws -> Set<String> {
        let data = try run(["list", "--source", "local", "--format", "json"])
        let listed = try JSONDecoder().decode([Listed].self, from: data)
        return Set(listed.filter(\.Running).map(\.Name))
    }

    static func set(_ name: String, cpus: Int, memoryMB: Int64) throws {
        _ = try run(["set", name, "--cpu", String(cpus), "--memory", String(memoryMB)])
    }

    static func stop(_ name: String) throws {
        _ = try run(["stop", name])
    }

    static func start(_ name: String, onExit: @escaping @Sendable (Error?) -> Void) throws {
        guard let executable else { throw TartError.notInstalled }
        let process = Process()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.terminationHandler = { process in
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            onExit(process.terminationStatus == 0 ? nil : TartError.failed(
                command: "run \(name)", message: message.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        try process.run()
    }

    private static func run(_ arguments: [String]) throws -> Data {
        guard let executable else { throw TartError.notInstalled }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let message = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TartError.failed(
                command: arguments.joined(separator: " "),
                message: String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
