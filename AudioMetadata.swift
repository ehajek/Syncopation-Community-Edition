// AudioMetadata.swift — reads the tags and audio properties Syncopation needs
// to register tracks in the iPod's database. FLAC is parsed natively (Vorbis
// comments + STREAMINFO); everything else goes through AVFoundation.
//
// Copyright (C) 2026 Eddie Hajek
// Licensed under the GNU General Public License v3.0 — see the LICENSE file.

import Foundation
import AVFoundation

struct AudioMetadata {
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var genre = ""
    var composer = ""
    var comment = ""
    var trackNr = 0
    var trackCount = 0
    var discNr = 0
    var discCount = 0
    var year = 0
    var durationMS = 0
    var sampleRate = 0
}

enum MetadataReader {

    /// Reads whatever we can; always returns at least a title (the filename).
    static func read(url: URL) -> AudioMetadata {
        var meta: AudioMetadata
        if url.pathExtension.lowercased() == "flac" {
            meta = readFLAC(url: url) ?? AudioMetadata()
        } else {
            meta = readAVAsset(url: url)
        }
        if meta.title.isEmpty {
            meta.title = url.deletingPathExtension().lastPathComponent
        }
        return meta
    }

    // MARK: FLAC

    private static func readFLAC(url: URL) -> AudioMetadata? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 8,
              data.prefix(4).elementsEqual("fLaC".utf8) else { return nil }

        var meta = AudioMetadata()
        var pos = 4
        while pos + 4 <= data.count {
            let header = data[data.startIndex + pos]
            let isLast = header & 0x80 != 0
            let blockType = header & 0x7F
            let len = Int(data[data.startIndex + pos + 1]) << 16
                    | Int(data[data.startIndex + pos + 2]) << 8
                    | Int(data[data.startIndex + pos + 3])
            let body = pos + 4
            guard body + len <= data.count else { break }

            if blockType == 0, len >= 34 {          // STREAMINFO
                let b = { (i: Int) in Int(data[data.startIndex + body + i]) }
                let sampleRate = (b(10) << 12) | (b(11) << 4) | (b(12) >> 4)
                let totalSamples = ((b(13) & 0x0F) << 32) | (b(14) << 24)
                                 | (b(15) << 16) | (b(16) << 8) | b(17)
                meta.sampleRate = sampleRate
                if sampleRate > 0 {
                    meta.durationMS = Int(Double(totalSamples) * 1000.0 / Double(sampleRate))
                }
            } else if blockType == 4 {              // VORBIS_COMMENT
                parseVorbisComments(data, at: body, length: len, into: &meta)
            }
            if isLast { break }
            pos = body + len
        }
        return meta
    }

    private static func parseVorbisComments(_ data: Data, at start: Int, length: Int,
                                            into meta: inout AudioMetadata) {
        func u32le(_ offset: Int) -> Int {
            let s = data.startIndex + offset
            return Int(data[s]) | Int(data[s + 1]) << 8
                 | Int(data[s + 2]) << 16 | Int(data[s + 3]) << 24
        }
        let end = start + length
        var pos = start
        guard pos + 4 <= end else { return }
        let vendorLen = u32le(pos); pos += 4 + vendorLen
        guard pos + 4 <= end else { return }
        let count = u32le(pos); pos += 4

        for _ in 0..<count {
            guard pos + 4 <= end else { return }
            let len = u32le(pos); pos += 4
            guard pos + len <= end, len > 0 else { return }
            let s = data.startIndex + pos
            defer { pos += len }
            guard let comment = String(data: data[s..<s + len], encoding: .utf8),
                  let eq = comment.firstIndex(of: "=") else { continue }
            let key = comment[..<eq].uppercased()
            let value = String(comment[comment.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "TITLE": meta.title = value
            case "ARTIST": if meta.artist.isEmpty { meta.artist = value }
            case "ALBUM": meta.album = value
            case "ALBUMARTIST", "ALBUM ARTIST": meta.albumArtist = value
            case "GENRE": if meta.genre.isEmpty { meta.genre = value }
            case "COMPOSER": if meta.composer.isEmpty { meta.composer = value }
            case "COMMENT", "DESCRIPTION": if meta.comment.isEmpty { meta.comment = value }
            case "TRACKNUMBER":
                let parts = value.split(separator: "/")
                meta.trackNr = Int(parts.first ?? "") ?? 0
                if parts.count > 1 { meta.trackCount = Int(parts[1]) ?? meta.trackCount }
            case "TRACKTOTAL", "TOTALTRACKS": meta.trackCount = Int(value) ?? meta.trackCount
            case "DISCNUMBER":
                let parts = value.split(separator: "/")
                meta.discNr = Int(parts.first ?? "") ?? 0
                if parts.count > 1 { meta.discCount = Int(parts[1]) ?? meta.discCount }
            case "DISCTOTAL", "TOTALDISCS": meta.discCount = Int(value) ?? meta.discCount
            case "DATE", "YEAR":
                if meta.year == 0 { meta.year = Int(value.prefix(4)) ?? 0 }
            default: break
            }
        }
    }

    // MARK: MP3 / M4A / AAC / WAV / AIFF via AVFoundation

    private static func readAVAsset(url: URL) -> AudioMetadata {
        var meta = AudioMetadata()
        let asset = AVURLAsset(url: url)

        let duration = asset.duration
        if duration.isNumeric {
            meta.durationMS = Int(CMTimeGetSeconds(duration) * 1000)
        }
        if let track = asset.tracks(withMediaType: .audio).first {
            for desc in track.formatDescriptions {
                let fd = desc as! CMFormatDescription
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                    meta.sampleRate = Int(asbd.mSampleRate)
                    break
                }
            }
        }

        func text(_ item: AVMetadataItem?) -> String {
            item?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let common = asset.commonMetadata
        meta.title = text(AVMetadataItem.metadataItems(
            from: common, filteredByIdentifier: .commonIdentifierTitle).first)
        meta.artist = text(AVMetadataItem.metadataItems(
            from: common, filteredByIdentifier: .commonIdentifierArtist).first)
        meta.album = text(AVMetadataItem.metadataItems(
            from: common, filteredByIdentifier: .commonIdentifierAlbumName).first)

        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                guard let id = item.identifier else { continue }
                switch id {
                case .iTunesMetadataUserGenre, .id3MetadataContentType:
                    if meta.genre.isEmpty { meta.genre = text(item) }
                case .iTunesMetadataAlbumArtist, .id3MetadataBand:
                    if meta.albumArtist.isEmpty { meta.albumArtist = text(item) }
                case .iTunesMetadataComposer, .id3MetadataComposer:
                    if meta.composer.isEmpty { meta.composer = text(item) }
                case .iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime:
                    if meta.year == 0 { meta.year = Int(text(item).prefix(4)) ?? 0 }
                case .id3MetadataTrackNumber:
                    let parts = text(item).split(separator: "/")
                    meta.trackNr = Int(parts.first ?? "") ?? meta.trackNr
                    if parts.count > 1 { meta.trackCount = Int(parts[1]) ?? meta.trackCount }
                case .iTunesMetadataTrackNumber:
                    // iTunes stores this as an 8-byte blob: [0, trackNr, trackCount, 0] as u16be
                    if let d = item.dataValue, d.count >= 6 {
                        meta.trackNr = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
                        meta.trackCount = Int(d[d.startIndex + 4]) << 8 | Int(d[d.startIndex + 5])
                    }
                case .iTunesMetadataDiscNumber:
                    if let d = item.dataValue, d.count >= 6 {
                        meta.discNr = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
                        meta.discCount = Int(d[d.startIndex + 4]) << 8 | Int(d[d.startIndex + 5])
                    }
                default: break
                }
            }
        }
        return meta
    }
}
