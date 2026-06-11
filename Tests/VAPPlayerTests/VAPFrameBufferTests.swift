// VAPFrameBufferTests.swift
import Testing
@testable import VAPPlayer
import CoreVideo

@Suite("VAPFrameBuffer")
struct VAPFrameBufferTests {

    private func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer!
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            nil, &pb)
        return pb
    }

    @Test func initialState() async {
        let buf = VAPFrameBufferActor(capacity: 3)
        let count = await buf.count
        let isEmpty = await buf.isEmpty
        let isFull = await buf.isFull
        #expect(count == 0)
        #expect(isEmpty)
        #expect(!isFull)
    }

    @Test func pushPop() async {
        let buf = VAPFrameBufferActor(capacity: 3)
        let frame = VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: 0, pts: 0.0)
        await buf.push(frame)
        #expect(await buf.count == 1)
        let popped = await buf.pop()
        #expect(popped != nil)
        #expect(popped?.frameIndex == 0)
        #expect(await buf.count == 0)
    }

    @Test func fifoOrder() async {
        let buf = VAPFrameBufferActor(capacity: 5)
        for i in 0..<3 {
            await buf.push(VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: i, pts: Double(i)))
        }
        for i in 0..<3 {
            let f = await buf.pop()
            #expect(f?.frameIndex == i)
        }
    }

    @Test func isFullAtCapacity() async {
        let buf = VAPFrameBufferActor(capacity: 2)
        await buf.push(VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: 0, pts: 0))
        #expect(await buf.isFull == false)
        await buf.push(VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: 1, pts: 1))
        #expect(await buf.isFull == true)
    }

    @Test func popFromEmpty() async {
        let buf = VAPFrameBufferActor(capacity: 3)
        let result = await buf.pop()
        #expect(result == nil)
    }

    @Test func clear() async {
        let buf = VAPFrameBufferActor(capacity: 3)
        for i in 0..<3 {
            await buf.push(VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: i, pts: Double(i)))
        }
        await buf.clear()
        #expect(await buf.count == 0)
        #expect(await buf.isEmpty == true)
    }

    @Test func popAtOrAfterDropsStaleFrames() async {
        let buf = VAPFrameBufferActor(capacity: 5)
        for i in 0..<4 {
            await buf.push(VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: i, pts: Double(i)))
        }

        let frame = await buf.popFrame(atOrAfter: 2)

        #expect(frame?.frameIndex == 2)
        #expect(await buf.count == 1)
        let remaining = await buf.pop()
        #expect(remaining?.frameIndex == 3)
    }

    @Test func popExactFrameWaitsForMissingPresentationFrame() async {
        let buf = VAPFrameBufferActor(capacity: 5)
        await buf.push(VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: 0, pts: 0))
        await buf.push(VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: 3, pts: 3))
        await buf.push(VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: 1, pts: 1))

        #expect(await buf.popFrame(at: 0)?.frameIndex == 0)
        #expect(await buf.popFrame(at: 2) == nil)
        #expect(await buf.count == 2)

        await buf.push(VAPDecodedFrame(pixelBuffer: makePixelBuffer(), frameIndex: 2, pts: 2))
        #expect(await buf.popFrame(at: 1)?.frameIndex == 1)
        #expect(await buf.popFrame(at: 2)?.frameIndex == 2)
        #expect(await buf.popFrame(at: 3)?.frameIndex == 3)
    }
}
