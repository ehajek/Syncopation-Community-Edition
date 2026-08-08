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
