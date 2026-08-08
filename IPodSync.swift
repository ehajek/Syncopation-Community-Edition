// IPodSync.swift — writing music to an iPod.
//
// The Community Edition only ever adds: files are copied on, registered in the
// iPod's library, and nothing is removed. Clearing a device is a separate,
// deliberate action (the Erase button).
//
// Copyright (C) 2026 Eddie Hajek
// Licensed under the GNU General Public License v3.0 — see the LICENSE file.

import Foundation
import AppKit

/// Formats an iPod plays directly; FLAC is converted to Apple Lossless.
let ipodDirectExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif"]
let ipodConvertExtensions: Set<String> = ["flac"]

/// Whether an iPod can play Apple Lossless. Newer devices publish their codec
/// list; the first two generations of the original iPod predate the format
/// entirely, so converting FLAC for them would produce files they can't decode.
func iPodPlaysALAC(volume: String, family: String) -> Bool {
    if let text = try? String(contentsOfFile: volume + "/iPod_Control/Device/SysInfoExtended",
                              encoding: .utf8) {
        return text.contains("<key>AppleLossless</key>")
    }
    for old in ["iPod (1st gen)", "iPod (2nd gen)"] where family.hasPrefix(old) { return false }
    return true
}

extension SyncModel {

    // MARK: - Writing the library

    /// Saves the database with a backup, and the checksum the device requires.
    /// The new file is written first and the old one renamed aside, so the iPod
    /// is never left without a usable library.
    func writeIPodDatabase(_ db: IPodDatabase, to ipod: IPodDevice) throws {
        let fm = FileManager.default
        let path = ipod.volumePath + "/iPod_Control/iTunes/iTunesDB"
        var data = ITunesDBWriter.serialize(db)
        if ipod.needsHashedDB {
            try Hash58.apply(to: &data, firewireGUID: ipod.firewireGUID ?? "")
        }
        let tmp = path + ".syncopation.new"
        try? fm.removeItem(atPath: tmp)
        try data.write(to: URL(fileURLWithPath: tmp))

        let bak = path + ".syncopation.bak"
        if fm.fileExists(atPath: path) {
            let oldBak = bak + ".prev"
            try? fm.removeItem(atPath: oldBak)
            if fm.fileExists(atPath: bak) { try? fm.moveItem(atPath: bak, toPath: oldBak) }
            do {
                try fm.moveItem(atPath: path, toPath: bak)
            } catch {
                if fm.fileExists(atPath: oldBak) { try? fm.moveItem(atPath: oldBak, toPath: bak) }
                try? fm.removeItem(atPath: tmp)
                throw error
            }
            try? fm.removeItem(atPath: oldBak)
        }
        do {
            try fm.moveItem(atPath: tmp, toPath: path)
        } catch {
            if fm.fileExists(atPath: bak), !fm.fileExists(atPath: path) {
                try? fm.copyItem(atPath: bak, toPath: path)
            }
            throw error
        }
    }

    /// Every audio file in the iPod's hidden music folders.
    func ipodMusicFiles(volume: String) -> [String] {
        let fm = FileManager.default
        let root = volume + "/iPod_Control/Music"
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var files: [String] = []
        for dir in dirs where dir.hasPrefix("F") {
            for name in (try? fm.contentsOfDirectory(atPath: root + "/" + dir)) ?? []
            where !name.hasPrefix(".") {
                files.append(root + "/" + dir + "/" + name)
            }
        }
        return files
    }

    // MARK: - Interrupted transfers
    //
    // If the iPod goes away mid-copy, the files already written aren't in its
    // library yet: unplayable, invisible, and copied again next time. Each one
    // is noted as it lands so the next sync can clear the debris.

    func copyJournalPath(volume: String) -> String {
        volume + "/iPod_Control/Syncopation/inflight.txt"
    }

    func openCopyJournal(volume: String) -> FileHandle? {
        let path = copyJournalPath(volume: volume)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return nil }
        h.seekToEndOfFile()
        return h
    }

    func recordCopy(_ destPath: String, journal: FileHandle?) {
        guard let journal, let data = (destPath + "\n").data(using: .utf8) else { return }
        journal.write(data)
    }

    func resetCopyJournal(_ journal: FileHandle?) {
        guard let journal else { return }
        try? journal.truncate(atOffset: 0)
        try? journal.seek(toOffset: 0)
    }

    /// Deletes files an interrupted sync copied but never registered. Only
    /// files this app recorded are touched — never music another program put
    /// on the device.
    func reclaimInterruptedCopies(ipod: IPodDevice, db: IPodDatabase) {
        let fm = FileManager.default
        let path = copyJournalPath(volume: ipod.volumePath)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var referenced = Set<String>()
        for t in db.tracks {
            referenced.insert(ipod.volumePath + t.ipodPath.replacingOccurrences(of: ":", with: "/"))
        }
        var deleted = 0
        var freed: Int64 = 0
        for line in text.split(separator: "\n") {
            let p = String(line)
            guard !p.isEmpty, !referenced.contains(p), fm.fileExists(atPath: p) else { continue }
            let size = Int64((try? fm.attributesOfItem(atPath: p))?[.size] as? Int64 ?? 0)
            if (try? fm.removeItem(atPath: p)) != nil { deleted += 1; freed += size }
        }
        try? fm.removeItem(atPath: path)
        if deleted > 0 {
            log("Tidied up after an interrupted sync: removed \(deleted) leftover file"
                + "\(deleted == 1 ? "" : "s"), \(String(format: "%.1f", Double(freed) / 1e9)) GB "
                + "reclaimed. Those tracks are copied again below.")
        }
    }

    /// True while the iPod is still mounted.
    func iPodStillConnected(_ ipod: IPodDevice) -> Bool {
        FileManager.default.fileExists(atPath: ipod.volumePath + "/iPod_Control/iTunes")
    }

    // MARK: - Helpers

    func tagKey(title: String, artist: String, album: String) -> String {
        title.lowercased() + "|" + artist.lowercased() + "|" + album.lowercased()
    }

    func ensureMusicDirs(root: String) throws {
        for i in 0..<50 {
            try FileManager.default.createDirectory(atPath: root + String(format: "/F%02d", i),
                                                    withIntermediateDirectories: true)
        }
    }

    /// Copies a file into a random F## folder under an iTunes-style name.
    func placeOnIPod(fileAt url: URL, musicRoot: String, ext: String) throws -> URL {
        let fm = FileManager.default
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        while true {
            let dir = String(format: "F%02d", Int.random(in: 0..<50))
            let name = String((0..<4).map { _ in letters.randomElement()! }) + "." + ext
            let dest = URL(fileURLWithPath: musicRoot)
                .appendingPathComponent(dir).appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: url, to: dest)
                return dest
            }
        }
    }

    /// "/Volumes/iPod/iPod_Control/Music/F08/XQZR.m4a" → ":iPod_Control:Music:F08:XQZR.m4a"
    func ipodPathString(for destURL: URL, volume: String) -> String {
        String(destURL.path.dropFirst(volume.count)).replacingOccurrences(of: "/", with: ":")
    }

    func ipodFiletype(ext: String, converted: Bool) -> (marker: UInt32, description: String) {
        func fourCC(_ s: String) -> UInt32 {
            var v: UInt32 = 0
            for c in s.utf8.prefix(4) { v = (v << 8) | UInt32(c) }
            return v
        }
        switch ext {
        case "mp3": return (fourCC("MP3 "), "MPEG audio file")
        case "m4a": return (fourCC("M4A "), converted ? "Apple Lossless audio file" : "MPEG-4 audio file")
        case "m4b": return (fourCC("M4B "), "Audiobook file")
        case "aac": return (fourCC("AAC "), "AAC audio file")
        case "wav": return (fourCC("WAV "), "WAV audio file")
        case "aiff", "aif": return (fourCC("AIFF"), "AIFF audio file")
        default: return (fourCC("M4A "), "Audio file")
        }
    }
}
