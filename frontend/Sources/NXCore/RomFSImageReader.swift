import Foundation

/// Files out of a RomFS image (`romfs.img` in a Mac app, `RomFS.img` in a build folder): the format dm/tools/romfs_image.py writes.
/// A 32-byte header ("DMROMFS1", index offset, index size, entry count), the files' bytes, then the index: 24-byte entries
/// (u64 a, u64 b, u32 name offset, u16 name length, u8 type, u8 flags) and the name pool. A directory's a and b are its first
/// child and its number of children, a file's are its offset and size. Entry 0 is the root.
package struct RomFSImageReader {
    package enum Problem: Error, Equatable {
        case notAnImage(String)
        case missing(String)
    }

    private struct Entry { let a: UInt64, b: UInt64, nameOffset: Int, nameLength: Int, isDirectory: Bool }

    package let url: URL
    private let entries: [Entry]
    private let pool: Data

    package init(url: URL) throws {
        self.url = url
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Problem.notAnImage(url.path) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 32)) ?? Data()
        guard head.count == 32, head.prefix(8) == Data("DMROMFS1".utf8) else { throw Problem.notAnImage(url.path) }
        let indexOffset = Self.u64(head, 8), indexSize = Self.u64(head, 16), count = Self.u64(head, 24)
        guard count > 0, indexSize >= count * 24, indexSize < 1 << 32 else { throw Problem.notAnImage(url.path) }
        try handle.seek(toOffset: indexOffset)
        guard let raw = try handle.read(upToCount: Int(indexSize)), raw.count == Int(indexSize) else { throw Problem.notAnImage(url.path) }
        let n = Int(count)
        entries = (0..<n).map { k in
            let o = k * 24
            return Entry(a: Self.u64(raw, o), b: Self.u64(raw, o + 8), nameOffset: Int(Self.u32(raw, o + 16)),
                         nameLength: Int(raw[raw.startIndex + o + 20]) | Int(raw[raw.startIndex + o + 21]) << 8, isDirectory: raw[raw.startIndex + o + 22] == 0)
        }
        pool = raw.subdata(in: raw.startIndex + n * 24 ..< raw.endIndex)
    }

    private static func u64(_ d: Data, _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[d.startIndex + o + $1]) << (8 * UInt64($1)) }
    }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[d.startIndex + o + $1]) << (8 * UInt32($1)) }
    }

    private func name(_ e: Entry) -> String {
        let start = pool.startIndex + e.nameOffset
        guard e.nameOffset + e.nameLength <= pool.count else { return "" }
        return String(decoding: pool[start ..< start + e.nameLength], as: UTF8.self)
    }

    private func children(_ e: Entry) -> Range<Int> {
        let first = Int(min(e.a, UInt64(entries.count))), end = Int(min(e.a + e.b, UInt64(entries.count)))
        return first ..< max(first, end)
    }

    /// The entry of a path (`Mals/EUen.Product.110.sarc.zs`), nil when there is none.
    private func find(_ path: String) -> Int? {
        var k = 0
        for part in path.split(separator: "/") {
            guard entries[k].isDirectory, let next = children(entries[k]).first(where: { name(entries[$0]) == part }) else { return nil }
            k = next
        }
        return k
    }

    /// Copies each path (a file, or a folder with everything under it) to the same path under `folder`. Returns the number of
    /// files written. A path the image does not have throws `missing`.
    @discardableResult
    package func extract(_ paths: [String], to folder: URL, fm: FileManager = .default) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var written = 0
        func copy(_ k: Int, to dst: URL) throws {
            let e = entries[k]
            if e.isDirectory {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                for c in children(e) { try copy(c, to: dst.appendingPathComponent(name(entries[c]))) }
                return
            }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: dst.path, contents: nil)
            let out = try FileHandle(forWritingTo: dst)
            defer { try? out.close() }
            try handle.seek(toOffset: e.a)
            var left = e.b
            while left > 0 {
                let chunk = try handle.read(upToCount: Int(min(left, 8 << 20))) ?? Data()
                guard !chunk.isEmpty else { throw Problem.notAnImage(url.path) }
                try out.write(contentsOf: chunk); left -= UInt64(chunk.count)
            }
            written += 1
        }
        for path in paths {
            guard let k = find(path) else { throw Problem.missing(path) }
            try copy(k, to: folder.appendingPathComponent(path))
        }
        return written
    }
}
