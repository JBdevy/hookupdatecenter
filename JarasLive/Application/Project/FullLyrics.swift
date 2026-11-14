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
            var item = AudioClip(id: UUID(), name: String(text.split(separator: "\n").first?.prefix(80) ?? ""),
                startTime: onset, duration: finish - onset, text: text)
            item.regionOwnerID = region
            return item
        }
    }
}

public enum FullLyrics {
    /// Two empty lines separate stanzas. One empty line belongs to its stanza.
    /// Normalize line endings from pasted Windows/macOS documents first.
    public static func stanzas(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = [], lines: [String] = [], blanks = 0
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { blanks += 1; continue }
            if blanks >= 2 && !lines.isEmpty { result.append(lines.joined(separator: "\n")); lines.removeAll(keepingCapacity: true) }
            else if blanks == 1 && !lines.isEmpty { lines.append("") }
            blanks = 0
            lines.append(line)
        }
        if !lines.isEmpty { result.append(lines.joined(separator: "\n")) }
        return result
    }
}
