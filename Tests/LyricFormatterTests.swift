import Foundation

@main struct LyricFormatterTests {
    static func main() {
        let original = "[ar:Example]\r\n[0:01.349][00:03.20]原文\r\n[00:04.00]末句\r\n"
        let translation = "[offset:+100]\n[0:01.249]Translation\n[00:03.10]Translation\n[00:03.11]Extra"
        var options = LyricOptions()
        expect(original, translation, options,
               "[ar:Example]\n[00:01.34]原文 Translation\n[00:03.20]原文 Translation\n[00:03.21]Extra\n[00:04.00]末句")

        options.normalizeTimes = false
        options.separator = " | "
        options.removeHeaders = true
        expect(original, translation, options,
               "[0:01.349]原文 | Translation\n[00:03.20]原文 | Translation\n[00:03.21]Extra\n[00:04.00]末句")

        let first = "[00:01.00]One\n[00:03.00]Two"
        let second = "[00:01.00]一\n[00:03.00]二"
        options = LyricOptions()
        options.layout = .originalFirst
        expect(first, second, options, "[00:01.00]One\n[00:01.00]一\n[00:03.00]Two\n[00:03.00]二")
        options.layout = .translationFirst
        expect(first, second, options, "[00:01.00]一\n[00:01.00]One\n[00:03.00]二\n[00:03.00]Two")
        options.layout = .staggered
        expect(first, second, options, "[00:01.00]One\n[00:02.99]一\n[00:03.00]Two\n[00:13.00]二")
        expect("[00:01.00]One\n\n[00:02.70]\n[00:03.00]Two",
               second + "\n[00:02.00]Extra\n[00:05.00]Later", options,
               "[00:01.00]One\n[00:02.00]Extra\n\n[00:02.70]\n[00:02.99]一\n[00:03.00]Two\n[00:05.00]Later\n[00:13.00]二")
        options.layout = .sections
        expect(first, second, options, first + "\n" + second)

        options.translationOnly = true
        expect(first, second, options, second)
        expect(first, "[ti:Translation]\n[00:01.00] ", options, first)
        options.translationEnabled = false
        expect(first, second, options, first)

        options = LyricOptions()
        options.removeTimes = true
        options.removeHeaders = true
        options.removeBlankLines = true
        options.conversion = .simplified
        expect("\u{FEFF}[ti:歌曲]\n\n[00:02]繁體\n[00:03]  ", nil, options, "繁体")
        expect("[ar:Only metadata]\n[00:01.00] ", nil, options, "")

        options = LyricOptions()
        expect("One\n\nTwo", "一\n二\n三", options, "One 一\n\nTwo 二\n三")
        expect("[00:01.00]One", "Plain", options, "[00:01.00]One\nPlain")
        expect("[00:01.000]One\n[00:01.001]Two", "[00:01.001]二", options, "[00:01.00]One\n[00:01.00]Two 二")
        expect("[00:00.02]One\n[offset:-30]", "[00:00.00]一", options, "[00:00.00]One 一")
        expect("[00:02]One\n[00:02]Two", "[00:02]一\n[00:02]二", options, "[00:02.00]One 一\n[00:02.00]Two 二")
        expect("", "[00:02]一", options, "[00:02.00]一")

        let data = try! JSONEncoder().encode(options)
        precondition(try! JSONDecoder().decode(LyricOptions.self, from: data) == options)
        print("PASS lyric layouts, timestamps, translation fallbacks, cleanup, and options coding")
    }

    private static func expect(_ original: String, _ translation: String?, _ options: LyricOptions,
                               _ expected: String, line: UInt = #line) {
        let actual = LyricFormatter.format(original: original, translation: translation, options: options)
        precondition(actual == expected, "Expected \(expected.debugDescription), got \(actual.debugDescription)", line: line)
    }
}
