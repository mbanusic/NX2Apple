import XCTest
@testable import NXCore

/// A mod built from the player's own game files (LNPANDY/NX2Apple#1133): the recipe, the RomFS image reader and the build.
final class ModRecipeTests: XCTestCase {
    private var temporary: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("ModRecipeTests-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: temporary) }

    private func write(_ path: String, _ text: String, in root: URL? = nil) throws {
        let url = (root ?? temporary).appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// An image in the layout of dm/tools/romfs_image.py: directories breadth-first, each one's children consecutive and sorted.
    private func image(_ files: [String: String]) throws -> URL {
        final class Node { var children: [String: Node] = [:]; var data: Data? }
        let root = Node()
        for (path, text) in files {
            var n = root
            for part in path.split(separator: "/").map(String.init) { n = n.children[part] ?? { let c = Node(); n.children[part] = c; return c }() }
            n.data = Data(text.utf8)
        }
        var order: [(name: String, node: Node)] = [("", root)]
        var firstChild: [Int: Int] = [:]
        var i = 0
        while i < order.count {
            let kids = order[i].node.children.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
            if order[i].node.data == nil { firstChild[i] = order.count; order += kids.map { ($0.key, $0.value) } }
            i += 1
        }
        var body = Data(), index = Data(), pool = Data()
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var offset: UInt64 = 32
        for (k, e) in order.enumerated() {
            let isDir = e.node.data == nil
            let a: UInt64 = isDir ? UInt64(firstChild[k]!) : offset
            let b: UInt64 = isDir ? UInt64(e.node.children.count) : UInt64(e.node.data!.count)
            if !isDir { body += e.node.data!; offset += b }
            index += le(a) + le(b) + le(UInt32(pool.count)) + le(UInt16(e.name.utf8.count)) + Data([isDir ? 0 : 1, 0])
            pool += Data(e.name.utf8)
        }
        let all = index + pool
        let url = temporary.appendingPathComponent("RomFS-\(UUID().uuidString).img")
        try (Data("DMROMFS1".utf8) + le(offset) + le(UInt64(all.count)) + le(UInt64(order.count)) + body + all).write(to: url)
        return url
    }

    private static let gameFiles = ["Pack/ZsDic.pack.zs": "dic", "Mals/EUen.Product.110.sarc.zs": "en", "Mals/JPja.Product.110.sarc.zs": "ja",
                                    "Model/Link.bfres.zs": "model", "System/RegionLangMask.txt": "EUen JPja"]

    func testTheReaderCopiesFilesAndWholeFolders() throws {
        let img = try image(Self.gameFiles)
        let out = temporary.appendingPathComponent("game")
        XCTAssertEqual(try RomFSImageReader(url: img).extract(["Pack/ZsDic.pack.zs", "Mals"], to: out), 3)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Pack/ZsDic.pack.zs"), encoding: .utf8), "dic")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Mals/JPja.Product.110.sarc.zs"), encoding: .utf8), "ja")
        XCTAssertFalse(fm.fileExists(atPath: out.appendingPathComponent("Model").path), "only what was asked for")
        XCTAssertThrowsError(try RomFSImageReader(url: img).extract(["Mals/KRko.Product.110.sarc.zs"], to: out)) {
            XCTAssertEqual($0 as? RomFSImageReader.Problem, .missing("Mals/KRko.Product.110.sarc.zs"))
        }
        try write("plain.bin", "not an image")
        XCTAssertThrowsError(try RomFSImageReader(url: temporary.appendingPathComponent("plain.bin")))
    }

    /// The engine's own packer, when the engine tree is there: the reader and romfs_image.py agree on the format.
    func testTheReaderReadsAnImageTheEnginePacked() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tool = repo.appendingPathComponent("engine/dm/tools/romfs_image.py")
        guard fm.fileExists(atPath: tool.path) else { throw XCTSkip("no engine tree (python3 tools/engine.py sync)") }
        let src = temporary.appendingPathComponent("romfs")
        for (path, text) in Self.gameFiles { try write(path, text, in: src) }
        let img = temporary.appendingPathComponent("packed.img")
        let result = SystemProcessRunner().capture(ProcessLaunch(["/usr/bin/env", "python3", tool.path, src.path, img.path], mergesErrors: true))
        guard result.ok else { throw XCTSkip("romfs_image.py did not run: \(result.out)") }
        let out = temporary.appendingPathComponent("game")
        XCTAssertEqual(try RomFSImageReader(url: img).extract(["Mals", "System/RegionLangMask.txt"], to: out), 3)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Mals/EUen.Product.110.sarc.zs"), encoding: .utf8), "en")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("System/RegionLangMask.txt"), encoding: .utf8), "EUen JPja")
    }

    func testARecipeIsReadAndChecked() throws {
        let mod = temporary.appendingPathComponent("Hrvatski")
        XCTAssertNil(try ModRecipe.read(in: mod), "a folder without the file is an ordinary mod")
        try write("Hrvatski/mals_po.py", "")
        try write("Hrvatski/nx2apple-mod.json", #"{"needs": ["Pack/ZsDic.pack.zs", "Mals"], "build": ["mals_po.py", "build", "{game}", "EUen", "hr.json", "{out}"]}"#)
        let recipe = try XCTUnwrap(try ModRecipe.read(in: mod))
        XCTAssertEqual(recipe.command(python: "/py", mod: mod, game: URL(fileURLWithPath: "/g"), out: URL(fileURLWithPath: "/o")),
                       ["/py", mod.appendingPathComponent("mals_po.py").path, "build", "/g", "EUen", "hr.json", "/o"])
        for (json, why) in [(#"{"needs": [], "build": ["mals_po.py", "{out}"]}"#, "names no RomFS path"),
                            (#"{"needs": ["../x"], "build": ["mals_po.py", "{out}"]}"#, "not a path inside the RomFS"),
                            (#"{"needs": ["/Mals"], "build": ["mals_po.py", "{out}"]}"#, "not a path inside the RomFS"),
                            (#"{"needs": ["Mals"], "build": ["/bin/sh", "{out}"]}"#, "not a Python script"),
                            (#"{"needs": ["Mals"], "build": ["../evil.py", "{out}"]}"#, "not a Python script"),
                            (#"{"needs": ["Mals"], "build": ["other.py", "{out}"]}"#, "has no other.py"),
                            (#"{"needs": ["Mals"], "build": ["mals_po.py", "build"]}"#, "({out})"),
                            (#"{"needs": "Mals"}"#, "nx2apple-mod.json")] {
            try write("Hrvatski/nx2apple-mod.json", json)
            XCTAssertThrowsError(try ModRecipe.read(in: mod), json) { error in
                switch error as? ModRecipe.Problem {
                case .invalid(let text), .unreadable(let text): XCTAssertTrue(text.contains(why), "\(json): \(text)")
                case nil: XCTFail("\(error)")
                }
            }
        }
    }

    func testTheGameImageIsTheMacAppsElseTheNewestExtractedVersion() throws {
        let build = temporary.appendingPathComponent("0400486024DEC000_build")
        XCTAssertNil(ModBuild.gameImage(appPath: "", buildFolders: [build.path]))
        try write("0400486024DEC000_build/extract/v65536/RomFS.img", "old")
        try write("0400486024DEC000_build/extract/v131072/RomFS.img", "new")
        try write("0400486024DEC000_build/extract/vtmp/RomFS.img", "not a version")
        XCTAssertEqual(ModBuild.gameImage(appPath: "", buildFolders: ["", build.path])?.lastPathComponent, "RomFS.img")
        XCTAssertEqual(ModBuild.gameImage(appPath: "", buildFolders: [build.path])?.deletingLastPathComponent().lastPathComponent, "v131072")
        try write("Game.app/Contents/Resources/romfs.img", "app")
        XCTAssertEqual(ModBuild.gameImage(appPath: temporary.appendingPathComponent("Game.app").path, buildFolders: [build.path])?.lastPathComponent, "romfs.img")
    }

    private func recipeMod() throws -> (URL, ModRecipe) {
        try write("Hrvatski/mals_po.py", "")
        try write("Hrvatski/nx2apple-mod.json", #"{"needs": ["Mals"], "build": ["mals_po.py", "build", "{game}", "{out}"]}"#)
        let mod = temporary.appendingPathComponent("Hrvatski")
        return (mod, try XCTUnwrap(try ModRecipe.read(in: mod)))
    }

    func testABuildCopiesTheNeedsRunsTheScriptAndKeepsItsFilesAsTheRomFS() throws {
        let (mod, recipe) = try recipeMod()
        let img = try image(Self.gameFiles)
        let runner = FakeProcessRunner()
        runner.answer = { launch in
            // The script sees the game's files under {game} and writes under {out}, from the mod's folder
            let game = URL(fileURLWithPath: launch.arguments[2]), out = URL(fileURLWithPath: launch.arguments[3])
            let en = (try? String(contentsOf: game.appendingPathComponent("Mals/EUen.Product.110.sarc.zs"), encoding: .utf8)) ?? "?"
            try? FileManager.default.createDirectory(at: out.appendingPathComponent("Mals"), withIntermediateDirectories: true)
            try? Data("hr from \(en)".utf8).write(to: out.appendingPathComponent("Mals/EUen.Product.110.sarc.zs"))
            return ProcessResult(out: "20620 translated entries\n")
        }
        try write("Hrvatski/romfs/stale.bin", "from an earlier build")
        try ModBuild.run(recipe, mod: mod, image: img, python: "/py", scratch: temporary.appendingPathComponent("scratch"), runner: runner)
        XCTAssertEqual(runner.launches.first?.executable, "/py")
        XCTAssertEqual(runner.launches.first?.directory, mod.path)
        XCTAssertEqual(try String(contentsOf: mod.appendingPathComponent("romfs/Mals/EUen.Product.110.sarc.zs"), encoding: .utf8), "hr from en")
        XCTAssertFalse(fm.fileExists(atPath: mod.appendingPathComponent("romfs/stale.bin").path), "the new build replaces the old one")
        let log = try String(contentsOf: mod.appendingPathComponent(ModBuild.logName), encoding: .utf8)
        XCTAssertTrue(log.contains("copied 2 files: Mals") && log.contains("20620 translated entries") && log.contains("built "), log)
    }

    func testAFailedBuildKeepsTheOldRomFSAndSaysWhy() throws {
        let (mod, recipe) = try recipeMod()
        try write("Hrvatski/romfs/Mals/EUen.Product.110.sarc.zs", "the last good build")
        let runner = FakeProcessRunner()
        runner.answer = { _ in ProcessResult(status: 1, out: "Traceback ...\nModuleNotFoundError: No module named 'compression'\n") }
        let img = try image(Self.gameFiles), scratch = temporary.appendingPathComponent("scratch")
        XCTAssertThrowsError(try ModBuild.run(recipe, mod: mod, image: img, python: "/py", scratch: scratch, runner: runner)) {
            XCTAssertEqual($0 as? ModBuild.Problem, .script(status: 1, lastLine: "ModuleNotFoundError: No module named 'compression'"))
        }
        XCTAssertEqual(try String(contentsOf: mod.appendingPathComponent("romfs/Mals/EUen.Product.110.sarc.zs"), encoding: .utf8), "the last good build")
        XCTAssertTrue(try String(contentsOf: mod.appendingPathComponent(ModBuild.logName), encoding: .utf8).contains("exit code 1"))

        runner.answer = { _ in ProcessResult() }
        XCTAssertThrowsError(try ModBuild.run(recipe, mod: mod, image: img, python: "/py", scratch: temporary.appendingPathComponent("scratch2"), runner: runner)) {
            XCTAssertEqual($0 as? ModBuild.Problem, .noOutput)
        }
        XCTAssertThrowsError(try ModBuild.run(recipe, mod: mod, image: nil, python: "/py", scratch: scratch, runner: runner)) {
            XCTAssertEqual($0 as? ModBuild.Problem, .noGameFiles)
        }
        let noMals = try image(["Pack/ZsDic.pack.zs": "dic"])
        XCTAssertThrowsError(try ModBuild.run(recipe, mod: mod, image: noMals, python: "/py", scratch: temporary.appendingPathComponent("scratch3"), runner: runner)) {
            XCTAssertEqual($0 as? ModBuild.Problem, .extract("the game's RomFS has no Mals"))
        }
    }
}
