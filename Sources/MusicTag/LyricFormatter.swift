import Foundation

enum LyricLayout: String, Codable, CaseIterable {
    case inline, originalFirst, staggered, translationFirst, sections
}

enum LyricConversion: String, Codable, CaseIterable {
    case none, simplified, traditional
}

struct LyricOptions: Codable, Equatable {
    var layout: LyricLayout = .inline
    var translationEnabled = true
    var translationOnly = false
    var separator = " "
    var normalizeTimes = true
    var removeTimes = false
    var removeBlankLines = false
    var removeHeaders = false
    var conversion: LyricConversion = .none
}

enum LyricFormatter {
    private struct Time {
        let milliseconds: Int
        let spelling: String?

        func tag(normalized: Bool) -> String {
            if !normalized, let spelling { return spelling }
            let minutes = milliseconds / 60_000
            let seconds = milliseconds / 1_000 % 60
            let fraction = milliseconds % 1_000
            let decimal = normalized || fraction.isMultiple(of: 10)
                ? String(format: "%02d", fraction / 10)
                : String(format: "%03d", fraction)
            return "[\(String(format: "%02lld:%02lld", Int64(minutes), Int64(seconds))).\(decimal)]"
        }
    }

    private struct Line {
        let time: Time?
        let text: String

        var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private struct Document {
        var headers: [String] = []
        var lines: [Line] = []

        var hasText: Bool { lines.contains(where: \.hasText) }
        var hasTimes: Bool { lines.contains { $0.time != nil } }
    }

    private static let timePattern = try! NSRegularExpression(pattern: #"^\[([0-9]+):([0-5]?[0-9])(?:[.:]([0-9]{1,3}))?\]"#)
    private static let headerPattern = try! NSRegularExpression(pattern: #"^(?:\[[A-Za-z][A-Za-z0-9_-]*:[^\]]*\]\s*)+$"#)
    private static let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:\s*([+-]?[0-9]+)\s*\]"#, options: .caseInsensitive)

    static func format(original: String, translation: String?, options: LyricOptions) -> String {
        let primary = parse(original)
        let secondary = options.translationEnabled && translation != original ? parse(translation ?? "") : Document()
        guard primary.hasText || secondary.hasText else { return "" }

        let headers: [String]
        let lines: [Line]
        if (!primary.hasText || options.translationOnly) && secondary.hasText {
            headers = secondary.headers.isEmpty ? primary.headers : secondary.headers
            lines = secondary.lines
        } else if !secondary.hasText {
            headers = primary.headers
            lines = primary.lines
        } else {
            var seen = Set<String>()
            headers = (primary.headers + secondary.headers).filter { seen.insert($0).inserted }
            lines = options.layout == .sections
                ? primary.lines + secondary.lines
                : merge(primary, secondary, options: options)
        }

        var output = options.removeHeaders ? [] : headers
        output += lines.compactMap { line in
            if options.removeBlankLines && !line.hasText { return nil }
            let tag = options.removeTimes ? "" : line.time?.tag(normalized: options.normalizeTimes) ?? ""
            return tag + line.text
        }
        let result = output.joined(separator: "\n")
        switch options.conversion {
        case .none: return result
        case .simplified: return result.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? result
        case .traditional: return result.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? result
        }
    }

    private static func parse(_ text: String) -> Document {
        var rows = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        if rows.first?.hasPrefix("\u{FEFF}") == true { rows[0].removeFirst() }
        var offset = 0
        var content: [String] = []
        var document = Document()
        for row in rows {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if headerPattern.firstMatch(in: trimmed, range: range) != nil {
                for match in offsetPattern.matches(in: trimmed, range: range) {
                    if let value = captured(match, group: 1, in: trimmed).flatMap(Int.init) {
                        offset = value
                    }
                }
                let header = offsetPattern.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
                if !header.trimmingCharacters(in: .whitespaces).isEmpty { document.headers.append(header) }
            } else {
                content.append(row)
            }
        }
        for row in content {
            var remainder = row[...]
            var times: [Time] = []
            while let (time, count) = parseTime(String(remainder), offset: offset) {
                times.append(time)
                remainder = remainder.dropFirst(count)
            }
            if times.isEmpty {
                document.lines.append(Line(time: nil, text: row))
            } else {
                let lyric = String(remainder)
                document.lines += times.map { Line(time: $0, text: lyric) }
            }
        }
        return document
    }

    private static func parseTime(_ text: String, offset: Int) -> (Time, Int)? {
        guard let match = timePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let spelling = captured(match, group: 0, in: text),
              let minutes = captured(match, group: 1, in: text).flatMap(Int.init),
              let seconds = captured(match, group: 2, in: text).flatMap(Int.init),
              minutes <= (Int.max - 60_000) / 60_000 else { return nil }

        let decimal = captured(match, group: 3, in: text) ?? ""
        let fraction = Int(decimal.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        let milliseconds = minutes * 60_000 + seconds * 1_000 + fraction
        let (shifted, overflow) = milliseconds.addingReportingOverflow(offset)
        let effective = overflow ? Int.max : max(0, shifted)
        return (Time(milliseconds: effective, spelling: offset == 0 ? spelling : nil), spelling.count)
    }

    private static func captured(_ match: NSTextCheckingResult, group: Int, in text: String) -> String? {
        Range(match.range(at: group), in: text).map { String(text[$0]) }
    }

    private static func merge(_ primary: Document, _ secondary: Document, options: LyricOptions) -> [Line] {
        let bothPlain = !primary.hasTimes && !secondary.hasTimes
        var byTime: [Int: [Int]] = [:]
        var plain: [Int] = []
        for (index, line) in secondary.lines.enumerated() where line.hasText {
            if let time = line.time {
                byTime[time.milliseconds, default: []].append(index)
            } else if bothPlain {
                plain.append(index)
            }
        }
        var nextByTime: [Int: Int] = [:]
        var nextPlain = 0
        var matched = Set<Int>()
        var output: [Line] = []
        let nextTimes = options.layout == .staggered ? staggeredTimes(primary.lines) : [:]

        for original in primary.lines {
            var translationIndex: Int?
            if original.hasText, let time = original.time?.milliseconds {
                let next = nextByTime[time, default: 0]
                if let indices = byTime[time], next < indices.count {
                    translationIndex = indices[next]
                    nextByTime[time] = next + 1
                }
            } else if original.hasText && bothPlain && nextPlain < plain.count {
                translationIndex = plain[nextPlain]
                nextPlain += 1
            }
            guard let translationIndex else {
                output.append(original)
                continue
            }
            matched.insert(translationIndex)
            let translationText = secondary.lines[translationIndex].text
            guard translationText != original.text else {
                output.append(original)
                continue
            }
            let translated = Line(time: original.time, text: translationText)
            switch options.layout {
            case .inline:
                output.append(Line(time: original.time, text: original.text + options.separator + translationText))
            case .originalFirst, .sections:
                output += [original, translated]
            case .translationFirst:
                output += [translated, original]
            case .staggered:
                let shifted = original.time.flatMap { nextTimes[$0.milliseconds] }
                output += [original, Line(time: shifted, text: translationText)]
            }
        }
        output += secondary.lines.enumerated().compactMap { matched.contains($0.offset) ? nil : $0.element }
        let timed = output.enumerated().compactMap { index, line in
            line.time.map { (index: index, milliseconds: $0.milliseconds) }
        }
        let sorted = timed.sorted { lhs, rhs in
            lhs.milliseconds == rhs.milliseconds ? lhs.index < rhs.index : lhs.milliseconds < rhs.milliseconds
        }
        var ordered = output
        for (slot, line) in zip(timed, sorted) {
            ordered[slot.index] = output[line.index]
        }
        return ordered
    }

    private static func staggeredTimes(_ lines: [Line]) -> [Int: Time] {
        let times = Set(lines.filter(\.hasText).compactMap { $0.time?.milliseconds }).sorted()
        var result: [Int: Time] = [:]
        for (index, time) in times.enumerated() {
            let next: Int
            if index + 1 < times.count {
                next = max(time, times[index + 1] - 10)
            } else {
                next = min(time, Int.max - 10_000) + 10_000
            }
            result[time] = Time(milliseconds: next, spelling: nil)
        }
        return result
    }
}
