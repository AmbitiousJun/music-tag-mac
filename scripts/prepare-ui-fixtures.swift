import Foundation

@main struct PrepareUIFixtures {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: prepare-ui-fixtures <new-directory>\n", stderr)
            exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures = try UITestFixtures.create(at: root)
        print("Created disposable UI fixtures: \(fixtures.root.path)")
        print("Import folder: \(fixtures.music.path)")
        print("Cover: \(fixtures.cover.path)")
        print("Lyrics: \(fixtures.lyrics.path)")
        print("Baseline PCM SHA-256: \(fixtures.root.appendingPathComponent("manifest.json").path)")
        print("Isolated launch arguments: --ui-test-session \(UUID().uuidString)")
    }
}
