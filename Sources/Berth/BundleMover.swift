import Foundation

enum MoveError: LocalizedError {
    case destinationExists(URL)
    case notEnoughSpace(needed: Int64, available: Int64)
    case unexpectedEntry(URL)

    var errorDescription: String? {
        switch self {
        case let .destinationExists(url):
            "\(url.path) already exists."
        case let .notEnoughSpace(needed, available):
            "The destination needs \(needed.formatted(.byteCount(style: .file))) but has \(available.formatted(.byteCount(style: .file))) free."
        case let .unexpectedEntry(url):
            "\(url.lastPathComponent) in the VM bundle isn't a regular file."
        }
    }
}

enum BundleMover {
    static func move(
        _ source: URL, to destination: URL, progress: @Sendable (_ done: Int64, _ total: Int64) -> Void
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { throw MoveError.destinationExists(destination) }
        if rename(source.path, destination.path) == 0 { return }
        guard errno == EXDEV else { throw posixError() }

        let staging = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).partial", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        let plan = try planCopy(source)
        let total = plan.reduce(0) { $0 + $1.bytes }
        let available = Bundles.volume(containing: destination.deletingLastPathComponent())?.available ?? 0
        guard available >= total else { throw MoveError.notEnoughSpace(needed: total, available: available) }

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            try copy(plan, into: staging, total: total, progress: progress)
            guard rename(staging.path, destination.path) == 0 else { throw posixError() }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        try fm.removeItem(at: source)
    }

    struct FilePlan {
        let url: URL
        let ranges: [Range<Int64>]
        var bytes: Int64 { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
    }

    static func planCopy(_ bundle: URL) throws -> [FilePlan] {
        try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.isRegularFileKey])
            .map { url in
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw MoveError.unexpectedEntry(url)
                }
                let fd = open(url.path, O_RDONLY)
                guard fd >= 0 else { throw posixError() }
                defer { close(fd) }
                return FilePlan(url: url, ranges: try dataRanges(fd))
            }
    }

    static func copy(
        _ plan: [FilePlan], into directory: URL, total: Int64,
        progress: @Sendable (_ done: Int64, _ total: Int64) -> Void
    ) throws {
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        var done: Int64 = 0
        var lastReport = ContinuousClock.now
        for file in plan {
            let src = open(file.url.path, O_RDONLY)
            guard src >= 0 else { throw posixError() }
            defer { close(src) }
            var info = stat()
            guard fstat(src, &info) == 0 else { throw posixError() }
            let dst = open(directory.appending(path: file.url.lastPathComponent).path,
                           O_WRONLY | O_CREAT | O_EXCL, info.st_mode & 0o7777)
            guard dst >= 0 else { throw posixError() }
            defer { close(dst) }
            guard ftruncate(dst, info.st_size) == 0 else { throw posixError() }

            for range in file.ranges {
                var offset = range.lowerBound
                while offset < range.upperBound {
                    try Task.checkCancellation()
                    let count = Int(min(Int64(chunk), range.upperBound - offset))
                    try transfer(count, at: offset, from: src, to: dst, buffer: buffer)
                    offset += Int64(count)
                    done += Int64(count)
                    if ContinuousClock.now - lastReport > .milliseconds(100) {
                        progress(done, total)
                        lastReport = .now
                    }
                }
            }
            var times = [info.st_atimespec, info.st_mtimespec]
            guard futimens(dst, &times) == 0, fsync(dst) == 0 else { throw posixError() }
        }
        progress(done, total)
    }

    private static func transfer(
        _ count: Int, at offset: Int64, from src: Int32, to dst: Int32, buffer: UnsafeMutableRawPointer
    ) throws {
        var read = 0
        while read < count {
            let n = pread(src, buffer + read, count - read, offset + Int64(read))
            guard n > 0 else { throw n == 0 ? POSIXError(.EIO) : posixError() }
            read += n
        }
        var written = 0
        while written < count {
            let n = pwrite(dst, buffer + written, count - written, offset + Int64(written))
            guard n >= 0 else { throw posixError() }
            written += n
        }
    }

    static func dataRanges(_ fd: Int32) throws -> [Range<Int64>] {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        var ranges: [Range<Int64>] = []
        var position: off_t = 0
        while position < info.st_size {
            let start = lseek(fd, position, SEEK_DATA)
            if start < 0 {
                if errno == ENXIO { break }
                throw posixError()
            }
            let end = lseek(fd, start, SEEK_HOLE)
            guard end >= 0 else { throw posixError() }
            ranges.append(start..<end)
            position = end
        }
        return ranges
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
