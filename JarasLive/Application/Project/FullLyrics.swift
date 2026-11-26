import Foundation

/// The edit cursor chooses the song; it is never the insertion offset.
public struct FullLyricsRange: Equatable {
    public let region: UUID
    public let name: String
    public let start: Double
    public let end: Double

    public init(song: Song, position: Double) throws {
        guard position.isFinite,
              let root = song.parts.filter({ $0.parentRegionID == nil && $0.startTime <= position && position < $0.endTime })
                .min(by: { $0.endTime - $0.startTime < $1.endTime - $1.startTime }) else {
            throw ProjectError.invalid("Place the edit cursor inside a song region.")
        }
        let children = song.parts.filter { $0.parentRegionID == root.id }
            .sorted { song.playbackRegionStart($0) < song.playbackRegionStart($1) }
        if !children.isEmpty {
            guard let index = children.lastIndex(where: { song.playbackRegionStart($0) <= position }) else {
                throw ProjectError.invalid("Place the edit cursor inside a song region.")
            }
            let child = children[index]
            let limit = index + 1 < children.count ? song.playbackRegionStart(children[index + 1]) : root.endTime
            region = child.id; name = child.name
            start = max(root.startTime, song.playbackRegionStart(child)); end = min(root.endTime, child.endTime, limit)
        } else {
            region = root.id; name = root.name; start = root.startTime; end = root.endTime
        }
        guard start.isFinite, end.isFinite, start >= 0, end > start, position < end else {
            throw ProjectError.invalid("Invalid song duration.")
        }
    }

    public func items(text: String) throws -> [AudioClip] {
        let stanzas = FullLyrics.stanzas(text)
        guard stanzas.count >= 2 else {
            throw ProjectError.invalid("Separate at least one stanza with two blank lines.")
        }
        let length = (end - start) / Double(stanzas.count)
        guard length >= 0.01 else { throw ProjectError.invalid("Too many stanzas for this song duration.") }
        return stanzas.enumerated().map { index, text in
            let onset = start + Double(index) * length
            let finish = index == stanzas.count - 1 ? end : start + Double(index + 1) * length
            var item = AudioClip(id: UUID(), name: String(ItemTextColors.plain(text).split(separator: "\n").first?.prefix(80) ?? ""),
                startTime: onset, duration: finish - onset, text: text)
            item.regionOwnerID = region
            return item
        }
    }
}

public enum FullLyrics {
    /// UTF-16 ranges also let the editors outline the same stanzas they create.
    public static func stanzaRanges(_ text: String) -> [NSRange] {
        let source = text as NSString
        var result: [NSRange] = []
        var cursor = 0, start: Int? = nil, end = 0, blanks = 0
        while cursor < source.length {
            var lineStart = 0, next = 0, contentEnd = 0
            source.getLineStart(&lineStart, end: &next, contentsEnd: &contentEnd,
                                for: NSRange(location: cursor, length: 0))
            let line = source.substring(with: NSRange(location: lineStart, length: contentEnd - lineStart))
            cursor = next
            if line.trimmingCharacters(in: .whitespaces).isEmpty { blanks += 1; continue }
            if blanks >= 2, let first = start {
                result.append(NSRange(location: first, length: end - first))
                start = nil
            }
            start = start ?? lineStart
            end = contentEnd
            blanks = 0
        }
        if let start { result.append(NSRange(location: start, length: end - start)) }
        return result
    }

    public static func stanzas(_ text: String) -> [String] {
        let runs = ItemTextColors.runs(text)
        let plain = runs.map(\.text).joined()
        let ranges = stanzaRanges(plain)
        var slices = [[ItemTextColors.Run]](repeating: [], count: ranges.count)
        var offset = 0, index = 0
        for run in runs {
            let source = run.text as NSString
            let runRange = NSRange(location: offset, length: source.length)
            while index < ranges.count, ranges[index].location < NSMaxRange(runRange) {
                let common = NSIntersectionRange(runRange, ranges[index])
                if common.length != 0 {
                    let piece = source.substring(with: NSRange(location: common.location - offset, length: common.length))
                    slices[index].append(.init(text: piece, color: run.color))
                }
                if NSMaxRange(ranges[index]) > NSMaxRange(runRange) { break }
                index += 1
            }
            offset += source.length
        }
        return slices.map { values in
            ItemTextColors.encode(values.map {
                .init(text: $0.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"),
                      color: $0.color)
            })
        }
    }
}
