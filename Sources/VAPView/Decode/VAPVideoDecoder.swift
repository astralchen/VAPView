// VAPVideoDecoder.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Decoder actor

actor VAPVideoDecoder {

    private let info: VAPMP4Info
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private let buffer: VAPFrameBufferActor
    private var fileHandle: FileHandle?

    init(info: VAPMP4Info, bufferCapacity: Int) {
        self.info  = info
        self.buffer = VAPFrameBufferActor(capacity: bufferCapacity)
        self.fileHandle = FileHandle(forReadingAtPath: info.localFilePath)
    }

    /// Must be called immediately after init before any decode calls.
    func prepare() throws {
        try setupFormatDescription()
        try setupDecompressionSession()
    }

    // MARK: - Setup

    private func setupFormatDescription() throws {
        switch info.codec {
        case .h264:
            guard let avcC = info.avcC,
                  let sps = avcC.sps.first,
                  let pps = avcC.pps.first else {
                throw VAPError.videoToolboxDescriptionCreationFailed
            }
            formatDesc = try makeH264FormatDesc(sps: sps, pps: pps)
        case .h265:
            guard let hvcC = info.hvcC else {
                throw VAPError.videoToolboxDescriptionCreationFailed
            }
            formatDesc = try makeH265FormatDesc(hvcC: hvcC)
        }
    }

    private func setupDecompressionSession() throws {
        guard let formatDesc else { throw VAPError.videoToolboxSessionCreationFailed }
        var decoderSpec: [CFString: Any] = [:]
        if #available(iOS 17.0, *) {
            decoderSpec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true
        }
        // Must specify NV12 output — the renderer expects exactly 2 planes.
        let imageAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec.isEmpty ? nil : decoderSpec as CFDictionary,
            imageBufferAttributes: imageAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw VAPError.videoToolboxSessionCreationFailed
        }
        self.session = session
    }

    // MARK: - Decode

    /// Decode the sample at `index` and push the result into the frame buffer.
    func decodeFrame(at index: Int) async throws {
        guard index < info.videoSamples.count else { return }
        let sample = info.videoSamples[index]
        decoderLog.debug("decodeFrame index=\(index) offset=\(sample.offset) size=\(sample.size)")
        guard let blockBuffer = try readSampleData(sample: sample) else {
            throw VAPError.decodeFailed(NSError(domain: "VAPDecoder", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "readSampleData returned nil for index=\(index) offset=\(sample.offset) size=\(sample.size)"]))
        }
        guard let formatDesc, let session else { throw VAPError.videoToolboxSessionCreationFailed }

        let isKey = sample.isKeySample
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: sample.pts, preferredTimescale: 90000),
            decodeTimeStamp: CMTime(seconds: sample.dts, preferredTimescale: 90000)
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = Int(sample.size)
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else {
            throw VAPError.decodeFailed(NSError(domain: "VAPDecoder", code: Int(createStatus)))
        }

        if isKey {
            CMSetAttachment(sampleBuffer,
                            key: kCMSampleAttachmentKey_DisplayImmediately as CFString,
                            value: kCFBooleanTrue,
                            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }

        // Decode using VT output handler + checked continuation.
        // CVPixelBuffer is a CFTypeRef and is safe to pass across isolation boundaries;
        // we wrap it in a Sendable box to satisfy Swift 6.
        var flags = VTDecodeInfoFlags()
        let decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let pixelBuffer: CVPixelBuffer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CVPixelBuffer, any Error>) in
            let continuationBox = DecodeContinuationBox(continuation: continuation)
            let unmanagedRef = Unmanaged.passRetained(continuationBox)
            let decStatus = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: decodeFlags,
                infoFlagsOut: &flags,
                outputHandler: { status, _, pixBuf, _, _ in
                    let ref = unmanagedRef
                    defer { ref.release() }
                    let continuationBox = ref.takeUnretainedValue()
                    if status == noErr, let pixBuf {
                        decoderLog.debug("VT outputHandler: got pixBuf index=\(index)")
                        continuationBox.continuation.resume(returning: SendableCVPixelBuffer(pixBuf).value)
                    } else {
                        decoderLog.error("VT outputHandler: failed index=\(index) status=\(status) pixBuf=\(pixBuf == nil ? "nil" : "ok")")
                        continuationBox.continuation.resume(
                            throwing: VAPError.decodeFailed(
                                NSError(domain: "VAPDecoder", code: Int(status))
                            )
                        )
                    }
                }
            )
            if decStatus != noErr {
                unmanagedRef.release()
                continuation.resume(throwing: VAPError.decodeFailed(
                    NSError(domain: "VAPDecoder", code: Int(decStatus))))
            }
        }

        let frame = VAPDecodedFrame(pixelBuffer: pixelBuffer,
                                    frameIndex: sample.presentationIndex,
                                    pts: sample.pts)
        await buffer.push(frame)
        if index < 3 {
            let count = await buffer.count
            decoderLog.debug("decoded+pushed sample \(index) presentation=\(sample.presentationIndex) bufferedFrameCount=\(count)")
        }
    }

    func popFrame() async -> VAPDecodedFrame? {
        await buffer.pop()
    }

    func popFrame(atOrAfter targetIndex: Int) async -> VAPDecodedFrame? {
        await buffer.popFrame(atOrAfter: targetIndex)
    }

    func popFrame(at targetIndex: Int) async -> VAPDecodedFrame? {
        await buffer.popFrame(at: targetIndex)
    }

    func bufferedFrameCount() async -> Int {
        await buffer.count
    }

    func bufferIsFull() async -> Bool {
        await buffer.isFull
    }

    func waitUntilBufferHasSpace() async throws {
        while await buffer.isFull {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Reset the decoder for a new loop cycle.
    /// Clears the frame buffer and recreates the VTDecompressionSession,
    /// reusing the existing formatDesc and fileHandle.
    func reset() async throws {
        await buffer.clear()
        if let session { VTDecompressionSessionInvalidate(session) }
        self.session = nil
        try setupDecompressionSession()
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: - Private

    private func readSampleData(sample: VAPMP4Sample) throws -> CMBlockBuffer? {
        guard let fh = fileHandle else {
            decoderLog.error("readSampleData: fileHandle is nil for index=\(sample.index)")
            return nil
        }
        try fh.seek(toOffset: sample.offset)
        let raw: Data
        do {
            guard let data = try fh.read(upToCount: Int(sample.size)),
                  data.count == Int(sample.size) else {
                decoderLog.error("readSampleData: short read index=\(sample.index) expected=\(sample.size)")
                return nil
            }
            raw = data
        } catch {
            let nsError = error as NSError
            decoderLog.error("readSampleData: read error index=\(sample.index) domain=\(nsError.domain) code=\(nsError.code)")
            return nil
        }
        // MP4 sample data is already in AVCC (length-prefixed NAL unit) format.
        let avccData = raw
        decoderLog.debug("readSampleData: avccData.count=\(avccData.count) index=\(sample.index)")
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            decoderLog.error("readSampleData: CMBlockBufferCreate failed status=\(status) index=\(sample.index)")
            return nil
        }
        status = avccData.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            decoderLog.error("readSampleData: CMBlockBufferReplaceDataBytes failed status=\(status) index=\(sample.index)")
            return nil
        }
        return blockBuffer
    }


    private func makeH264FormatDesc(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var desc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let paramSets: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let paramSizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: paramSets,
                    parameterSetSizes: paramSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
        guard status == noErr, let desc else { throw VAPError.videoToolboxDescriptionCreationFailed }
        return desc
    }

    private func makeH265FormatDesc(hvcC: VAPHvcCData) throws -> CMVideoFormatDescription {
        guard let vps = hvcC.vps, let sps = hvcC.sps, let pps = hvcC.pps else {
            throw VAPError.videoToolboxDescriptionCreationFailed
        }
        var desc: CMVideoFormatDescription?
        let status: OSStatus = vps.withUnsafeBytes { vpsPtr in
            sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    let paramSets: [UnsafePointer<UInt8>] = [
                        vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    ]
                    let paramSizes: [Int] = [vps.count, sps.count, pps.count]
                    if #available(iOS 11.0, *) {
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: paramSets,
                            parameterSetSizes: paramSizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &desc
                        )
                    } else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }
                }
            }
        }
        guard status == noErr, let desc else { throw VAPError.videoToolboxDescriptionCreationFailed }
        return desc
    }
}

// MARK: - Sendable wrapper for CVPixelBuffer

/// CVPixelBuffer is a CFTypeRef (thread-safe retain/release) but not formally Sendable in Swift 6.
/// This wrapper lets us shuttle it across the continuation boundary.
private struct SendableCVPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ pb: CVPixelBuffer) { self.value = pb }
}

// MARK: - Continuation helper (reference type for Unmanaged)

private final class DecodeContinuationBox: @unchecked Sendable {
    let continuation: CheckedContinuation<CVPixelBuffer, any Error>
    init(continuation: CheckedContinuation<CVPixelBuffer, any Error>) {
        self.continuation = continuation
    }
}
