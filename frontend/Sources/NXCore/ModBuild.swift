import Foundation

/// Builds a recipe mod (`ModRecipe`, LNPANDY/NX2Apple#1133) from the player's game: the RomFS paths it needs are copied out of the
/// game's RomFS image into a temporary folder, its script runs with the launcher's Python, and what the script wrote becomes the
/// mod's `romfs/`. The old `romfs/` is replaced only when the script succeeded, and `build.log` in the mod's folder keeps the output.
package enum ModBuild {
    package static let logName = "build.log"

    package enum Problem: Error, Equatable {
        case noGameFiles
        case extract(String)
        case script(status: Int32, lastLine: String)
        case noOutput
    }

    /// The RomFS image of the game: its Mac app's (`Contents/Resources/romfs.img`), else the newest version's in a build folder
    /// (`<title ID>_build/extract/v<version>/RomFS.img`). The Mac app's comes first: it is the one Play starts.
    package static func gameImage(appPath: String, buildFolders: [String], fm: FileManager = .default) -> URL? {
        if !appPath.isEmpty {
            let img = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources/romfs.img")
            if fm.fileExists(atPath: img.path) { return img }
        }
        for folder in buildFolders where !folder.isEmpty {
            let extract = URL(fileURLWithPath: folder).appendingPathComponent("extract")
            let versions = ((try? fm.contentsOfDirectory(atPath: extract.path)) ?? [])
                .filter { $0.hasPrefix("v") && UInt64($0.dropFirst()) != nil }
                .sorted { UInt64($0.dropFirst())! > UInt64($1.dropFirst())! }
            for v in versions {
                let img = extract.appendingPathComponent(v).appendingPathComponent("RomFS.img")
                if fm.fileExists(atPath: img.path) { return img }
            }
        }
        return nil
    }

    /// Builds the mod in `mod` from `image`. `scratch` is an empty temporary folder, removed afterwards by the caller.
    package static func run(_ recipe: ModRecipe, mod: URL, image: URL?, python: String, scratch: URL,
                            runner: ProcessRunner = SystemProcessRunner(), fm: FileManager = .default) throws {
        let log = mod.appendingPathComponent(logName)
        func write(_ text: String) { try? Data(text.utf8).write(to: log) }
        guard let image else { write("no RomFS image of the game: build the game first\n"); throw Problem.noGameFiles }
        let game = scratch.appendingPathComponent("game"), out = scratch.appendingPathComponent("out")
        var text = "game files: \(image.path)\n"
        do {
            let n = try RomFSImageReader(url: image).extract(recipe.needs, to: game, fm: fm)
            text += "copied \(n) files: \(recipe.needs.joined(separator: ", "))\n"
        } catch {
            let reason: String
            switch error {
            case RomFSImageReader.Problem.missing(let path): reason = "the game's RomFS has no \(path)"
            case RomFSImageReader.Problem.notAnImage(let path): reason = "\(path) is not a RomFS image"
            default: reason = error.localizedDescription
            }
            write(text + reason + "\n"); throw Problem.extract(reason)
        }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let command = recipe.command(python: python, mod: mod, game: game, out: out)
        text += "$ " + command.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ") + "\n"
        let result = runner.capture(ProcessLaunch(command, directory: mod.path, mergesErrors: true))
        text += result.out + (result.err.isEmpty ? "" : result.err)
        guard result.ok else {
            let last = (result.out + result.err).split(separator: "\n").last.map(String.init) ?? ""
            write(text + "exit code \(result.status)\n"); throw Problem.script(status: result.status, lastLine: last)
        }
        let made = (try? fm.contentsOfDirectory(atPath: out.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard !made.isEmpty else { write(text + "the script wrote no files\n"); throw Problem.noOutput }
        let romfs = mod.appendingPathComponent("romfs")
        try? fm.removeItem(at: romfs)
        try fm.moveItem(at: out, to: romfs)
        write(text + "built \(romfs.path)\n")
    }
}
