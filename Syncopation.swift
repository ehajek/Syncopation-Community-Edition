// Syncopation — Community Edition.
//
// A native macOS app that copies music, books, or any files onto an SD card,
// a folder, or an iPod. It only ever ADDS: nothing is deleted by syncing.
// Clearing a destination is a separate, deliberate action — the Erase button.
//
// Copyright (C) 2026 Eddie Hajek
// Licensed under the GNU General Public License v3.0 — see the LICENSE file.

import SwiftUI
import QuartzCore
import AppKit
import IOKit
import IOKit.usb

// The release codename, macOS-style. Repairs inherit the family name —
// 1.0.x is still Origen. Shown in the About panel next to the version.
// Codenames track the version number, not the feature set — 1.0 and 1.0.1
// were Origen in both editions, so 1.1 is Podification in both even though
// the podcast filing itself is Pro-only.
let versionCodename = "Podification"

let junkNames: Set<String> = [".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd"]

let musicExtensions: Set<String> = [
    "mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif",
    "ogg", "opus", "wma", "ape", "dsf", "dff",
]
let bookExtensions: Set<String> = ["epub", "pdf"]

enum SyncMode: String, CaseIterable, Identifiable {
    case music, books, all, ipod
    var id: String { rawValue }

    var label: String {
        switch self {
        case .music: return "Music"
        case .books: return "ePUB/PDF"
        case .all: return "All Files"
        case .ipod: return "iPod"
        }
    }

    var details: String {
        switch self {
        case .music:
            return "Music copies audio files only — MP3, M4A/M4B, AAC, FLAC, WAV, AIFF, "
                + "OGG, Opus, WMA, APE, DSF, DFF — keeping your folder structure. "
                + "Everything else is skipped."
        case .books:
            return "ePUB/PDF copies books and documents only — ePUB and PDF — keeping "
                + "your folder structure."
        case .all:
            return "All Files copies everything in the source folder, no filtering."
        case .ipod:
            return "iPod loads music onto an iPod in disk mode. FLAC is converted to "
                + "ALAC (Apple Lossless) automatically; MP3, AAC and ALAC copy as-is. "
                + "Tracks are registered in the iPod's library so they play as soon "
                + "as you eject. Syncing only ADDS music — it never deletes anything "
                + "from the iPod."
        }
    }

    /// nil means no filtering.
    var allowedExtensions: Set<String>? {
        switch self {
        case .music, .ipod: return musicExtensions
        case .books: return bookExtensions
        case .all: return nil
        }
    }
}


// MARK: - Facts a restore can't erase
//
// Restoring an iPod deletes SysInfoExtended, taking the serial number, the
// model, the DBVersion and the FireWire GUID with it. Finder and Music only
// write that file during a sync, so a just-restored device — the usual state
// of a fresh flash mod or a second-hand iPod — arrives anonymous. Guessing
// that no checksum is needed would write a library the device rejects, which
// looks to the owner exactly like a bricked iPod. Both facts are therefore
// taken from the hardware instead.

/// Every iPod attached over USB, with its FireWire GUID and product id. An
/// iPod reports its GUID as its USB serial number. Uses IOKit directly rather
/// than spawning a tool.
func attachedIPods() -> [(guid: String, productID: Int)] {
    var found: [(guid: String, productID: Int)] = []
    guard let matching = IOServiceMatching("IOUSBHostDevice") else { return found }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else { return found }
    defer { IOObjectRelease(iterator) }
    while case let device = IOIteratorNext(iterator), device != 0 {
        defer { IOObjectRelease(device) }
        guard let product = IORegistryEntryCreateCFProperty(
                device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
              product.localizedCaseInsensitiveContains("ipod") else { continue }
        guard let serial = IORegistryEntryCreateCFProperty(
                device, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
              serial.count == 16, serial.allSatisfy(\.isHexDigit) else { continue }
        let pid = IORegistryEntryCreateCFProperty(
            device, "idProduct" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int ?? 0
        found.append((serial, pid))
    }
    return found
}

/// Families confirmed against real hardware. Only verified entries are listed:
/// a guessed table would name devices wrongly, which is worse than not naming
/// them at all.
private let ipodUSBProductFamilies: [Int: String] = [
    0x1261: "iPod classic",
]

/// The hashing scheme declared by a library already on the iPod — the device's
/// own verdict on what it will accept, and the one source a restore leaves
/// intact. Returns nil when there is no readable library yet.
func hashSchemeOfExistingDatabase(volume: String) -> Int? {
    let path = volume + "/iPod_Control/iTunes/iTunesDB"
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: 0x40), head.count >= 0x32,
          head.prefix(4).elementsEqual("mhbd".utf8) else { return nil }
    let base = head.startIndex
    return Int(head[base + 0x30]) | (Int(head[base + 0x31]) << 8)
}

struct SourceFile {
    let url: URL
    let relativePath: String
    let size: Int64
}

// MARK: - Finding and identifying iPods

struct IPodDevice: Identifiable, Equatable {
    let volumePath: String
    let name: String
    let family: String
    let serial: String?
    let dbVersion: Int?
    let needsHashedDB: Bool
    let isShuffle: Bool
    let firewireGUID: String?
    let capacity: Int64
    let free: Int64

    var id: String { volumePath }

    /// Tint for the device icon, taken from the model's own colour.
    var shellColor: Color {
        let f = family.lowercased()
        if f.contains("black") { return .black }
        if f.contains("silver") || f.contains("stainless") { return .gray }
        if f.contains("blue") { return .blue }
        if f.contains("green") { return .green }
        if f.contains("pink") { return .pink }
        if f.contains("purple") { return .purple }
        if f.contains("orange") { return .orange }
        if f.contains("red") { return .red }
        if f.contains("yellow") || f.contains("gold") { return .yellow }
        return .secondary
    }

    var unsupportedReason: String? {
        if isShuffle {
            return "the iPod shuffle uses a different library format, which this app doesn't write"
        }
        if let v = dbVersion, v >= 4 {
            return "this iPod uses a library format this app doesn't write"
        }
        return nil
    }

    /// Name for the device picker. Drops the model's *stock* capacity: an
    /// iPod whose drive has been replaced advertising its original size is
    /// worse than useless. Real size is on the Capacity meter, measured.
    var pickerFamily: String {
        family.replacingOccurrences(
            of: #"\s+\d+(\.\d+)?\s*(GB|MB|TB)"#,
            with: "", options: .regularExpression)
    }

    var summary: String {
        let cap = ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
        let fr = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        if let reason = unsupportedReason {
            return "Not supported: \(family) “\(name)” — \(reason)."
        }
        var s = "Found: \(family) “\(name)” · \(cap), \(fr) free"
        if let serial { s += " · SN \(serial)" }
        return s
    }
}

private func sysInfoValue(_ key: String, in text: String, tag: String) -> String? {
    guard let r = text.range(of: "<key>\(key)</key>") else { return nil }
    let after = text[r.upperBound...].prefix(200)
    guard let o = after.range(of: "<\(tag)>"), let c = after.range(of: "</\(tag)>") else { return nil }
    return String(after[o.upperBound..<c.lowerBound])
}

private func identify(serial: String?, modelNumber: String) -> IPodModelInfo? {
    if let serial, serial.count >= 3,
       let hit = ipodSerialModels[String(serial.suffix(3)).uppercased()] { return hit }
    var num = modelNumber.uppercased()
    if num.hasPrefix("X") { num = String(num.dropFirst()) }
    if num.hasPrefix("M") { num = String(num.dropFirst()) }
    if num.count >= 4, let hit = ipodNumberModels[String(num.prefix(4))] { return hit }
    return nil
}

/// An iPod in disk mode is a volume with iPod_Control/Device on it.
func detectIPods() -> [IPodDevice] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                  .volumeAvailableCapacityKey]
    let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                    options: [.skipHiddenVolumes]) ?? []
    var found: [IPodDevice] = []
    for vol in urls where vol.path.hasPrefix("/Volumes/") {
        let device = vol.appendingPathComponent("iPod_Control/Device")
        let sysInfo = device.appendingPathComponent("SysInfo").path
        let sysInfoExtended = device.appendingPathComponent("SysInfoExtended").path
        guard fm.fileExists(atPath: sysInfo) || fm.fileExists(atPath: sysInfoExtended)
        else { continue }

        var model = "", guid: String? = nil, serial: String? = nil
        var dbVersion: Int? = nil

        // Plain key: value text, written by the iPod itself. Often empty.
        if let text = try? String(contentsOfFile: sysInfo, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if key == "ModelNumStr" { model = value }
                if key.lowercased() == "firewireguid" { guid = value }
                if key == "pszSerialNumber" { serial = value }
            }
        }
        // XML written by iTunes/Music — not always valid XML, so scanned as text.
        if let text = try? String(contentsOfFile: sysInfoExtended, encoding: .utf8) {
            if model.isEmpty { model = sysInfoValue("ModelNumStr", in: text, tag: "string") ?? "" }
            if guid == nil { guid = sysInfoValue("FireWireGUID", in: text, tag: "string") }
            serial = sysInfoValue("SerialNumber", in: text, tag: "string") ?? serial
            dbVersion = sysInfoValue("DBVersion", in: text, tag: "integer").flatMap(Int.init)
        }
        if model.hasPrefix("x") { model = String(model.dropFirst()) }

        // What this device accepts, most trustworthy first: a library already
        // on it, then DBVersion, then the mere presence of SysInfoExtended
        // (which only 2007-and-later iPods have).
        let hashed = hashSchemeOfExistingDatabase(volume: vol.path).map { $0 >= 1 }
            ?? dbVersion.map { $0 >= 3 }
            ?? fm.fileExists(atPath: sysInfoExtended)

        // A restore takes the GUID with it; the device still reports it over
        // USB, and without it a checksummed iPod can't be written to at all.
        let attached = attachedIPods()
        if guid == nil, hashed, attached.count == 1 { guid = attached.first?.guid }

        var hit = identify(serial: serial, modelNumber: model)
        if hit == nil, let guid,
           let pid = attached.first(where: { $0.guid == guid })?.productID,
           let usbFamily = ipodUSBProductFamilies[pid] {
            hit = IPodModelInfo(display: usbFamily, isShuffle: false)
        }
        let values = try? vol.resourceValues(forKeys: Set(keys))
        found.append(IPodDevice(
            volumePath: vol.path,
            name: values?.volumeName ?? vol.lastPathComponent,
            family: hit?.display ?? "iPod",
            serial: serial,
            dbVersion: dbVersion,
            // DBVersion decides: 3 and up need the checksummed library. Without
            // the key, only 2007-and-later devices have SysInfoExtended at all.
            needsHashedDB: hashed,
            isShuffle: hit?.isShuffle ?? false,
            firewireGUID: guid,
            capacity: Int64(values?.volumeTotalCapacity ?? 0),
            free: Int64(values?.volumeAvailableCapacity ?? 0)))
    }
    return found.sorted { $0.name < $1.name }
}

// MARK: - Model

/// Used-versus-total for the destination, formatted for the Capacity meter.
struct DestCapacity {
    let used: Int64
    let total: Int64

    var fraction: Double {
        total > 0 ? min(1, max(0, Double(used) / Double(total))) : 0
    }

    /// "109/477 GB · 23%" — decimal GB, matching what the Finder reports.
    var text: String {
        let useTB = Double(total) / 1_000_000_000 >= 1000
        let scale = useTB ? 1000.0 : 1.0
        func n(_ bytes: Int64) -> String {
            let v = Double(bytes) / 1_000_000_000 / scale
            return v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        }
        return "\(n(used))/\(n(total)) \(useTB ? "TB" : "GB") · \(Int((fraction * 100).rounded()))%"
    }
}

final class SyncModel: ObservableObject {
    @Published var sourcePath: String
    @Published var destPath: String
    @Published var volumes: [String] = []
    @Published var ipods: [IPodDevice] = []
    @Published var selectedIPod: IPodDevice?
    @Published var logText = ""
    // Synco-pod: how iPod-mode syncs file their tracks. Deliberately not
    // persisted — filing is a per-run decision, and Music each launch is the
    // safe default.
    @Published var syncMediaKind: IPodMediaKind = .music
    @Published var status = "Ready."
    @Published var running = false {
        didSet {
            // Hold off idle sleep while a sync runs. A long first sync left
            // unattended must not have the Mac doze off mid-copy — sleep cuts
            // USB power and takes the iPod with it. Display sleep stays
            // allowed; only the system itself is kept awake.
            guard running != oldValue else { return }
            if running {
                syncActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "Syncing music")
            } else {
                if let activity = syncActivity {
                    ProcessInfo.processInfo.endActivity(activity)
                    syncActivity = nil
                }
                announceFinish()
            }
            if running { runStarted = Date() }
        }
    }
    private var syncActivity: NSObjectProtocol?
    private var runStarted: Date?

    /// A long sync is something you walk away from, so say when it's over —
    /// in the user's own alert sound, at their volume, and silently if they
    /// have turned interface sounds off. A run that finished while you were
    /// still watching it doesn't need announcing, and a run that failed needs
    /// announcing just as much as one that worked.
    private func announceFinish() {
        defer { runStarted = nil }
        guard UserDefaults.standard.object(forKey: finishSoundKey) as? Bool ?? true,
              let started = runStarted,
              Date().timeIntervalSince(started) >= finishSoundFloor else { return }
        NSSound.beep()
    }
    @Published var done: Double = 0
    @Published var total: Double = 0
    @Published var mode: SyncMode { didSet {
        defaults.set(mode.rawValue, forKey: "syncMode")
        if mode == .ipod { refreshIPods() }
    } }

    /// How full the thing we're copying to is. Read fresh from whichever
    /// destination the current mode points at, so one meter serves every mode.
    var destCapacity: DestCapacity? {
        if mode == .ipod {
            guard let pod = selectedIPod, pod.capacity > 0 else { return nil }
            return DestCapacity(used: pod.capacity - pod.free, total: pod.capacity)
        }
        let path = destPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty,
              let values = try? URL(fileURLWithPath: path).resourceValues(
                  forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        return DestCapacity(used: Int64(total) - free, total: Int64(total))
    }

    var cancelled = false
    private let defaults = UserDefaults.standard

    init() {
        sourcePath = defaults.string(forKey: "source") ?? ""
        destPath = defaults.string(forKey: "destination") ?? ""
        mode = SyncMode(rawValue: defaults.string(forKey: "syncMode") ?? "") ?? .music
        refreshVolumes()
        refreshIPods()
    }

    func refreshVolumes() {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.map(\.path).filter { $0.hasPrefix("/Volumes/") }.sorted()
    }

    func refreshIPods() {
        ipods = detectIPods()
        if let current = selectedIPod,
           let match = ipods.first(where: { $0.volumePath == current.volumePath }) {
            selectedIPod = match
        } else if let saved = defaults.string(forKey: "ipodVolume"),
                  let match = ipods.first(where: { $0.volumePath == saved }) {
            selectedIPod = match
        } else {
            selectedIPod = ipods.count == 1 ? ipods.first : nil
        }
    }

    func selectIPod(_ pod: IPodDevice) {
        selectedIPod = pod
        defaults.set(pod.volumePath, forKey: "ipodVolume")
    }

    func chooseFolder(message: String, initial: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !initial.isEmpty { panel.directoryURL = URL(fileURLWithPath: initial) }
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }

    func cancel() {
        cancelled = true
        status = "Stopping…"
    }

    // MARK: Eject

    private var ejectTargetPath: String {
        mode == .ipod ? (selectedIPod?.volumePath ?? "")
                      : destPath.trimmingCharacters(in: .whitespaces)
    }

    var destIsEjectable: Bool { ejectTargetPath.hasPrefix("/Volumes/") }

    func eject() {
        let path = ejectTargetPath
        guard path.hasPrefix("/Volumes/") else {
            alert("The destination isn't a removable disk, so there's nothing to eject.")
            return
        }
        let url = URL(fileURLWithPath: path)
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? url
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            status = "Ejected \(volume.lastPathComponent) — safe to unplug."
            refreshVolumes()
            refreshIPods()
        } catch {
            alert("Could not eject \(volume.lastPathComponent): \(error.localizedDescription)\n\n"
                + "Make sure no other app is using it.")
        }
    }

    // MARK: Worker plumbing

    func post(_ update: @escaping () -> Void) { DispatchQueue.main.async(execute: update) }
    func log(_ line: String) { post { self.logText += line + "\n" } }

    func finish(_ summary: String) {
        post {
            // The status line is one line: it gets the headline, and the full
            // report always lands in the log where there's room for it.
            self.status = Self.headline(of: summary)
            self.logText += summary + "\n"
            self.running = false
            self.done = 0
            self.total = 0
            // Free space has just changed; re-read it so the Capacity meter
            // isn't still showing what was true before the copy.
            if self.mode == .ipod { self.refreshIPods() }
        }
    }

    /// First sentence of a report, collapsed to a single line.
    static func headline(of text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let stop = flat.range(of: ". ") else { return flat }
        return String(flat[flat.startIndex..<stop.lowerBound]) + "."
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Syncopation"
        a.informativeText = text
        a.runModal()
    }

    private func scan(_ rootURL: URL, allowed: Set<String>?) -> [SourceFile] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var files: [SourceFile] = []
        let basePath = rootURL.standardizedFileURL.path
        guard let e = fm.enumerator(at: rootURL, includingPropertiesForKeys: Array(keys),
                                    options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e {
            if cancelled { return files }
            let name = url.lastPathComponent
            if junkNames.contains(name) || name.hasPrefix("._") { continue }
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true
            else { continue }
            if let allowed, !allowed.contains(url.pathExtension.lowercased()) { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(basePath + "/") else { continue }
            files.append(SourceFile(url: url,
                                    relativePath: String(full.dropFirst(basePath.count + 1)),
                                    size: Int64(v.fileSize ?? 0)))
        }
        return files
    }

    // MARK: - Sync (adds only)

    func start(dryRun: Bool) {
        if mode == .ipod { startIPod(dryRun: dryRun); return }
        let fm = FileManager.default
        let src = sourcePath.trimmingCharacters(in: .whitespaces)
        let dst = destPath.trimmingCharacters(in: .whitespaces)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else {
            alert("Please choose a valid source folder."); return
        }
        guard fm.fileExists(atPath: dst, isDirectory: &isDir), isDir.boolValue else {
            alert("Please choose a valid destination — is the card or drive plugged in?"); return
        }
        let realSrc = URL(fileURLWithPath: src).resolvingSymlinksInPath().path
        let realDst = URL(fileURLWithPath: dst).resolvingSymlinksInPath().path
        guard realDst != realSrc, !realDst.hasPrefix(realSrc + "/"), !realSrc.hasPrefix(realDst + "/")
        else {
            alert("Source and destination can't be the same folder, or inside each other."); return
        }
        defaults.set(src, forKey: "source")
        defaults.set(dst, forKey: "destination")
        beginRun(dryRun ? "Checking…" : "Scanning…")
        let allowed = mode.allowedExtensions
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            runFolder(src: src, dst: dst, dryRun: dryRun, allowed: allowed)
        }
    }

    private func beginRun(_ status: String) {
        logText = ""
        done = 0
        total = 0
        cancelled = false
        running = true
        self.status = status
    }

    private func runFolder(src: String, dst: String, dryRun: Bool, allowed: Set<String>?) {
        let fm = FileManager.default
        let files = scan(URL(fileURLWithPath: src), allowed: allowed)
        if cancelled { finish("Stopped."); return }
        log("Found \(files.count) matching files in the source folder.")

        var todo: [SourceFile] = []
        var skipped = 0
        for f in files {
            if cancelled { finish("Stopped."); return }
            let destFile = dst + "/" + f.relativePath
            if let attrs = try? fm.attributesOfItem(atPath: destFile),
               let size = attrs[.size] as? Int64, size == f.size {
                skipped += 1
            } else {
                todo.append(f)
            }
        }
        let needed = todo.reduce(Int64(0)) { $0 + $1.size }
        let neededStr = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
        log("To copy: \(todo.count) files (\(neededStr)). Already there: \(skipped).")

        if dryRun {
            for f in todo { log("WOULD COPY  \(f.relativePath)") }
            finish("Check done — \(todo.count) files (\(neededStr)) would be copied.")
            return
        }
        var free = Int64.max
        if let attrs = try? fm.attributesOfFileSystem(forPath: dst),
           let f = attrs[.systemFreeSize] as? Int64 { free = f }
        if needed > free {
            finish("Not enough room: \(neededStr) to copy, only "
                 + "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free. "
                 + "Nothing was copied.")
            return
        }

        post { self.total = Double(todo.count) }
        var copied = 0, errors = 0
        for (i, f) in todo.enumerated() {
            if cancelled { finish("Stopped — \(copied) copied."); return }
            post {
                self.status = "Copying \u{201C}\((f.relativePath as NSString).lastPathComponent)\u{201D}"
                    + " \u{2014} \(i + 1) of \(todo.count)"
            }
            let destURL = URL(fileURLWithPath: dst).appendingPathComponent(f.relativePath)
            do {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                try fm.copyItem(at: f.url, to: destURL)
                copied += 1
                log("COPIED  \(f.relativePath)")
            } catch {
                errors += 1
                log("ERROR   \(f.relativePath): \(error.localizedDescription)")
            }
            let n = Double(i + 1)
            post { self.done = n }
        }
        var summary = "Done — \(copied) copied, \(skipped) already there"
        if errors > 0 { summary += ", \(errors) errors" }
        finish(summary + ".")
    }

    // MARK: - Sync to an iPod (adds only)

    private struct Manifest: Codable {
        var version = 1
        var entries: [String: Int64] = [:]   // source path → size
    }

    private func manifestPath(volume: String) -> String {
        volume + "/iPod_Control/Syncopation/manifest.json"
    }

    private func loadManifest(volume: String) -> Manifest {
        guard let d = FileManager.default.contents(atPath: manifestPath(volume: volume)),
              let m = try? JSONDecoder().decode(Manifest.self, from: d) else { return Manifest() }
        return m
    }

    private func saveManifest(_ m: Manifest, volume: String) {
        let path = manifestPath(volume: volume)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: URL(fileURLWithPath: path)) }
    }

    private func startIPod(dryRun: Bool) {
        let fm = FileManager.default
        let src = sourcePath.trimmingCharacters(in: .whitespaces)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else {
            alert("Please choose a valid source folder."); return
        }
        guard let ipod = selectedIPod else {
            alert("Select an iPod first — connect it in disk mode, then click Refresh."); return
        }
        guard fm.fileExists(atPath: ipod.volumePath + "/iPod_Control") else {
            refreshIPods()
            alert("“\(ipod.name)” doesn't seem to be plugged in any more."); return
        }
        if let reason = ipod.unsupportedReason {
            alert("Can't sync to \(ipod.name): \(reason)."); return
        }
        if ipod.needsHashedDB, ipod.firewireGUID == nil {
            alert("\(ipod.name) needs a checksummed library, but its device ID couldn't be read. "
                + "Sync it once with iTunes or Music, then try again."); return
        }
        defaults.set(src, forKey: "source")
        let kind = syncMediaKind        // read on the main thread, used on the worker
        beginRun(dryRun ? "Checking…" : "Scanning…")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            runIPod(src: src, ipod: ipod, dryRun: dryRun, kind: kind)
        }
    }

    private func runIPod(src: String, ipod: IPodDevice, dryRun: Bool, kind runMediaKind: IPodMediaKind) {
        let fm = FileManager.default
        log("Found iPod: “\(ipod.name)” — \(ipod.family)")
        log("Library: \(ipod.needsHashedDB ? "checksummed" : "standard")")

        let dbPath = ipod.volumePath + "/iPod_Control/iTunes/iTunesDB"
        var db: IPodDatabase
        var freshDB = false
        if fm.fileExists(atPath: dbPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dbPath)),
                  let parsed = try? ITunesDBParser.parse(data) else {
                finish("Could not read the iPod's library. Nothing was changed."); return
            }
            db = parsed
            log("Existing library: \(db.tracks.count) tracks — they're kept.")
        } else {
            db = IPodDatabase()
            freshDB = true
            log("No library yet — a new one will be created.")
        }
        reclaimInterruptedCopies(ipod: ipod, db: db)
        if db.masterPlaylistIndex == nil {
            var mpl = IPodPlaylist()
            mpl.isMaster = true
            mpl.name = ipod.name
            db.playlists.insert(mpl, at: 0)
        }

        var manifest = loadManifest(volume: ipod.volumePath)
        var known = Set(db.tracks.map { tagKey(title: $0.title, artist: $0.artist, album: $0.album) })
        let playsALAC = iPodPlaysALAC(volume: ipod.volumePath, family: ipod.family)
        if !playsALAC {
            log("This iPod is too old for Apple Lossless, so FLAC files are skipped — "
                + "MP3 and AAC copy as normal.")
        }

        let files = scan(URL(fileURLWithPath: src), allowed: musicExtensions)
        if cancelled { finish("Stopped."); return }
        log("Found \(files.count) music files in the source folder.")

        var todo: [(SourceFile, AudioMetadata, Bool)] = []
        var alreadySynced = 0, alreadyThere = 0, unplayable = 0
        for f in files {
            if cancelled { finish("Stopped."); return }
            let ext = (f.relativePath as NSString).pathExtension.lowercased()
            let convert: Bool
            if ipodConvertExtensions.contains(ext) {
                guard playsALAC else { unplayable += 1; continue }
                convert = true
            } else if ipodDirectExtensions.contains(ext) {
                convert = false
            } else { unplayable += 1; continue }

            if manifest.entries[f.relativePath] == f.size { alreadySynced += 1; continue }
            let meta = MetadataReader.read(url: f.url)
            if known.contains(tagKey(title: meta.title, artist: meta.artist, album: meta.album)) {
                alreadyThere += 1; continue
            }
            todo.append((f, meta, convert))
        }
        // Copied files cost their own size. Converted files cost what the
        // *output* will be: 16-bit stereo ALAC at an iPod-legal rate. For
        // CD-quality FLAC that's near the source size, but hi-res sources
        // shrink several-fold when downsampled — estimating those at source
        // size refused syncs that would have fit comfortably. When duration
        // is unknown, fall back to source size (the safe direction).
        let needed = todo.reduce(Int64(0)) { sum, item in
            let (file, meta, convert) = item
            guard convert, meta.durationMS > 0 else { return sum + file.size }
            let rate = AudioConverter.iPodSampleRate(for: meta.sampleRate)
            let pcm = Int64(meta.durationMS) / 1000 * Int64(rate) * 4  // 16-bit stereo
            return sum + min(pcm * 3 / 4, file.size)   // ALAC ≈ 75% of PCM, capped at source
        }
        let neededStr = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
        var free = Int64.max
        if let attrs = try? fm.attributesOfFileSystem(forPath: ipod.volumePath),
           let f = attrs[.systemFreeSize] as? Int64 { free = f }
        let freeStr = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        log("To add: \(todo.count) tracks (about \(neededStr)). \(freeStr) free on “\(ipod.name)”.")
        log("Skipped: \(alreadySynced) synced before, \(alreadyThere) already on the iPod, "
            + "\(unplayable) this iPod can't play.")
        log("Syncing only adds — nothing is ever deleted from the iPod.")

        if dryRun {
            for t in todo { log("WOULD \(t.2 ? "CONVERT" : "COPY   ")  \(t.0.relativePath)") }
            if needed > free { log("WARNING: this won't fit — \(neededStr) needed, \(freeStr) free.") }
            finish("Check done — \(todo.count) tracks (\(neededStr)) would be added.")
            return
        }
        if todo.isEmpty && !freshDB {
            finish("Nothing to do — “\(ipod.name)” already has this music.")
            return
        }
        if needed > free {
            finish("Not enough room on “\(ipod.name)”: \(neededStr) needed, \(freeStr) free. "
                 + "Nothing was copied.")
            return
        }

        let musicRoot = ipod.volumePath + "/iPod_Control/Music"
        do { try ensureMusicDirs(root: musicRoot) } catch {
            finish("Could not prepare the iPod: \(error.localizedDescription)"); return
        }

        post { self.total = Double(todo.count) }
        var added = 0, converted = 0, errors = 0
        var deviceLost = false
        var nextID = (db.tracks.map(\.id).max() ?? 51) + 1
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("syncopation", isDirectory: true)
        try? fm.removeItem(at: tmpDir)     // sweep leftovers from any interrupted run
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let journal = openCopyJournal(volume: ipod.volumePath)
        defer { try? journal?.close() }

        // ---- Pipelined conversion: a background worker converts ahead while
        // this loop copies to the iPod, so the CPU and the USB link work at
        // the same time instead of taking turns. Bounded lookahead keeps tmp
        // usage constant regardless of library size.
        let convertJobs: [ConversionPipeline.Job] = todo.enumerated().compactMap { i, item in
            guard item.2 else { return nil }
            return ConversionPipeline.Job(index: i, source: item.0.url,
                                          sampleRate: item.1.sampleRate,
                                          durationMS: item.1.durationMS)
        }
        let pipeline: ConversionPipeline? = convertJobs.isEmpty
            ? nil : ConversionPipeline(jobs: convertJobs, tmpDir: tmpDir)
        defer { pipeline?.stop() }

        // Adaptive time-remaining for the status line: project from the pace
        // so far once there is enough of it to mean anything.
        let syncStart = Date()
        func timeLeftString(_ seconds: TimeInterval) -> String {
            let m = Int(seconds / 60)
            if m >= 60 { return "\(m / 60) hr \(m % 60) min" }
            return m >= 2 ? "\(m) min" : "a minute or two"
        }

        for (i, item) in todo.enumerated() {
            if cancelled { break }
            // The iPod can go away mid-copy; stop rather than failing every
            // remaining file one by one.
            if i % 10 == 0, !iPodStillConnected(ipod) { deviceLost = true; break }
            let (file, meta, convert) = item
            // Say what's happening to which song, in words. The file path and
            // the outcome go to the log; the status line stays one sentence.
            let songLabel = meta.title.isEmpty
                ? (file.relativePath as NSString).lastPathComponent
                : meta.title
            var etaSuffix = ""
            if i >= 3 {
                let pace = Date().timeIntervalSince(syncStart) / Double(i)
                let remaining = pace * Double(todo.count - i)
                if remaining > 90 { etaSuffix = " \u{2014} about \(timeLeftString(remaining)) left" }
            }
            post {
                self.status = "\(convert ? "Converting" : "Copying") \u{201C}\(songLabel)\u{201D}"
                    + " \u{2014} \(i + 1) of \(todo.count)" + etaSuffix
            }
            // A converted file taken from the pipeline but not yet placed on
            // the iPod; the catch below releases it if the copy fails.
            var pipelineTicket: (url: URL, bytes: Int64)?
            do {
                var payload = file.url
                var ext = (file.relativePath as NSString).pathExtension.lowercased()
                if convert {
                    guard let pipeline else {
                        throw AudioConvertError.failed("the conversion pipeline is not running")
                    }
                    let result = pipeline.take(i)
                    if let error = result.error { throw error }
                    guard let url = result.url else {
                        throw AudioConvertError.failed("conversion produced no file")
                    }
                    pipelineTicket = (url, result.bytes)
                    payload = url
                    ext = "m4a"
                }
                // Filing: the per-sync tick, except .m4b which is an audiobook
                // on its own. Audiobooks ride the mp4 container onto the device
                // as .m4b — the extension the firmware's audiobook accounting
                // and bookmarking key on; mp3 stays mp3 (never bookmarkable,
                // under iTunes either).
                let srcExt = (file.relativePath as NSString).pathExtension.lowercased()
                let kind: IPodMediaKind = srcExt == "m4b" ? .audiobook : runMediaKind
                if kind == .audiobook, ext == "m4a" { ext = "m4b" }
                let dest = try placeOnIPod(fileAt: payload, musicRoot: musicRoot, ext: ext)
                recordCopy(dest.path, journal: journal)
                if let ticket = pipelineTicket {
                    try? fm.removeItem(at: ticket.url)
                    pipeline?.didConsume(bytes: ticket.bytes)
                    pipelineTicket = nil
                }
                let size = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int64)
                    ?? file.size

                var t = IPodTrack()
                t.id = nextID; nextID += 1
                t.dbid = UInt64.random(in: 1...UInt64.max)
                t.title = meta.title
                t.artist = meta.artist
                t.album = meta.album
                t.albumArtist = meta.albumArtist
                t.genre = meta.genre
                t.composer = meta.composer
                t.mediaKind = kind
                let ft = ipodFiletype(ext: ext, converted: convert)
                t.filetypeMarker = ft.marker
                t.filetypeDescription = ft.description
                t.ipodPath = ipodPathString(for: dest, volume: ipod.volumePath)
                t.size = UInt32(clamping: size)
                t.lengthMS = UInt32(clamping: meta.durationMS)
                t.trackNr = UInt32(clamping: meta.trackNr)
                t.trackCount = UInt32(clamping: meta.trackCount)
                t.cdNr = UInt32(clamping: meta.discNr)
                t.cdCount = UInt32(clamping: meta.discCount)
                t.year = UInt32(clamping: meta.year)
                var rate = meta.sampleRate
                if convert { rate = AudioConverter.iPodSampleRate(for: rate) }
                t.samplerate = UInt32(clamping: rate)
                if meta.durationMS > 0 {
                    t.bitrate = UInt32(clamping: Int(size) * 8 / meta.durationMS)
                }
                t.timeAdded = macTimeNow()
                t.timeModified = macTimeNow()

                db.tracks.append(t)
                manifest.entries[file.relativePath] = file.size
                known.insert(tagKey(title: t.title, artist: t.artist, album: t.album))
                added += 1
                if convert { converted += 1 }
                log("\(convert ? "CONVERTED" : "COPIED   ")  \(file.relativePath)")
            } catch {
                // Release a converted file the copy step never placed, so the
                // pipeline's budget isn't leaked by the failure.
                if let ticket = pipelineTicket {
                    try? fm.removeItem(at: ticket.url)
                    pipeline?.didConsume(bytes: ticket.bytes)
                }
                errors += 1
                log("ERROR      \(file.relativePath): \(error.localizedDescription)")
                if !iPodStillConnected(ipod) { deviceLost = true; break }
            }
            let n = Double(i + 1)
            post { self.done = n }
        }

        if deviceLost {
            post { self.refreshIPods() }
            finish("“\(ipod.name)” was unplugged during the sync — \(added) of \(todo.count) "
                 + "tracks had been copied, and they weren't added to the library. Plug it back "
                 + "in and sync again; the leftover files are tidied up automatically.")
            return
        }

        if added > 0 || freshDB {
            post { self.status = "Updating the iPod's library\u{2026}" }
            do {
                try writeIPodDatabase(db, to: ipod)
                saveManifest(manifest, volume: ipod.volumePath)
                resetCopyJournal(journal)
                log("Library updated: \(db.tracks.count) tracks.")
            } catch {
                finish("Copied \(added) files, but updating the library failed: "
                     + "\(error.localizedDescription) The previous library was kept.")
                return
            }
        }
        var summary = cancelled ? "Stopped — \(added) tracks added"
                                : "Done — \(added) tracks added (\(converted) converted)"
        summary += ", \(alreadySynced + alreadyThere) skipped"
        if errors > 0 { summary += ", \(errors) errors" }
        finish(summary + ". Eject the iPod before unplugging.")
    }

    // MARK: - Erase (a separate, deliberate action)

    func eraseDestination() {
        let fm = FileManager.default
        if mode == .ipod {
            guard let ipod = selectedIPod else {
                alert("Select an iPod first."); return
            }
            let count = ipodMusicFiles(volume: ipod.volumePath).count
            guard count > 0 else {
                alert("“\(ipod.name)” has no music on it — there's nothing to erase."); return
            }
            guard confirmErase(
                title: "Erase all music from “\(ipod.name)”?",
                body: """
                \(count) file\(count == 1 ? "" : "s") will be permanently deleted, including \
                music put there by other programs, and the iPod's library will be emptied.

                The iPod's own menus and settings are left alone, and nothing is copied \
                afterwards — this only erases. It can't be undone.
                """,
                button: "Erase") else { return }
            beginRun("Erasing…")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                eraseIPod(ipod)
            }
        } else {
            let dst = destPath.trimmingCharacters(in: .whitespaces)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dst, isDirectory: &isDir), isDir.boolValue else {
                alert("Choose a valid destination first."); return
            }
            let items = ((try? fm.contentsOfDirectory(atPath: dst)) ?? [])
                .filter { !junkNames.contains($0) }
            guard !items.isEmpty else {
                alert("“\(dst)” is already empty."); return
            }
            guard confirmErase(
                title: "Erase everything in “\(dst)”?",
                body: """
                \(items.count) item\(items.count == 1 ? "" : "s") will be permanently deleted — \
                every file and folder inside, not just the types this mode syncs.

                Deleted items don't go to the Trash, nothing is copied afterwards, and this \
                can't be undone.
                """,
                button: "Erase") else { return }
            beginRun("Erasing…")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var deleted = 0, failed = 0
                for name in items {
                    if cancelled { break }
                    do { try fm.removeItem(atPath: dst + "/" + name); deleted += 1 }
                    catch { failed += 1; log("ERROR   could not delete \(name)") }
                }
                finish("Done — \(deleted) items deleted"
                     + (failed > 0 ? ", \(failed) could not be removed." : "."))
            }
        }
    }

    private func eraseIPod(_ ipod: IPodDevice) {
        let fm = FileManager.default
        // Empty the library first: if that fails, the music is still listed and
        // playable rather than orphaned.
        var db = IPodDatabase()
        if let data = try? Data(contentsOf: URL(fileURLWithPath:
                ipod.volumePath + "/iPod_Control/iTunes/iTunesDB")),
           let existing = try? ITunesDBParser.parse(data) {
            db = existing
            db.tracks = []
            for i in db.playlists.indices { db.playlists[i].memberIDs = [] }
            for i in db.mhsd5Playlists.indices { db.mhsd5Playlists[i].memberIDs = [] }
        }
        if db.masterPlaylistIndex == nil {
            var mpl = IPodPlaylist()
            mpl.isMaster = true
            mpl.name = ipod.name
            db.playlists.insert(mpl, at: 0)
        }
        do { try writeIPodDatabase(db, to: ipod) } catch {
            finish("Could not empty the iPod's library: \(error.localizedDescription). "
                 + "Nothing was deleted."); return
        }
        let files = ipodMusicFiles(volume: ipod.volumePath)
        post { self.total = Double(files.count) }
        var deleted = 0
        for (i, p) in files.enumerated() {
            if cancelled { break }
            if (try? fm.removeItem(atPath: p)) != nil { deleted += 1 }
            let n = Double(i + 1)
            post { self.done = n; self.status = "Erasing \u{2014} \(Int(n)) of \(files.count)" }
        }
        try? fm.removeItem(atPath: ipod.volumePath + "/iPod_Control/Syncopation")
        post { self.refreshIPods() }
        finish("Done — \(deleted) files deleted from “\(ipod.name)”. Eject before unplugging.")
    }

    private func confirmErase(title: String, body: String, button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .critical
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: button)
        return a.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - Interface

// One geometry for every primary action, and one corner radius shared by the
// buttons and the cards, so the two read as a single system rather than two.
let actionWidth: CGFloat = 84
let actionHeight: CGFloat = 38
let cardCorner: CGFloat = 8

// The size the window always opens at — stretchable afterwards, but never
// restored from a previous session, so every launch starts composed.
let windowWidth: CGFloat = 760
// Matches Pro's composed size — the two editions present at the same
// dimensions; CE's shorter content collects its slack above the foot.
let windowHeight: CGFloat = 810

// On short screens the composed layout doesn't fit: 13-inch Macs at default
// scaling offer roughly 775 usable points against an 810-point window.
// Rather than maintaining a second compact layout, the whole interface
// renders scaled down just enough to fit the screen it opened on; 14-inch
// and larger displays see it at 100%.
let uiScale: CGFloat = {
    guard let screen = NSScreen.main else { return 1 }
    let titleBar: CGFloat = 28
    return min(1, (screen.visibleFrame.height - titleBar) / windowHeight)
}()
// The drawer rolls out of the window's right edge — the full window height
// is its vertical budget, which a bottom roll-out under an already
// screen-filling window never had.
let debugPanelWidth: CGFloat = 480

// Debug panel visibility. Stored so the Help menu item and the Debug button
// can drive the same state from two different parts of the view tree; reset
// at every launch, since it's a look under the hood rather than a preference.
let debugPanelKey = "showDebugPanel"

// Aubergine, matching the app icon's gradient.
let accentTop = Color(red: 0x77 / 255.0, green: 0x29 / 255.0, blue: 0x53 / 255.0)
let accentBottom = Color(red: 0x30 / 255.0, green: 0x0A / 255.0, blue: 0x24 / 255.0)
// The foot is a shorter bar than the title, so it starts partway down the same
// gradient rather than repeating it — the two read as one frame, not two bars.
let footerTop = Color(red: 0x5D / 255.0, green: 0x1F / 255.0, blue: 0x41 / 255.0)
let syncoOrchid = Color(red: 0xC7 / 255.0, green: 0x5B / 255.0, blue: 0x8F / 255.0)
/// One hairline for the whole window. Orchid rather than the deeper
/// aubergine: at hairline weight the dark tone disappears against the panels.
let syncoLine = syncoOrchid.opacity(0.55)
let syncoLineSoft = syncoOrchid.opacity(0.34)
/// The title bar's exact fill, reused by the active segment of a track.
let accentGradient = LinearGradient(colors: [accentTop, accentBottom],
                                    startPoint: .top, endPoint: .bottom)

// View menu settings. Appearance follows the system unless told otherwise;
// the finish sound borrows whatever alert the user picked in System Settings.
let appearanceKey = "appearance"          // "system" | "light" | "dark"
let finishSoundKey = "playSoundWhenFinished"

/// A run shorter than this was watched, and doesn't need announcing.
let finishSoundFloor: TimeInterval = 30

struct HeaderBar: View {
    private var titleGradient: LinearGradient {
        LinearGradient(colors: [.white,
                                Color(red: 1.0, green: 0.80, blue: 0.92)],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        // One line, shared with the traffic lights: the bar reaches up under
        // the title-bar safe area so the wordmark sits level with the buttons
        // instead of below them, and the leading inset keeps clear of them.
        HStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(titleGradient)
            Text("Syncopation CE")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(titleGradient)
                .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
        }
        .padding(.leading, 80)      // clears the traffic lights
        .padding(.trailing, 16)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [accentTop, accentBottom],
                                   startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea(edges: .top)
    }
}

// Bookend to the tinted title bar: states the version and what the app is
// pointed at, without spending a section of the window on either.
struct FooterBar: View {
    let right: String

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Syncopation CE \(version)")
            Spacer()
            Text(right)
                .foregroundColor(.white.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10.5))
        .foregroundColor(.white.opacity(0.86))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(LinearGradient(colors: [footerTop, accentBottom],
                                   startPoint: .top, endPoint: .bottom))
    }
}

/// The one card treatment: soft material fill with the fine aubergine
/// hairline. Fields, the device picker, the info/Capacity/Status cards and
/// the Debug card all wear exactly this, so the window reads as one system.
struct CardChrome: ViewModifier {
    var fill: Color? = nil
    var height: CGFloat? = nil

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            // Flat fill, deliberately: CE has no glass — the frosted look is
            // a Pro signature.
            .background(RoundedRectangle(cornerRadius: cardCorner)
                .fill(fill ?? Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: cardCorner)
                .stroke(syncoLineSoft, lineWidth: 1))
    }
}

extension View {
    func syncoCard(fill: Color? = nil, height: CGFloat? = nil) -> some View {
        modifier(CardChrome(fill: fill, height: height))
    }
}

// The Help menu can't reach the model, so it rings this bell and ContentView —
// which can — answers it.
extension Notification.Name {
    static let toggleDebugDrawer = Notification.Name("toggleDebugDrawer")
}

/// The Debug drawer: an attached child window that slides out from under the
/// main window's bottom edge.
///
/// This is a drawer rather than an in-window panel because resizing a live
/// SwiftUI window can't be animated cleanly: AppKit's frame animators
/// crossfade a snapshot of the old content into the new (the whole window
/// ghosts double), and stepping the frame by hand relayouts every tick. A
/// child window's slide is pure compositor work — its content is laid out
/// once, at full size, and the motion never triggers a layout — so it is
/// smooth by construction.
final class DebugDrawer {
    static let shared = DebugDrawer()
    private var drawer: NSWindow?
    private var observers: [NSObjectProtocol] = []
    // Tucked this far up behind the parent, so the drawer's own rounded
    // corners never peek out while it's closed.
    private let tuck: CGFloat = 13

    var isOpen: Bool { drawer != nil }

    func toggle(on parent: NSWindow, content: NSView) {
        isOpen ? close() : open(on: parent, content: content)
    }

    private func open(on parent: NSWindow, content: NSView) {
        // Classic drawer manners: no room on the right of the window means
        // the window gives way, nudged left until the drawer fits on screen.
        if let screen = parent.screen {
            let overflow = (parent.frame.maxX + debugPanelWidth) - screen.visibleFrame.maxX
            if overflow > 0 {
                var f = parent.frame
                f.origin.x = max(screen.visibleFrame.minX, f.origin.x - overflow)
                parent.setFrame(f, display: true, animate: true)
            }
        }
        let w = NSWindow(contentRect: hiddenFrame(parent),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        // Solid backdrop — CE has no glass. A plain layer honours
        // cornerRadius directly, so the corners round without a mask image.
        let backdrop = NSView(frame: NSRect(origin: .zero,
                                            size: hiddenFrame(parent).size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        backdrop.layer?.cornerRadius = 11
        backdrop.layer?.masksToBounds = true
        content.frame = backdrop.bounds
        content.autoresizingMask = [.width, .height]
        backdrop.addSubview(content)
        w.contentView = backdrop
        drawer = w
        // .below keeps it hidden behind the parent while tucked, and behind
        // the window's shadow line once extended.
        parent.addChildWindow(w, ordered: .below)
        slide(to: shownFrame(parent))
        // Child windows follow a parent drag on their own, but not a resize.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: parent, queue: .main
        ) { [weak self] _ in
            guard let self, let drawer = self.drawer else { return }
            drawer.setFrame(self.shownFrame(parent), display: true)
        })
        UserDefaults.standard.set(true, forKey: debugPanelKey)
    }

    func close() {
        guard let drawer else { return }
        guard let parent = drawer.parent else { dismantle(); return }
        slide(to: hiddenFrame(parent)) { [weak self] in self?.dismantle() }
        UserDefaults.standard.set(false, forKey: debugPanelKey)
    }

    private func dismantle() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let drawer else { return }
        drawer.parent?.removeChildWindow(drawer)
        drawer.orderOut(nil)
        self.drawer = nil
    }

    private func slide(to frame: NSRect, then completion: (() -> Void)? = nil) {
        guard let drawer else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drawer.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
    }

    private func hiddenFrame(_ parent: NSWindow) -> NSRect {
        NSRect(x: parent.frame.maxX - debugPanelWidth - tuck,
               y: parent.frame.minY,
               width: debugPanelWidth + tuck,
               height: parent.frame.height)
    }

    private func shownFrame(_ parent: NSWindow) -> NSRect {
        NSRect(x: parent.frame.maxX - tuck,
               y: parent.frame.minY,
               width: debugPanelWidth + tuck,
               height: parent.frame.height)
    }

}

/// A primary action button. The label fills the button's content area, so the
/// drawn shape matches the frame exactly — set the frame on a styled Button
/// alone and the button paints at its natural width inside it, which reads as
/// uneven gaps in the row.
struct ActionButton: View {
    let title: String
    var prominent: Bool = false
    var width: CGFloat = actionWidth
    let action: () -> Void

    var body: some View {
        styled.frame(width: width, height: actionHeight)
    }

    @ViewBuilder
    private var styled: some View {
        let label = Text(title).frame(maxWidth: .infinity, maxHeight: .infinity)
        let shaped = Group {
            if prominent {
                Button(action: action) { label.foregroundColor(.white) }
                    .buttonStyle(.borderedProminent)
                    .tint(accentTop)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.bordered)
            }
        }

        if #available(macOS 14.0, *) {
            shaped.buttonBorderShape(.roundedRectangle(radius: cardCorner))
        } else {
            shaped.buttonBorderShape(.roundedRectangle)
        }
    }
}

// Segmented mode selector: one track carrying every mode, with the active one
// filled. A row of separate buttons reads as four unrelated controls; a single
// track says "pick one of these", which is what the control actually is.
struct ModeSelector: View {
    @Binding var mode: SyncMode
    /// Ties the highlight to one identity across positions, which is what
    /// lets it travel instead of blinking out and in somewhere else.
    @Namespace private var slide
    // .disabled() reaches controls but not plain tap gestures, so the guard
    // has to be explicit — a sync must not be able to switch modes.
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SyncMode.allCases) { m in
                let on = mode == m
                Text(m.label)
                    .font(.system(size: 13))
                    .foregroundColor(on ? .white : .primary)
                    // Equal shares of the window rather than sized to the
                    // label, so the track lines up with everything else.
                    .frame(maxWidth: .infinity)
                    .frame(height: actionHeight - 4)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: cardCorner - 2)
                                .fill(accentGradient)
                                .matchedGeometryEffect(id: "selection", in: slide)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard enabled else { return }
                        withAnimation(.smooth(duration: 0.26)) { mode = m }
                    }
            }
        }
        .padding(2)
        .syncoCard()
        .frame(maxWidth: .infinity)
    }
}

// Synco-pod wears the same track as Synco-mode, in green: it is the one
// control that changes what a file *becomes* on the device, and it should not
// be mistaken for Synco-mode at a glance. Two kinds — podcast filing is being
// developed (it needs episode metadata the writer cannot produce yet).
let syncoGreen = Color(red: 0x2F / 255.0, green: 0x8F / 255.0, blue: 0x60 / 255.0)

struct MediaKindSelector: View {
    @Binding var kind: IPodMediaKind
    @Namespace private var slide
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach([IPodMediaKind.music, .audiobook]) { k in
                let on = kind == k
                Text(k.label)
                    .font(.system(size: 13))
                    .foregroundColor(on ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: actionHeight - 4)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: cardCorner - 2)
                                .fill(syncoGreen)
                                .matchedGeometryEffect(id: "selection", in: slide)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard enabled else { return }
                        withAnimation(.smooth(duration: 0.26)) { kind = k }
                    }
            }
        }
        .padding(2)
        .syncoCard()
        .frame(maxWidth: .infinity)
    }
}

// The used-versus-total meter. Turns amber as the destination fills so a
// sync that won't fit reads as trouble before the shortfall message appears.
struct CapacityBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.32))
                // Same orchid run as the sync progress bar, so the two meters
                // read as the same kind of thing. Amber still takes over near
                // the top: that one is a warning, and a warning is allowed to
                // break the palette.
                Capsule()
                    .fill(fraction >= 0.92
                          ? AnyShapeStyle(Color.orange)
                          : AnyShapeStyle(LinearGradient(colors: [accentBottom, syncoOrchid],
                                                         startPoint: .leading,
                                                         endPoint: .trailing)))
                    .frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(syncoLineSoft, lineWidth: 0.8))
    }
}

// Drawn by hand rather than a system ProgressView: .tint() does not reach the
// stock bar, which kept painting itself in the system accent colour — an
// orange sliver in an aubergine window.
struct SyncProgressBar: View {
    var value: Double
    var total: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(max(value / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.32))
                Capsule()
                    .fill(LinearGradient(colors: [accentBottom, syncoOrchid],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(syncoLineSoft, lineWidth: 0.8))
    }
}

struct LogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Progress will appear here." : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .id("end")
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3)))
            // The single-closure form; the newer one needs macOS 14.
            .onChange(of: text) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

// What lives in the Debug drawer: everything technical about the device, in
// three compact columns so the per-file log gets the height, drawn as a card
// like every other card in the window.
struct DebugDrawerView: View {
    @ObservedObject var model: SyncModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.4)
                .foregroundColor(.secondary)
            if model.mode == .ipod, let pod = model.selectedIPod {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             alignment: .leading),
                                         count: 2),
                          alignment: .leading, spacing: 3) {
                    ForEach(deviceFacts(pod), id: \.0) { fact in
                        HStack(spacing: 5) {
                            Text(fact.0).foregroundColor(.secondary)
                            Text(fact.1)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 10.5))
                    }
                }
            }
            LogView(text: model.logText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .syncoCard()
        .padding(.vertical, 14)
        .padding(.trailing, 14)
        // The drawer's left 13pt is tucked behind the main window; the extra
        // leading padding puts the card clear of the window's right edge.
        .padding(.leading, 25)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deviceFacts(_ pod: IPodDevice) -> [(String, String)] {
        let bytes = { (n: Int64) in
            ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
        }
        var facts: [(String, String)] = [
            ("Model", pod.family),
            ("Volume", pod.volumePath),
        ]
        if let serial = pod.serial { facts.append(("Serial", serial)) }
        if let guid = pod.firewireGUID { facts.append(("Device ID", guid)) }
        if let v = pod.dbVersion { facts.append(("DBVersion", String(v))) }
        facts.append(("Library", pod.needsHashedDB ? "checksummed · hash58"
                                                   : "standard database"))
        facts.append(("Capacity", "\(bytes(pod.capacity)) · \(bytes(pod.free)) free"))
        facts.append(("Conversion", "FLAC → ALAC, 16-bit"))
        if let reason = pod.unsupportedReason { facts.append(("Unsupported", reason)) }
        return facts
    }
}

struct ContentView: View {
    @StateObject private var model = SyncModel()
    // Shared with the Help menu, which drives the same drawer.
    @AppStorage(debugPanelKey) private var showDebug = false

    private var composed: some View {
        VStack(spacing: 0) {
            HeaderBar()
            mainContent
            // Slack from a stretched window collects here, so the controls stay
            // put at the top and the foot stays welded to the bottom edge.
            Spacer(minLength: 0)
            FooterBar(right: footerStatus)
        }
    }

    var body: some View {
        Group {
            if uiScale < 1 {
                // Short screen: lay out at the composed size, render scaled to
                // fit. The window is fixed-size in this state — stretching a
                // transformed layout helps nobody.
                composed
                    .frame(width: windowWidth, height: windowHeight, alignment: .top)
                    .scaleEffect(uiScale, anchor: .topLeading)
                    .frame(width: windowWidth * uiScale,
                           height: windowHeight * uiScale, alignment: .topLeading)
            } else {
                composed
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .frame(minWidth: 700, minHeight: windowHeight)
            }
        }
        .onReceive(NotificationCenter.default
            .publisher(for: .toggleDebugDrawer)) { _ in toggleDebug() }
    }

    // Right-hand side of the foot: what we're pointed at, in a few words.
    private var footerStatus: String {
        if model.mode == .ipod {
            guard let pod = model.selectedIPod else { return "No iPod connected" }
            return "\(pod.name) · connected"
        }
        let dest = model.destPath.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty else { return "No destination chosen" }
        return URL(fileURLWithPath: dest).lastPathComponent
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Synco-mode:").bold()
                ModeSelector(mode: $model.mode)
                    .disabled(model.running)
                    .padding(.bottom, 2)

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                    Text(model.mode.details)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .syncoCard()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Default Source:").bold()
                HStack(spacing: 6) {
                    TextField("Choose the folder to sync from", text: $model.sourcePath)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .syncoCard(fill: Color(nsColor: .textBackgroundColor),
                                   height: actionHeight)
                    ActionButton(title: "Choose…") {
                        model.chooseFolder(message: "Choose the folder to sync from",
                                           initial: model.sourcePath) { model.sourcePath = $0 }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if model.mode == .ipod { ipodDestination } else { folderDestination }
            }

            if model.mode == .ipod {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Synco-pod:").bold()
                    MediaKindSelector(kind: $model.syncMediaKind)
                        .disabled(model.running)
                        .padding(.bottom, 2)

                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                        Text(model.syncMediaKind.details)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            // Both kinds' texts run ~2 lines; the floor keeps
                            // the card one height so the buttons never jump.
                            .frame(minHeight: 36, alignment: .top)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .syncoCard()
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                actionRow
                statusCard
            }
        }
        // Generous at the sides, tight top and bottom: the tinted bars already
        // give the content air there, and a matching inset just wastes height.
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // The drawer needs the window and the model; only this view has both.
    private func toggleDebug() {
        if DebugDrawer.shared.isOpen {
            showDebug = false
            DebugDrawer.shared.close()
        } else {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            showDebug = true
            DebugDrawer.shared.toggle(
                on: window,
                content: NSHostingView(rootView: DebugDrawerView(model: model)))
        }
    }

    // Four identically sized buttons, then the capacity meter taking whatever
    // width is left — so the meter grows when the window does.
    private var actionRow: some View {
        HStack(spacing: 6) {
            ActionButton(title: "Preview") { model.start(dryRun: true) }
                .disabled(model.running)
            ActionButton(title: "Sync", prominent: true) { model.start(dryRun: false) }
                .disabled(model.running)
                .keyboardShortcut(.defaultAction)
            ActionButton(title: "Cancel") { model.cancel() }
                .disabled(!model.running)
            ActionButton(title: "Debug", prominent: showDebug) { toggleDebug() }
                .help("Show the device details and the per-file log")

            capacityCard.padding(.leading, 20)
        }
    }

    private var capacityCard: some View {
        HStack(spacing: 10) {
            Text("Capacity")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
            if let cap = model.destCapacity {
                CapacityBar(fraction: cap.fraction)
                Text(cap.text)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            } else {
                Text(model.mode == .ipod ? "No iPod selected" : "No destination chosen")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .syncoCard(height: actionHeight)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Status")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.4)
                .foregroundColor(.secondary)
            Text(model.status)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            SyncProgressBar(value: model.done, total: model.total)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .syncoCard()
    }

    @ViewBuilder
    private var folderDestination: some View {
        Text("Destination (SD card or folder):").bold()
        HStack(spacing: 6) {
            TextField("Pick the card or destination folder", text: $model.destPath)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .syncoCard(fill: Color(nsColor: .textBackgroundColor),
                           height: actionHeight)
            Menu("Volumes") {
                if model.volumes.isEmpty { Text("No external volumes found") }
                ForEach(model.volumes, id: \.self) { v in
                    Button(v) { model.destPath = v }
                }
            }
            .frame(width: 100)
            ActionButton(title: "Refresh") { model.refreshVolumes() }
            ActionButton(title: "Browse…") {
                model.chooseFolder(message: "Choose the destination (or a folder on it)",
                                   initial: model.destPath.isEmpty ? "/Volumes" : model.destPath) {
                    model.destPath = $0
                }
            }
            ActionButton(title: "Erase…") { model.eraseDestination() }
                .disabled(model.running)
            ActionButton(title: "Eject") { model.eject() }
                .disabled(model.running || !model.destIsEjectable)
        }
    }

    @ViewBuilder
    private var ipodDestination: some View {
        Text("Destination (iPod):").bold()
        HStack(spacing: 6) {
            Menu {
                if model.ipods.isEmpty {
                    Text("No iPods found — connect one in disk mode, then Refresh")
                }
                ForEach(model.ipods) { pod in
                    Button { model.selectIPod(pod) } label: {
                        Label("\(pod.name) — \(pod.pickerFamily)", systemImage: "ipod")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ipod")
                        .foregroundStyle(model.selectedIPod?.shellColor ?? .secondary)
                    Text(model.selectedIPod.map { "\($0.name) — \($0.pickerFamily)" }
                         ?? "Select iPod…")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            // Fills the row up to the buttons, like the source field above it —
            // the width comes from the window, never from the device's name,
            // so a long name truncates instead of shoving the buttons about.
            .syncoCard(height: actionHeight)

            ActionButton(title: "Refresh") { model.refreshIPods() }
            ActionButton(title: "Erase…") { model.eraseDestination() }
                .disabled(model.running || model.selectedIPod == nil)
            ActionButton(title: "Eject") { model.eject() }
                .disabled(model.running || !model.destIsEjectable)
        }
        // A working device says everything it has to say in Debug; only a
        // device the user has to *act* on gets a line in the main window.
        if let pod = model.selectedIPod, pod.unsupportedReason != nil {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .padding(.top, 2)
                Text(pod.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .syncoCard(fill: .orange.opacity(0.12))
        }
    }
}

@main
struct SyncopationApp: App {
    // Same key ContentView reads, so the Help menu and the Debug button drive
    // one piece of state rather than two.
    @AppStorage(debugPanelKey) private var showDebug = false
    @AppStorage(appearanceKey) private var appearance = "system"
    @AppStorage(finishSoundKey) private var playSoundWhenFinished = true

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// nil hands the choice back to macOS, which is the default.
    private var chosenScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// .preferredColorScheme re-colours SwiftUI views but leaves the AppKit
    /// layer on the system appearance, which reads as a half-switched app.
    /// Setting NSApp.appearance moves the whole thing at once.
    private func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }

    var body: some Scene {
        WindowGroup("Syncopation CE") {
            ContentView()
                .onAppear {
                    // Debug is a look under the hood, not a preference: every
                    // launch starts with it closed.
                    showDebug = false
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        for window in NSApp.windows {
                            // Draggable by the custom header (and any other
                            // empty background area).
                            window.isMovableByWindowBackground = true
                            // Always open at the composed size. macOS otherwise
                            // restores whatever the window was left at, which
                            // defeats having a considered default at all.
                            window.setContentSize(NSSize(width: windowWidth * uiScale,
                                                         height: windowHeight * uiScale))
                            window.center()
                        }
                    }
                }
                .preferredColorScheme(chosenScheme)
                .onAppear { applyAppearance() }
                .onChange(of: appearance) { _ in applyAppearance() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: windowWidth * uiScale, height: windowHeight * uiScale)
        .commands {
            // Appearance and the finish sound are View concerns: nobody has
            // ever gone looking for a theme in the Edit menu. Liquid Glass and
            // Transparency are deliberately absent — CE is flat by design, so
            // there is nothing for either switch to turn off.
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Play Sound When Finished", isOn: $playSoundWhenFinished)
                Divider()
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Syncopation CE") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: "\(appVersion) \u{201C}\(versionCodename)\u{201D}",
                    ])
                }
            }
            CommandGroup(replacing: .help) {
                Text("Syncopation CE \(appVersion)")
                Divider()
                Button(showDebug ? "Hide Debug Info" : "Show Debug Info") {
                    // ContentView owns the model the drawer renders, so the
                    // menu just rings the bell.
                    NotificationCenter.default.post(name: .toggleDebugDrawer,
                                                    object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Syncopation on GitHub") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/ehajek/Syncopation-Community-Edition")!)
                }
            }
        }
    }
}
