// IPodDB.swift — native Swift reader/writer for the iPod's iTunesDB.
//
// The binary format and the hash58 checksum were reverse-engineered by the
// libgpod project (https://github.com/gtkpod/libgpod); this file is an
// independent Swift implementation written with libgpod as the reference.
// The hash58 algorithm is ported from libgpod's itdb_hash58.c:
//   Copyright (C) 2007 Christophe Fergeau <teuf@gnome.org>
//   (BSD license; based on proof-of-concept code by wtbw)
// That BSD attribution must be retained in all copies of this file.
//
// Copyright (C) 2026 Eddie Hajek
// Licensed under the GNU General Public License v3.0 — see the LICENSE file.

import Foundation
import CryptoKit

// MARK: - Binary helpers (iTunesDB is little-endian)

final class BinWriter {
    private(set) var data = Data()
    var count: Int { data.count }

    func u8(_ v: UInt8) { data.append(v) }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    func f32(_ v: Float) { u32(v.bitPattern) }
    func zeros(_ n: Int) { data.append(Data(count: n)) }
    func bytes(_ d: Data) { data.append(d) }
    func tag(_ s: String) { data.append(contentsOf: s.utf8) }        // "mhbd" etc.
    func utf16(_ s: String) {
        for unit in s.utf16 { u16(unit) }
    }
    func pad(to target: Int) {
        precondition(count <= target, "record overran its declared size")
        zeros(target - count)
    }
    func patchU32(_ v: UInt32, at offset: Int) {
        withUnsafeBytes(of: v.littleEndian) { bytes in
            data.replaceSubrange(offset..<offset + 4, with: bytes)
        }
    }
}

struct BinReader {
    let data: Data
    var pos: Int = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - pos }

    mutating func u8() -> UInt8 { defer { pos += 1 }; return data[data.startIndex + pos] }
    mutating func u16() -> UInt16 { UInt16(u8()) | (UInt16(u8()) << 8) }
    mutating func u32() -> UInt32 { UInt32(u16()) | (UInt32(u16()) << 16) }
    mutating func u64() -> UInt64 { UInt64(u32()) | (UInt64(u32()) << 32) }

    func peekTag(at offset: Int) -> String? {
        guard offset + 4 <= data.count else { return nil }
        let start = data.startIndex + offset
        return String(data: data[start..<start + 4], encoding: .ascii)
    }
    func u32(at offset: Int) -> UInt32 {
        var r = BinReader(data); r.pos = offset; return r.u32()
    }
    func u64(at offset: Int) -> UInt64 {
        var r = BinReader(data); r.pos = offset; return r.u64()
    }
    func u8(at offset: Int) -> UInt8 { data[data.startIndex + offset] }
    func slice(_ offset: Int, _ length: Int) -> Data {
        let start = data.startIndex + offset
        return data.subdata(in: start..<start + min(length, data.count - offset))
    }
}

// MARK: - Model

struct IPodTrack {
    var id: UInt32 = 0                  // renumbered on write (starts at 52, like iTunes)
    var dbid: UInt64 = 0
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var genre = ""
    var composer = ""
    var comment = ""
    var filetypeDescription = ""        // e.g. "Apple Lossless audio file"
    var filetypeMarker: UInt32 = 0      // fourcc, e.g. 'M4A '
    var ipodPath = ""                   // ":iPod_Control:Music:F00:XXXX.m4a"
    var size: UInt32 = 0
    var lengthMS: UInt32 = 0
    var trackNr: UInt32 = 0
    var trackCount: UInt32 = 0
    var cdNr: UInt32 = 0
    var cdCount: UInt32 = 0
    var year: UInt32 = 0
    var bitrate: UInt32 = 0
    var samplerate: UInt32 = 0
    var rating: UInt8 = 0
    var playcount: UInt32 = 0
    var timeAdded: UInt32 = 0           // mac time
    var timeModified: UInt32 = 0
    // Artwork links (see IPodArtwork.swift). mhiiLink points at an mhii id in
    // the ArtworkDB; all tracks sharing a cover share one mhii.
    var hasArtwork: UInt8 = 0           // 1 = yes
    var artworkCount: UInt16 = 0
    var artworkSize: UInt32 = 0         // byte size of the original cover image
    var mhiiLink: UInt32 = 0
}

struct IPodPlaylist {
    var isMaster = false
    var name = ""
    var id: UInt64 = 0
    var sortorder: UInt32 = 1           // 1 = manual
    var memberIDs: [UInt32] = []        // track ids
    var smartPrefMhod: Data? = nil      // raw mhod type 50 (smart playlist prefs), verbatim
    var smartRulesMhod: Data? = nil     // raw mhod type 51 (smart playlist rules), verbatim
}

struct IPodDatabase {
    var tracks: [IPodTrack] = []
    var playlists: [IPodPlaylist] = []
    // The mhsd type 5 playlists are the device UI's menu categories (Music,
    // Videos, Audiobooks, …) as smart playlists. The firmware NEEDS these —
    // writing an empty type 5 sends an iPod nano to the "use iTunes to
    // restore" screen. Preserved verbatim across rewrites.
    var mhsd5Playlists: [IPodPlaylist] = []
    var geniusSection: Data? = nil      // raw mhsd type 9, verbatim
    // mhbd fields preserved across a rewrite
    var dbID: UInt64 = 0
    var libraryPID: UInt64 = 0
    var id0x24: UInt64 = 0
    var platform: UInt16 = 1            // 1 = macOS
    var language = "en"
    var unk0x50: UInt32 = 0
    var unk0x54: UInt32 = 0

    var masterPlaylistIndex: Int? { playlists.firstIndex(where: { $0.isMaster }) }
}

enum IPodDBError: LocalizedError {
    case notAnITunesDB
    case truncated
    case missingFireWireGUID

    var errorDescription: String? {
        switch self {
        case .notAnITunesDB: return "The file on the iPod doesn't look like an iTunesDB."
        case .truncated: return "The iTunesDB on the iPod is truncated or corrupt."
        case .missingFireWireGUID:
            return "This iPod requires a checksummed database, but its FireWire GUID "
                 + "could not be read. Sync it once with iTunes/Music or Swinsian "
                 + "(which creates SysInfoExtended), then try again."
        }
    }
}

let macEpochOffset: UInt32 = 2_082_844_800   // seconds between 1904 and 1970

func macTimeNow() -> UInt32 {
    UInt32(Date().timeIntervalSince1970) &+ macEpochOffset
}

// MARK: - Parser

enum ITunesDBParser {

    static func parse(_ data: Data) throws -> IPodDatabase {
        let r = BinReader(data)
        guard r.peekTag(at: 0) == "mhbd" else { throw IPodDBError.notAnITunesDB }
        guard data.count >= 244 else { throw IPodDBError.truncated }

        var db = IPodDatabase()
        let headerLen = Int(r.u32(at: 4))
        db.dbID = r.u64(at: 0x18)
        db.platform = UInt16(r.u32(at: 0x20) & 0xFFFF)
        db.id0x24 = r.u64(at: 0x24)
        if let lang = String(data: r.slice(0x46, 2), encoding: .ascii), !lang.isEmpty {
            db.language = lang
        }
        db.libraryPID = r.u64(at: 0x48)
        db.unk0x50 = r.u32(at: 0x50)
        db.unk0x54 = r.u32(at: 0x54)

        var pos = headerLen
        while pos + 16 <= data.count, r.peekTag(at: pos) == "mhsd" {
            let sdHeaderLen = Int(r.u32(at: pos + 4))
            let sdTotalLen = Int(r.u32(at: pos + 8))
            let sdType = r.u32(at: pos + 12)
            guard sdTotalLen > 0, pos + sdTotalLen <= data.count else { throw IPodDBError.truncated }
            switch sdType {
            case 1:
                try parseTracks(r, at: pos + sdHeaderLen, into: &db)
            case 2:
                db.playlists = try parsePlaylists(r, at: pos + sdHeaderLen)
            case 5:
                db.mhsd5Playlists = try parsePlaylists(r, at: pos + sdHeaderLen)
            case 9:
                db.geniusSection = r.slice(pos, sdTotalLen)
            default:
                break   // type 3 (podcast view) and albums/artists are regenerated
            }
            pos += sdTotalLen
        }
        return db
    }

    private static func parseTracks(_ r: BinReader, at start: Int, into db: inout IPodDatabase) throws {
        guard r.peekTag(at: start) == "mhlt" else { return }
        let count = Int(r.u32(at: start + 8))
        var pos = start + Int(r.u32(at: start + 4))
        for _ in 0..<count {
            guard r.peekTag(at: pos) == "mhit" else { throw IPodDBError.truncated }
            let headerLen = Int(r.u32(at: pos + 4))
            let totalLen = Int(r.u32(at: pos + 8))
            let mhodCount = Int(r.u32(at: pos + 12))

            var t = IPodTrack()
            t.id = r.u32(at: pos + 16)
            t.filetypeMarker = r.u32(at: pos + 24)
            t.rating = r.u8(at: pos + 31)
            t.timeModified = r.u32(at: pos + 32)
            t.size = r.u32(at: pos + 36)
            t.lengthMS = r.u32(at: pos + 40)
            t.trackNr = r.u32(at: pos + 44)
            t.trackCount = r.u32(at: pos + 48)
            t.year = r.u32(at: pos + 52)
            t.bitrate = r.u32(at: pos + 56)
            t.samplerate = r.u32(at: pos + 60) >> 16
            t.playcount = r.u32(at: pos + 80)
            t.cdNr = r.u32(at: pos + 92)
            t.cdCount = r.u32(at: pos + 96)
            t.timeAdded = r.u32(at: pos + 104)
            t.dbid = r.u64(at: pos + 112)
            t.artworkCount = UInt16(r.u32(at: pos + 124) & 0xFFFF)
            t.artworkSize = r.u32(at: pos + 128)
            t.hasArtwork = r.u8(at: pos + 164)
            if headerLen > 0x160 + 4 { t.mhiiLink = r.u32(at: pos + 0x160) }

            var mhodPos = pos + headerLen
            for _ in 0..<mhodCount {
                guard r.peekTag(at: mhodPos) == "mhod" else { break }
                let mhodTotal = Int(r.u32(at: mhodPos + 8))
                let mhodType = r.u32(at: mhodPos + 12)
                if let s = readStringMhod(r, at: mhodPos, total: mhodTotal) {
                    switch mhodType {
                    case 1: t.title = s
                    case 2: t.ipodPath = s
                    case 3: t.album = s
                    case 4: t.artist = s
                    case 5: t.genre = s
                    case 6: t.filetypeDescription = s
                    case 8: t.comment = s
                    case 12: t.composer = s
                    case 22: t.albumArtist = s
                    default: break
                    }
                }
                mhodPos += max(mhodTotal, 16)
            }
            db.tracks.append(t)
            pos += totalLen
        }
    }

    private static func parsePlaylists(_ r: BinReader, at start: Int) throws -> [IPodPlaylist] {
        guard r.peekTag(at: start) == "mhlp" else { return [] }
        let count = Int(r.u32(at: start + 8))
        var pos = start + Int(r.u32(at: start + 4))
        var playlists: [IPodPlaylist] = []
        for _ in 0..<count {
            guard r.peekTag(at: pos) == "mhyp" else { throw IPodDBError.truncated }
            let headerLen = Int(r.u32(at: pos + 4))
            let totalLen = Int(r.u32(at: pos + 8))
            let mhodCount = Int(r.u32(at: pos + 12))
            let mhipCount = Int(r.u32(at: pos + 16))

            var pl = IPodPlaylist()
            pl.isMaster = r.u8(at: pos + 20) == 1
            pl.id = r.u64(at: pos + 28)
            pl.sortorder = r.u32(at: pos + 44)

            var childPos = pos + headerLen
            for _ in 0..<mhodCount {
                guard r.peekTag(at: childPos) == "mhod" else { break }
                let mhodTotal = Int(r.u32(at: childPos + 8))
                let mhodType = r.u32(at: childPos + 12)
                switch mhodType {
                case 1:
                    if let s = readStringMhod(r, at: childPos, total: mhodTotal) { pl.name = s }
                case 50:
                    pl.smartPrefMhod = r.slice(childPos, mhodTotal)
                case 51:
                    pl.smartRulesMhod = r.slice(childPos, mhodTotal)
                default:
                    break   // prefs mhod (100) and sort indexes (52/53) are regenerated
                }
                childPos += max(mhodTotal, 16)
            }
            for _ in 0..<mhipCount {
                guard r.peekTag(at: childPos) == "mhip" else { break }
                let mhipTotal = Int(r.u32(at: childPos + 8))   // includes its child mhod
                pl.memberIDs.append(r.u32(at: childPos + 24))
                childPos += max(mhipTotal, 76)
            }
            playlists.append(pl)
            pos += totalLen
        }
        return playlists
    }

    private static func readStringMhod(_ r: BinReader, at pos: Int, total: Int) -> String? {
        // String mhods: 24-byte header, then type(u32) len(u32) unk unk, UTF-16LE data.
        guard total >= 40 else { return nil }
        let stringType = r.u32(at: pos + 24)
        let byteLen = Int(r.u32(at: pos + 28))
        guard byteLen > 0, 40 + byteLen <= total else { return nil }
        let raw = r.slice(pos + 40, byteLen)
        if stringType == 1 {
            var units: [UInt16] = []
            units.reserveCapacity(byteLen / 2)
            var i = raw.startIndex
            while i < raw.endIndex, raw.index(after: i) < raw.endIndex {
                units.append(UInt16(raw[i]) | (UInt16(raw[raw.index(after: i)]) << 8))
                i = raw.index(i, offsetBy: 2)
            }
            return String(decoding: units, as: UTF16.self)
        }
        return String(data: raw, encoding: .utf8)
    }
}

// MARK: - Writer

enum ITunesDBWriter {

    static func serialize(_ db: IPodDatabase) -> Data {
        var db = db
        // Renumber track ids the way iTunes does (starting at 52) and remap playlists.
        var idMap: [UInt32: UInt32] = [:]
        for (i, _) in db.tracks.enumerated() {
            let newID = UInt32(52 + i)
            idMap[db.tracks[i].id] = newID
            db.tracks[i].id = newID
            if db.tracks[i].dbid == 0 { db.tracks[i].dbid = UInt64.random(in: 1...UInt64.max) }
        }
        for (i, _) in db.playlists.enumerated() {
            db.playlists[i].memberIDs = db.playlists[i].memberIDs.compactMap { idMap[$0] }
            if db.playlists[i].id == 0 { db.playlists[i].id = UInt64.random(in: 1...UInt64.max) }
        }
        for (i, _) in db.mhsd5Playlists.enumerated() {
            db.mhsd5Playlists[i].memberIDs = db.mhsd5Playlists[i].memberIDs.compactMap { idMap[$0] }
            if db.mhsd5Playlists[i].id == 0 {
                db.mhsd5Playlists[i].id = UInt64.random(in: 1...UInt64.max)
            }
        }
        // The master playlist always lists every track, first in the file.
        if let mi = db.masterPlaylistIndex {
            db.playlists[mi].memberIDs = db.tracks.map(\.id)
            let mpl = db.playlists.remove(at: mi)
            db.playlists.insert(mpl, at: 0)
        }
        if db.dbID == 0 { db.dbID = UInt64.random(in: 1...UInt64.max) }
        if db.libraryPID == 0 { db.libraryPID = UInt64.random(in: 1...UInt64.max) }

        let albums = groupIDs(db.tracks) { ($0.album, $0.albumArtist.isEmpty ? $0.artist : $0.albumArtist) }
        let artists = groupIDs(db.tracks) { ($0.artist, "") }

        // Section order and content mirror what iTunes itself writes (verified
        // against a device-accepted database): albums first, the master
        // playlist duplicated into type 3, the UI's smart playlists in type 5,
        // and the genius blob last. Deviating from this sends old firmware to
        // the restore screen.
        let masters = db.playlists.filter(\.isMaster)
        let w = BinWriter()
        writeMhbd(w, db, children: UInt32(8 + (db.geniusSection != nil ? 1 : 0)))
        writeAlbumsSection(w, db, albums: albums)
        writeTracksSection(w, db, albums: albums, artists: artists)
        writePlaylistsSection(w, db, type: 3, playlists: masters)
        writePlaylistsSection(w, db, type: 2, playlists: db.playlists)
        writeArtistsSection(w, db, artists: artists)
        writeEmptyListSection(w, type: 6)
        writeEmptyListSection(w, type: 10)
        writePlaylistsSection(w, db, type: 5, playlists: db.mhsd5Playlists)
        if let genius = db.geniusSection { w.bytes(genius) }
        w.patchU32(UInt32(w.count), at: 8)                                      // mhbd total size
        return w.data
    }

    // Unique (key → sequential id), in first-seen order, keyed per track index.
    private struct GroupIDs {
        var idFor: [Int: UInt32] = [:]              // track index → group id
        var representative: [UInt32: Int] = [:]     // group id → first track index
        var order: [UInt32] = []
    }

    private static func groupIDs(_ tracks: [IPodTrack],
                                 key: (IPodTrack) -> (String, String)) -> GroupIDs {
        var result = GroupIDs()
        var seen: [String: UInt32] = [:]
        var next: UInt32 = 1
        for (i, t) in tracks.enumerated() {
            let (a, b) = key(t)
            let k = a.lowercased() + "\u{1F}" + b.lowercased()
            if let id = seen[k] {
                result.idFor[i] = id
            } else {
                seen[k] = next
                result.idFor[i] = next
                result.representative[next] = i
                result.order.append(next)
                next += 1
            }
        }
        return result
    }

    private static func writeMhbd(_ w: BinWriter, _ db: IPodDatabase, children: UInt32) {
        w.tag("mhbd")
        w.u32(244)                       // header size
        w.u32(0)                         // total size — patched at the end
        w.u32(1)                         // 1 on iPod classic (2 only on compressed-db devices)
        w.u32(0x30)                      // database version (iTunes 9.2)
        w.u32(children)
        w.u64(db.dbID)                                   // 0x18
        w.u16(db.platform)                               // 0x20
        w.u16(0)
        w.u64(db.id0x24)                                 // 0x24
        w.u32(0)
        w.u16(0)                                         // 0x30 hashing scheme (set by hash58)
        w.zeros(20)                                      // 0x32
        let lang = Array(db.language.utf8.prefix(2))
        w.u8(lang.count > 0 ? lang[0] : 0x65)            // 0x46 language
        w.u8(lang.count > 1 ? lang[1] : 0x6E)
        w.u64(db.libraryPID)                             // 0x48
        w.u32(db.unk0x50)                                // 0x50
        w.u32(db.unk0x54)
        w.zeros(20)                                      // 0x58 hash58 (filled by hash58)
        w.i32(Int32(TimeZone.current.secondsFromGMT()))  // 0x6c
        w.u16(0)                                         // 0x70 (0 = hash58-class device)
        w.u16(0)
        w.zeros(44)                                      // hash72 area
        w.zeros(10)                                      // 0xa0 audio/subtitle lang + unknowns
        w.u8(0)
        w.zeros(57)                                      // hashAB area
        w.pad(to: 244)
    }

    private static func writeMhsdHeader(_ w: BinWriter, type: UInt32) -> Int {
        let start = w.count
        w.tag("mhsd")
        w.u32(96)
        w.u32(0)         // total — patched by caller
        w.u32(type)
        w.zeros(80)
        return start
    }

    private static func writeListHeader(_ w: BinWriter, tag: String, count: UInt32) {
        w.tag(tag)       // mhlt / mhlp / mhla / mhli
        w.u32(92)
        w.u32(count)
        w.zeros(80)
    }

    private static func writeEmptyListSection(_ w: BinWriter, type: UInt32) {
        let start = writeMhsdHeader(w, type: type)
        writeListHeader(w, tag: "mhlt", count: 0)
        w.patchU32(UInt32(w.count - start), at: start + 8)
    }

    // MARK: mhsd type 1 — tracks

    private static func writeTracksSection(_ w: BinWriter, _ db: IPodDatabase,
                                           albums: GroupIDs, artists: GroupIDs) {
        let start = writeMhsdHeader(w, type: 1)
        writeListHeader(w, tag: "mhlt", count: UInt32(db.tracks.count))
        for (i, track) in db.tracks.enumerated() {
            writeMhit(w, db, track,
                      albumID: albums.idFor[i] ?? 0,
                      artistID: artists.idFor[i] ?? 0)
        }
        w.patchU32(UInt32(w.count - start), at: start + 8)
    }

    private static func writeMhit(_ w: BinWriter, _ db: IPodDatabase, _ t: IPodTrack,
                                  albumID: UInt32, artistID: UInt32) {
        let start = w.count
        w.tag("mhit")
        w.u32(0x248)                    // header size
        w.u32(0)                        // total — patched below
        w.u32(0)                        // mhod count — patched below
        w.u32(t.id)                     // +0x10
        w.u32(1)                        // visible
        w.u32(t.filetypeMarker)
        w.u8(0)                         // type1
        w.u8(0)                         // type2
        w.u8(0)                         // compilation
        w.u8(t.rating)
        w.u32(t.timeModified)           // +0x20
        w.u32(t.size)
        w.u32(t.lengthMS)
        w.u32(t.trackNr)
        w.u32(t.trackCount)             // +0x30
        w.u32(t.year)
        w.u32(t.bitrate)
        w.u32(t.samplerate << 16)
        w.u32(0)                        // +0x40 volume
        w.u32(0)                        // starttime
        w.u32(0)                        // stoptime
        w.u32(0)                        // soundcheck
        w.u32(t.playcount)              // +0x50
        w.u32(t.playcount)              // playcount2
        w.u32(0)                        // last played
        w.u32(t.cdNr)
        w.u32(t.cdCount)                // +0x60
        w.u32(0)                        // drm
        w.u32(t.timeAdded)
        w.u32(0)                        // bookmark
        w.u64(t.dbid)                   // +0x70
        w.u8(1)                         // checked
        w.u8(0)                         // app rating
        w.u16(0)                        // BPM
        w.u16(t.artworkCount)
        w.u16(0xFFFF)                   // unk126 (as written by iTunes)
        w.u32(t.artworkSize)            // +0x80
        w.u32(0)
        w.f32(Float(t.samplerate))
        w.u32(0)                        // released
        w.u16(0)                        // +0x90
        w.u16(0)                        // explicit
        w.u32(0)
        w.u32(0)
        w.u32(0)                        // skip count
        w.u32(0)                        // +0xA0 last skipped
        w.u8(t.hasArtwork)              // 1 = has artwork
        w.u8(0)                         // skip when shuffling
        w.u8(0)                         // remember position
        w.u8(0)                         // flag4
        w.u64(t.dbid)                   // dbid2
        w.u8(0)                         // +0xB0 lyrics
        w.u8(0)                         // movie
        w.u8(0)                         // mark unplayed (2 = played)
        w.u8(0)
        w.u32(0)
        w.u32(0)                        // pregap
        w.u64(0)                        // sample count
        w.u32(0)
        w.u32(0)                        // postgap
        w.u32(0)
        w.u32(1)                        // +0xD0 mediatype: 1 = audio
        w.u32(0)                        // season
        w.u32(0)                        // episode
        w.u32(0)
        w.zeros(16)                     // +0xE0
        w.zeros(8)                      // +0xF0 unk240/244
        w.u32(0)                        // gapless data
        w.u32(0)
        w.u16(0)                        // +0x100 gapless track flag
        w.u16(0)                        // gapless album flag
        w.zeros(28)
        w.u32(albumID)                  // +0x120
        w.u64(db.id0x24)
        w.u32(t.size)                   // filesize again
        w.u32(0)                        // +0x130
        w.u64(0x8080_8080_8080)
        w.u32(0)
        w.zeros(8)                      // +0x140
        w.u32(0)                        // (epub/pdf flags — audio: 0)
        w.zeros(20)
        w.u32(t.mhiiLink)               // +0x160 → mhii id in the ArtworkDB
        w.u32(0)
        w.u32(1)
        w.u32(0)
        w.zeros(112)                    // +0x170
        w.u32(artistID)                 // +0x1E0
        w.zeros(16)
        w.u32(0)                        // +0x1F4 composer id
        w.pad(to: start + 0x248)

        var mhodCount: UInt32 = 0
        func str(_ type: UInt32, _ s: String) {
            guard !s.isEmpty else { return }
            writeStringMhod(w, type: type, s)
            mhodCount += 1
        }
        str(1, t.title)
        str(4, t.artist)
        str(3, t.album)
        str(6, t.filetypeDescription)
        str(8, t.comment)
        str(2, t.ipodPath)
        str(5, t.genre)
        str(12, t.composer)
        str(22, t.albumArtist)
        if let sa = sortName(t.artist) { str(23, sa) }
        if let saa = sortName(t.albumArtist) { str(29, saa) }

        w.patchU32(UInt32(w.count - start), at: start + 8)
        w.patchU32(mhodCount, at: start + 12)
    }

    // "The Beatles" → "Beatles, The" followed by five 0x01 chars, like iTunes.
    private static func sortName(_ name: String) -> String? {
        guard name.lowercased().hasPrefix("the "), name.count > 4 else { return nil }
        return String(name.dropFirst(4)) + ", The\u{01}\u{01}\u{01}\u{01}\u{01}"
    }

    private static func writeStringMhod(_ w: BinWriter, type: UInt32, _ s: String) {
        let byteLen = UInt32(s.utf16.count * 2)
        w.tag("mhod")
        w.u32(24)
        w.u32(byteLen + 40)
        w.u32(type)
        w.zeros(8)
        w.u32(1)             // string type: UTF-16
        w.u32(byteLen)
        w.u32(1)
        w.u32(0)
        w.utf16(s)
    }

    // MARK: mhsd types 2/3/5 — playlists

    private static func writePlaylistsSection(_ w: BinWriter, _ db: IPodDatabase,
                                              type: UInt32, playlists: [IPodPlaylist]) {
        let start = writeMhsdHeader(w, type: type)
        let listStart = w.count
        writeListHeader(w, tag: "mhlp", count: UInt32(playlists.count))
        for pl in playlists {
            writeMhyp(w, db, pl)
        }
        w.patchU32(UInt32(playlists.count), at: listStart + 8)
        w.patchU32(UInt32(w.count - start), at: start + 8)
    }

    private static func writeMhyp(_ w: BinWriter, _ db: IPodDatabase, _ pl: IPodPlaylist) {
        let start = w.count
        let isFullMaster = pl.isMaster && !pl.memberIDs.isEmpty
        var mhodNum: UInt32 = 2                       // title + prefs
        if isFullMaster { mhodNum += 10 }             // 5 × [sort index + jump table]
        if pl.smartPrefMhod != nil { mhodNum += 1 }
        if pl.smartRulesMhod != nil { mhodNum += 1 }
        w.tag("mhyp")
        w.u32(108)
        w.u32(0)                        // total — patched
        w.u32(mhodNum)
        w.u32(UInt32(pl.memberIDs.count))
        w.u8(pl.isMaster ? 1 : 0)
        w.u8(0); w.u8(0); w.u8(0)
        w.u32(macTimeNow())
        w.u64(pl.id)
        w.u32(0)
        w.u16(1)                        // string mhod count
        w.u16(0)                        // podcast flag
        w.u32(pl.sortorder)
        w.zeros(60)

        writeStringMhod(w, type: 1, pl.name)
        writePlaylistPrefsMhod(w)
        if let pref = pl.smartPrefMhod { w.bytes(pref) }
        if let rules = pl.smartRulesMhod { w.bytes(rules) }

        if isFullMaster {
            writeSortIndexes(w, db, pl)
        }

        for (pos, trackID) in pl.memberIDs.enumerated() {
            let mhipStart = w.count
            w.tag("mhip")
            w.u32(76)
            w.u32(0)                    // total (incl. child mhod) — patched
            w.u32(1)                    // child count
            w.u32(0)                    // podcast group flag
            w.u32(0)                    // podcast group id
            w.u32(trackID)
            w.u32(0)                    // timestamp
            w.u32(0)                    // podcast group ref
            w.zeros(40)
            // child mhod type 100: position in playlist
            w.tag("mhod")
            w.u32(24)
            w.u32(44)
            w.u32(100)
            w.zeros(8)
            w.u32(UInt32(pos))
            w.zeros(16)
            w.patchU32(UInt32(w.count - mhipStart), at: mhipStart + 8)
        }
        w.patchU32(UInt32(w.count - start), at: start + 8)
    }

    // The fixed "preferences" mhod every playlist carries (columns shown in iTunes).
    private static func writePlaylistPrefsMhod(_ w: BinWriter) {
        let start = w.count
        w.tag("mhod")
        w.u32(0x18)
        w.u32(0x288)
        w.u32(100)
        w.zeros(24)
        w.u32(0x010084); w.u32(0x05); w.u32(0x09); w.u32(0x03); w.u32(0x120001)
        w.zeros(12)
        w.u32(0xc80002); w.zeros(12)
        w.u32(0x3c000d); w.zeros(12)
        w.u32(0x7d0004); w.zeros(12)
        w.u32(0x7d0003); w.zeros(12)
        w.u32(0x640008); w.zeros(12)
        w.u32(0x640017); w.u32(0x01); w.zeros(8)
        w.u32(0x500014); w.u32(0x01); w.zeros(8)
        w.u32(0x7d0015); w.u32(0x01); w.zeros(8)
        w.pad(to: start + 0x288)
    }

    // MARK: mhod 52/53 — library sort indexes for the master playlist

    private static func writeSortIndexes(_ w: BinWriter, _ db: IPodDatabase, _ pl: IPodPlaylist) {
        // sort type → key extractor
        let sorts: [(UInt32, (IPodTrack) -> String)] = [
            (0x03, { $0.title }),                                     // title
            (0x04, { "\($0.album)\u{1F}\($0.trackNr)" }),             // album
            (0x05, { "\($0.artist)\u{1F}\($0.album)\u{1F}\($0.trackNr)" }),
            (0x07, { "\($0.genre)\u{1F}\($0.artist)" }),              // genre
            (0x12, { "\($0.composer)\u{1F}\($0.title)" }),            // composer
        ]
        let indexByID: [UInt32: Int] = Dictionary(
            uniqueKeysWithValues: db.tracks.enumerated().map { ($0.element.id, $0.offset) })

        for (sortType, keyOf) in sorts {
            let order = pl.memberIDs.enumerated().sorted { a, b in
                let ta = db.tracks[indexByID[a.element] ?? 0]
                let tb = db.tracks[indexByID[b.element] ?? 0]
                return keyOf(ta).localizedCaseInsensitiveCompare(keyOf(tb)) == .orderedAscending
            }
            // mhod 52: playlist positions in sorted order
            w.tag("mhod")
            w.u32(24)
            w.u32(UInt32(4 * order.count + 72))
            w.u32(52)
            w.zeros(8)
            w.u32(sortType)
            w.u32(UInt32(order.count))
            w.zeros(40)
            var jump: [(letter: UInt16, start: UInt32, count: UInt32)] = []
            for (i, entry) in order.enumerated() {
                w.u32(UInt32(entry.offset))
                let track = db.tracks[indexByID[entry.element] ?? 0]
                let letter = firstSortLetter(primarySortString(track, sortType: sortType))
                if let last = jump.last, last.letter == letter {
                    jump[jump.count - 1].count += 1
                } else {
                    jump.append((letter, UInt32(i), 1))
                }
            }
            // mhod 53: letter jump table for the index above
            w.tag("mhod")
            w.u32(24)
            w.u32(UInt32(12 * jump.count + 40))
            w.u32(53)
            w.zeros(8)
            w.u32(sortType)
            w.u32(UInt32(jump.count))
            w.zeros(8)
            for entry in jump {
                w.u16(entry.letter)
                w.u16(0)
                w.u32(entry.start)
                w.u32(entry.count)
            }
        }
    }

    private static func primarySortString(_ t: IPodTrack, sortType: UInt32) -> String {
        switch sortType {
        case 0x04: return t.album
        case 0x05: return t.artist
        case 0x07: return t.genre
        case 0x12: return t.composer
        default: return t.title
        }
    }

    private static func firstSortLetter(_ s: String) -> UInt16 {
        s.uppercased().utf16.first ?? 0
    }

    // MARK: mhsd type 4 — albums, type 8 — artists

    private static func writeAlbumsSection(_ w: BinWriter, _ db: IPodDatabase, albums: GroupIDs) {
        let start = writeMhsdHeader(w, type: 4)
        writeListHeader(w, tag: "mhla", count: UInt32(albums.order.count))
        for groupID in albums.order {
            guard let ti = albums.representative[groupID] else { continue }
            let t = db.tracks[ti]
            let mhiaStart = w.count
            w.tag("mhia")
            w.u32(88)
            w.u32(0)                        // total — patched
            w.u32(0)                        // mhod count — patched
            w.u32(groupID)
            w.u64(UInt64.random(in: 1...UInt64.max))
            w.u32(2)
            w.zeros(56)
            var n: UInt32 = 0
            if !t.album.isEmpty { writeStringMhod(w, type: 200, t.album); n += 1 }
            let artist = t.albumArtist.isEmpty ? t.artist : t.albumArtist
            if !artist.isEmpty { writeStringMhod(w, type: 201, artist); n += 1 }
            w.patchU32(UInt32(w.count - mhiaStart), at: mhiaStart + 8)
            w.patchU32(n, at: mhiaStart + 12)
        }
        w.patchU32(UInt32(w.count - start), at: start + 8)
    }

    private static func writeArtistsSection(_ w: BinWriter, _ db: IPodDatabase, artists: GroupIDs) {
        let start = writeMhsdHeader(w, type: 8)
        writeListHeader(w, tag: "mhli", count: UInt32(artists.order.count))
        for groupID in artists.order {
            guard let ti = artists.representative[groupID] else { continue }
            let t = db.tracks[ti]
            let mhiiStart = w.count
            w.tag("mhii")
            w.u32(80)
            w.u32(0)                        // total — patched
            w.u32(0)                        // mhod count — patched
            w.u32(groupID)
            w.u64(UInt64.random(in: 1...UInt64.max))
            w.u32(2)
            w.zeros(48)
            var n: UInt32 = 0
            if !t.artist.isEmpty { writeStringMhod(w, type: 300, t.artist); n += 1 }
            w.patchU32(UInt32(w.count - mhiiStart), at: mhiiStart + 8)
            w.patchU32(n, at: mhiiStart + 12)
        }
        w.patchU32(UInt32(w.count - start), at: start + 8)
    }
}

// MARK: - hash58 checksum (iPod classic 6G/7G, nano 3G/4G)
// Ported from libgpod itdb_hash58.c (BSD license, Christophe Fergeau / wtbw).

enum Hash58 {

    private static let table1: [UInt8] = [
        0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5,
        0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
        0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0,
        0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
        0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC,
        0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
        0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A,
        0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
        0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0,
        0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
        0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B,
        0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
        0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85,
        0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
        0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5,
        0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
        0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17,
        0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
        0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88,
        0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
        0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C,
        0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
        0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9,
        0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
        0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6,
        0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
        0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E,
        0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
        0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94,
        0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
        0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68,
        0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
    ]

    private static let table2: [UInt8] = [
        0x52, 0x09, 0x6A, 0xD5, 0x30, 0x36, 0xA5, 0x38,
        0xBF, 0x40, 0xA3, 0x9E, 0x81, 0xF3, 0xD7, 0xFB,
        0x7C, 0xE3, 0x39, 0x82, 0x9B, 0x2F, 0xFF, 0x87,
        0x34, 0x8E, 0x43, 0x44, 0xC4, 0xDE, 0xE9, 0xCB,
        0x54, 0x7B, 0x94, 0x32, 0xA6, 0xC2, 0x23, 0x3D,
        0xEE, 0x4C, 0x95, 0x0B, 0x42, 0xFA, 0xC3, 0x4E,
        0x08, 0x2E, 0xA1, 0x66, 0x28, 0xD9, 0x24, 0xB2,
        0x76, 0x5B, 0xA2, 0x49, 0x6D, 0x8B, 0xD1, 0x25,
        0x72, 0xF8, 0xF6, 0x64, 0x86, 0x68, 0x98, 0x16,
        0xD4, 0xA4, 0x5C, 0xCC, 0x5D, 0x65, 0xB6, 0x92,
        0x6C, 0x70, 0x48, 0x50, 0xFD, 0xED, 0xB9, 0xDA,
        0x5E, 0x15, 0x46, 0x57, 0xA7, 0x8D, 0x9D, 0x84,
        0x90, 0xD8, 0xAB, 0x00, 0x8C, 0xBC, 0xD3, 0x0A,
        0xF7, 0xE4, 0x58, 0x05, 0xB8, 0xB3, 0x45, 0x06,
        0xD0, 0x2C, 0x1E, 0x8F, 0xCA, 0x3F, 0x0F, 0x02,
        0xC1, 0xAF, 0xBD, 0x03, 0x01, 0x13, 0x8A, 0x6B,
        0x3A, 0x91, 0x11, 0x41, 0x4F, 0x67, 0xDC, 0xEA,
        0x97, 0xF2, 0xCF, 0xCE, 0xF0, 0xB4, 0xE6, 0x73,
        0x96, 0xAC, 0x74, 0x22, 0xE7, 0xAD, 0x35, 0x85,
        0xE2, 0xF9, 0x37, 0xE8, 0x1C, 0x75, 0xDF, 0x6E,
        0x47, 0xF1, 0x1A, 0x71, 0x1D, 0x29, 0xC5, 0x89,
        0x6F, 0xB7, 0x62, 0x0E, 0xAA, 0x18, 0xBE, 0x1B,
        0xFC, 0x56, 0x3E, 0x4B, 0xC6, 0xD2, 0x79, 0x20,
        0x9A, 0xDB, 0xC0, 0xFE, 0x78, 0xCD, 0x5A, 0xF4,
        0x1F, 0xDD, 0xA8, 0x33, 0x88, 0x07, 0xC7, 0x31,
        0xB1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xEC, 0x5F,
        0x60, 0x51, 0x7F, 0xA9, 0x19, 0xB5, 0x4A, 0x0D,
        0x2D, 0xE5, 0x7A, 0x9F, 0x93, 0xC9, 0x9C, 0xEF,
        0xA0, 0xE0, 0x3B, 0x4D, 0xAE, 0x2A, 0xF5, 0xB0,
        0xC8, 0xEB, 0xBB, 0x3C, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2B, 0x04, 0x7E, 0xBA, 0x77, 0xD6, 0x26,
        0xE1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0C, 0x7D,
    ]

    private static let fixed: [UInt8] = [
        0x67, 0x23, 0xFE, 0x30, 0x45, 0x33, 0xF8, 0x90, 0x99,
        0x21, 0x07, 0xC1, 0xD0, 0x12, 0xB2, 0xA1, 0x07, 0x81,
    ]

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while true {
            a %= b
            if a == 0 { return b }
            b %= a
            if b == 0 { return a }
        }
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        if a == 0 || b == 0 { return 1 }
        return a * b / gcd(a, b)
    }

    private static func generateKey(firewireID: [UInt8]) -> [UInt8] {
        var y = [UInt8](repeating: 0, count: 16)
        for i in 0..<4 {
            let l = lcm(Int(firewireID[i * 2]), Int(firewireID[i * 2 + 1]))
            let hi = Int((l & 0xFF00) >> 8)
            let lo = Int(l & 0xFF)
            y[i * 4] = table1[hi]
            y[i * 4 + 1] = table2[hi]
            y[i * 4 + 2] = table1[lo]
            y[i * 4 + 3] = table2[lo]
        }
        var sha = Insecure.SHA1()
        sha.update(data: Data(fixed))
        sha.update(data: Data(y))
        var key = [UInt8](repeating: 0, count: 64)
        let digest = Array(sha.finalize())
        key.replaceSubrange(0..<digest.count, with: digest)
        return key
    }

    private static func computeHash(firewireID: [UInt8], itdb: Data) -> [UInt8] {
        var key = generateKey(firewireID: firewireID)
        for i in 0..<64 { key[i] ^= 0x36 }
        var sha = Insecure.SHA1()
        sha.update(data: Data(key))
        sha.update(data: itdb)
        let inner = Array(sha.finalize())

        for i in 0..<64 { key[i] ^= 0x36 ^ 0x5C }
        var sha2 = Insecure.SHA1()
        sha2.update(data: Data(key))
        sha2.update(data: Data(inner))
        return Array(sha2.finalize())
    }

    /// Parses "000A270013AB4C6D"-style FireWire GUIDs into 8 bytes.
    static func parseFireWireGUID(_ s: String) -> [UInt8]? {
        var hex = s.lowercased()
        if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        hex = hex.filter { $0.isHexDigit }
        guard hex.count >= 16 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<8 {
            let next = hex.index(index, offsetBy: 2)
            guard let b = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        return bytes
    }

    /// Zeroes the volatile mhbd fields, computes the checksum, and patches it
    /// into the database bytes at offset 0x58. Mirrors itdb_hash58_write_hash.
    static func apply(to itdb: inout Data, firewireGUID: String) throws {
        guard let fwid = parseFireWireGUID(firewireGUID) else {
            throw IPodDBError.missingFireWireGUID
        }
        guard itdb.count >= 0x6C else { throw IPodDBError.truncated }

        let base = itdb.startIndex
        let backupDBID = itdb.subdata(in: base + 0x18..<base + 0x20)
        let backup32 = itdb.subdata(in: base + 0x32..<base + 0x46)

        itdb.replaceSubrange(base + 0x18..<base + 0x20, with: Data(count: 8))
        itdb.replaceSubrange(base + 0x32..<base + 0x46, with: Data(count: 20))
        itdb.replaceSubrange(base + 0x58..<base + 0x6C, with: Data(count: 20))
        itdb[base + 0x30] = 1        // hashing scheme = hash58
        itdb[base + 0x31] = 0

        let digest = computeHash(firewireID: fwid, itdb: itdb)
        itdb.replaceSubrange(base + 0x58..<base + 0x58 + digest.count, with: digest)
        itdb.replaceSubrange(base + 0x18..<base + 0x20, with: backupDBID)
        itdb.replaceSubrange(base + 0x32..<base + 0x46, with: backup32)
    }
}
