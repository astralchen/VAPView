// VAPFrameBuffer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import CoreVideo
import Foundation

// MARK: - Decoded frame

struct VAPDecodedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    var frameIndex: Int
    var pts: Double   // seconds
}

// MARK: - Thread-safe FIFO buffer

actor VAPFrameBufferActor {
    private var frames: [VAPDecodedFrame] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int { frames.count }
    var isFull: Bool { frames.count >= capacity }
    var isEmpty: Bool { frames.isEmpty }

    func push(_ frame: VAPDecodedFrame) {
        if let index = frames.firstIndex(where: { $0.frameIndex > frame.frameIndex }) {
            frames.insert(frame, at: index)
        } else {
            frames.append(frame)
        }
    }

    func pop() -> VAPDecodedFrame? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    func popFrame(atOrAfter targetIndex: Int) -> VAPDecodedFrame? {
        while let frame = frames.first {
            if frame.frameIndex >= targetIndex {
                return frames.removeFirst()
            }
            frames.removeFirst()
        }
        return nil
    }

    func popFrame(at targetIndex: Int) -> VAPDecodedFrame? {
        guard let targetPosition = frames.firstIndex(where: { $0.frameIndex == targetIndex }) else {
            return nil
        }
        if targetPosition > 0 {
            frames.removeFirst(targetPosition)
        }
        return frames.removeFirst()
    }

    func clear() {
        frames.removeAll()
    }
}
