// AudioConvert.swift — FLAC → ALAC entirely in-process.
//
// The App Store sandbox does not extend a security-scoped grant to child
// processes, so shelling out to /usr/bin/afconvert cannot read the user's
// music or write to the iPod. Everything here runs inside the app, using the
// access the app already holds. It also removes the last external dependency
// and the descriptor pressure that came with spawning thousands of processes.
//
// Output targets what click-wheel iPods actually play: 16-bit ALAC at
// 44.1 or 48 kHz. Hi-res sources are resampled down; nothing above 48 kHz
// and nothing deeper than 16-bit ever reaches the device.
//
// Copyright (C) 2026 Eddie Hajek
// Licensed under the GNU General Public License v3.0 — see the LICENSE file.

import Foundation
import AVFoundation
import AudioToolbox

enum AudioConvertError: LocalizedError {
    case unreadable(String)
    case noAudioTrack
    case writerSetupFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "Could not read the audio file: \(why)"
        case .noAudioTrack: return "The file contains no audio track."
        case .writerSetupFailed(let why): return "Could not start the converter: \(why)"
        case .failed(let why): return "Conversion failed: \(why)"
        }
    }
}

enum AudioConverter {

    /// The rate an iPod can actually play, given a source rate.
    /// 88.2/176.4 halve to 44.1; 96/192 halve to 48; anything already legal
    /// is left alone.
    static func iPodSampleRate(for sourceRate: Int) -> Int {
        let rate = sourceRate > 0 ? sourceRate : 44_100
        guard rate > 48_000 else { return rate }
        return rate % 44_100 == 0 ? 44_100 : 48_000
    }

    /// Converts any CoreAudio-readable file to 16-bit ALAC in an .m4a
    /// container. Runs synchronously on the calling (worker) thread.
    static func convertToALAC(source: URL, output: URL, sourceRate: Int) throws {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioConvertError.noAudioTrack
        }

        let rate = iPodSampleRate(for: sourceRate)
        let channels = min(channelCount(of: track), 2)   // iPods are stereo only

        do {
            try convertUsingAVFoundation(asset: asset, track: track, output: output,
                                         rate: rate, channels: channels)
        } catch {
            // Some files AVFoundation rejects decode perfectly through the
            // older CoreAudio path; try that before giving up on the track.
            try convertUsingCoreAudioFile(source: source, output: output,
                                          rate: rate, channels: channels)
        }
    }

    private static func convertUsingAVFoundation(asset: AVURLAsset, track: AVAssetTrack,
                                                 output: URL, rate: Int,
                                                 channels: Int) throws {

        // Decode to 16-bit interleaved PCM at the target rate. Doing the depth
        // conversion here is what keeps 32-bit ALAC — which iPod firmware
        // can't reliably decode — from ever being produced.
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 16,
        ]

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            try? FileManager.default.removeItem(at: output)
            writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        } catch {
            throw AudioConvertError.writerSetupFailed(error.localizedDescription)
        }

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw AudioConvertError.unreadable("this format can't be decoded")
        }
        reader.add(readerOutput)

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioConvertError.writerSetupFailed("Apple Lossless output was refused")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioConvertError.unreadable(reader.error?.localizedDescription ?? "unknown error")
        }
        guard writer.startWriting() else {
            throw AudioConvertError.writerSetupFailed(
                writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Pull samples on a private queue and block until it finishes; the
        // caller is a background worker that expects synchronous behaviour.
        let queue = DispatchQueue(label: "com.eddiehajek.syncopation.convert")
        let done = DispatchSemaphore(value: 0)
        writerInput.requestMediaDataWhenReady(on: queue) {
            while writerInput.isReadyForMoreMediaData {
                guard reader.status == .reading,
                      let buffer = readerOutput.copyNextSampleBuffer() else {
                    writerInput.markAsFinished()
                    done.signal()
                    return
                }
                if !writerInput.append(buffer) {
                    reader.cancelReading()
                    writerInput.markAsFinished()
                    done.signal()
                    return
                }
            }
        }
        done.wait()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: output)
            throw AudioConvertError.failed(reader.error?.localizedDescription ?? "read error")
        }
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: output)
            throw AudioConvertError.failed(writer.error?.localizedDescription ?? "write error")
        }
    }


    /// Second decoder, used when AVFoundation refuses a file.
    ///
    /// AVFoundation's reader rejects some perfectly good FLACs outright with
    /// `'dta?'` (unsupported data format) before producing a single buffer,
    /// while the lower-level CoreAudio file API — the same one `afconvert`
    /// uses — decodes them without complaint. This path covers those files.
    /// It is still entirely in-process, so nothing depends on a sandbox grant.
    static func convertUsingCoreAudioFile(source: URL, output: URL, rate: Int,
                                          channels: Int) throws {
        var inFile: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(source as CFURL, &inFile) == noErr, let inFile else {
            throw AudioConvertError.unreadable("CoreAudio could not open it either")
        }
        defer { ExtAudioFileDispose(inFile) }

        // Decode to 16-bit interleaved PCM at the target rate; CoreAudio
        // resamples as needed when this differs from the source.
        var client = AudioStreamBasicDescription(
            mSampleRate: Double(rate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0)
        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileSetProperty(inFile, kExtAudioFileProperty_ClientDataFormat,
                                      clientSize, &client) == noErr else {
            throw AudioConvertError.failed("this file's audio format can't be decoded")
        }

        var outFormat = AudioStreamBasicDescription()
        outFormat.mSampleRate = Double(rate)
        outFormat.mFormatID = kAudioFormatAppleLossless
        outFormat.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData
        outFormat.mChannelsPerFrame = UInt32(channels)

        try? FileManager.default.removeItem(at: output)
        var outFile: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(output as CFURL, kAudioFileM4AType, &outFormat,
                                        nil, AudioFileFlags.eraseFile.rawValue,
                                        &outFile) == noErr, let outFile else {
            throw AudioConvertError.writerSetupFailed("could not create the output file")
        }
        defer { ExtAudioFileDispose(outFile) }
        guard ExtAudioFileSetProperty(outFile, kExtAudioFileProperty_ClientDataFormat,
                                      clientSize, &client) == noErr else {
            throw AudioConvertError.writerSetupFailed("Apple Lossless output was refused")
        }

        let framesPerRead: UInt32 = 16384
        let byteCount = Int(framesPerRead) * Int(client.mBytesPerFrame)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                      mDataByteSize: UInt32(byteCount),
                                      mData: buffer))
            var frames = framesPerRead
            guard ExtAudioFileRead(inFile, &frames, &list) == noErr else {
                throw AudioConvertError.failed("decoding stopped partway through")
            }
            if frames == 0 { break }
            guard ExtAudioFileWrite(outFile, frames, &list) == noErr else {
                throw AudioConvertError.failed("writing the converted audio failed")
            }
        }
    }

    private static func channelCount(of track: AVAssetTrack) -> Int {
        for desc in track.formatDescriptions {
            let fd = desc as! CMFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                return Int(asbd.mChannelsPerFrame)
            }
        }
        return 2
    }
}

// MARK: - Pipelined conversion

/// Converts ahead of the copy loop on one background thread, so the CPU
/// works while the iPod's USB link drains and vice versa. The lookahead is
/// bounded — a few finished tracks, a few GB — so tmp usage stays constant
/// no matter how large the library is. One conversion is always allowed to
/// run even when a single huge file exceeds the byte budget on its own,
/// which keeps the pipeline from wedging on outliers.
final class ConversionPipeline {

    struct Job {
        let index: Int          // position in the sync plan
        let source: URL
        let sampleRate: Int
        let durationMS: Int
    }

    struct Outcome {
        let url: URL?           // converted file, ready to place on the iPod
        let bytes: Int64
        let error: Error?
    }

    /// How far the converter may run ahead of the copier.
    static let maxLookaheadFiles = 3
    static let maxLookaheadBytes: Int64 = 5_000_000_000

    /// FAT32's hard per-file ceiling — nothing this size can land on an iPod.
    static let fat32Limit: Int64 = 4_294_967_295

    private let cond = NSCondition()
    private var outcomes: [Int: Outcome] = [:]
    private var inFlightFiles = 0
    private var inFlightBytes: Int64 = 0
    private var stopped = false
    private let jobs: [Job]
    private let tmpDir: URL

    init(jobs: [Job], tmpDir: URL) {
        self.jobs = jobs
        self.tmpDir = tmpDir
        let worker = Thread { [self] in work() }
        worker.name = "com.eddiehajek.syncopation.convert-pipeline"
        worker.qualityOfService = .userInitiated
        worker.start()
    }

    /// Blocks until the converted result for a plan index is ready.
    /// The copy loop consumes indices in plan order, and the worker delivers
    /// them in plan order, so this never waits on an index the worker has
    /// silently passed by.
    func take(_ index: Int) -> Outcome {
        cond.lock(); defer { cond.unlock() }
        while outcomes[index] == nil && !stopped { cond.wait() }
        return outcomes.removeValue(forKey: index)
            ?? Outcome(url: nil, bytes: 0,
                       error: AudioConvertError.failed("the conversion was interrupted"))
    }

    /// The copier has deleted a converted file; its budget is free again.
    func didConsume(bytes: Int64) {
        cond.lock()
        inFlightFiles -= 1
        inFlightBytes -= bytes
        cond.broadcast()
        cond.unlock()
    }

    /// Ends the worker and removes any converted files nobody consumed.
    /// Safe to call at every exit from a sync, including normal completion.
    func stop() {
        cond.lock()
        stopped = true
        let leftovers = outcomes.values.compactMap(\.url)
        outcomes.removeAll()
        cond.broadcast()
        cond.unlock()
        for url in leftovers { try? FileManager.default.removeItem(at: url) }
    }

    private func work() {
        let fm = FileManager.default
        for job in jobs {
            cond.lock()
            while !stopped && inFlightFiles > 0 &&
                  (inFlightFiles >= Self.maxLookaheadFiles ||
                   inFlightBytes >= Self.maxLookaheadBytes) {
                cond.wait()
            }
            let bail = stopped
            cond.unlock()
            if bail { return }

            // Preflight: even at generous compression, a long enough track
            // cannot fit under FAT32's 4 GB ceiling. Skip it before spending
            // an hour of CPU proving the point. (16-bit PCM at the target
            // rate, stereo; ALAC won't halve that for real music.)
            let rate = AudioConverter.iPodSampleRate(for: job.sampleRate)
            let pcmBytes = Int64(job.durationMS) / 1000 * Int64(rate) * 4
            if pcmBytes / 2 > Self.fat32Limit {
                let hours = job.durationMS / 3_600_000
                deliver(job.index, Outcome(url: nil, bytes: 0,
                    error: AudioConvertError.failed(
                        "about \(hours) hours of audio in one file — the converted "
                        + "track would exceed the iPod's 4 GB per-file limit, so it was skipped")))
                continue
            }

            let out = tmpDir.appendingPathComponent(UUID().uuidString + ".m4a")
            do {
                try AudioConverter.convertToALAC(source: job.source, output: out,
                                                 sourceRate: job.sampleRate)
                let size = ((try? fm.attributesOfItem(atPath: out.path))?[.size] as? Int64) ?? 0
                if size >= Self.fat32Limit {
                    try? fm.removeItem(at: out)
                    deliver(job.index, Outcome(url: nil, bytes: 0,
                        error: AudioConvertError.failed(
                            "the converted file exceeds the iPod's 4 GB per-file limit — skipped")))
                    continue
                }
                cond.lock()
                inFlightFiles += 1
                inFlightBytes += size
                cond.unlock()
                deliver(job.index, Outcome(url: out, bytes: size, error: nil))
            } catch {
                deliver(job.index, Outcome(url: nil, bytes: 0, error: error))
            }
        }
    }

    private func deliver(_ index: Int, _ outcome: Outcome) {
        cond.lock()
        outcomes[index] = outcome
        cond.broadcast()
        cond.unlock()
    }
}
