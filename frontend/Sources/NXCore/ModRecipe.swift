import Foundation

/// A mod built from the player's own game files (LNPANDY/NX2Apple#1133): `nx2apple-mod.json` in the mod's folder. A fan translation
/// cannot ship the game's archives, so it ships its text and a script, and the launcher runs the script on the player's RomFS:
///
///     {"needs": ["Pack/ZsDic.pack.zs", "Mals"],
///      "build": ["mals_po.py", "build", "{game}", "EUen", "hr.json", "{out}", "--as", "USen", "--as", "EUen"]}
///
/// `needs` are RomFS paths (files or folders) copied out of the game's RomFS into `{game}`. `build[0]` is a Python script in the
/// mod's folder, run with the launcher's Python from that folder; `{out}` is where it writes the files that replace the game's,
/// which become the mod's `romfs/`.
package struct ModRecipe: Equatable, Decodable {
    package static let fileName = "nx2apple-mod.json"
    package var needs: [String]
    package var build: [String]

    package enum Problem: Error, Equatable {
        case unreadable(String)
        case invalid(String)
    }

    /// nil when the folder has no recipe. A recipe that cannot be used throws, with the reason in words.
    package static func read(in mod: URL, fm: FileManager = .default) throws -> ModRecipe? {
        let file = mod.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: file.path) else { return nil }
        let recipe: ModRecipe
        do { recipe = try JSONDecoder().decode(ModRecipe.self, from: Data(contentsOf: file)) }
        catch { throw Problem.unreadable("\(fileName): \(error.localizedDescription)") }
        try recipe.validate(in: mod, fm: fm)
        return recipe
    }

    /// A path that stays inside its folder: relative, no `..` and no empty part.
    static func isContained(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !parts.contains("..") && !parts.contains("")
    }

    func validate(in mod: URL, fm: FileManager = .default) throws {
        guard !needs.isEmpty else { throw Problem.invalid("\(Self.fileName): \"needs\" names no RomFS path") }
        for path in needs where !Self.isContained(path) {
            throw Problem.invalid("\(Self.fileName): \"\(path)\" in \"needs\" is not a path inside the RomFS")
        }
        guard let script = build.first else { throw Problem.invalid("\(Self.fileName): \"build\" is empty") }
        guard Self.isContained(script), script.hasSuffix(".py") else {
            throw Problem.invalid("\(Self.fileName): \"\(script)\" is not a Python script in the mod's folder")
        }
        guard fm.fileExists(atPath: mod.appendingPathComponent(script).path) else {
            throw Problem.invalid("\(Self.fileName): the mod's folder has no \(script)")
        }
        guard build.contains(where: { $0.contains("{out}") }) else {
            throw Problem.invalid("\(Self.fileName): \"build\" does not say where to write the files ({out})")
        }
    }

    /// The command line: the Python, the script's full path, then the arguments with `{game}` and `{out}` filled in.
    package func command(python: String, mod: URL, game: URL, out: URL) -> [String] {
        [python, mod.appendingPathComponent(build[0]).path] + build.dropFirst().map {
            $0.replacingOccurrences(of: "{game}", with: game.path).replacingOccurrences(of: "{out}", with: out.path)
        }
    }
}
