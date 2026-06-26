// VAPEvent.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation

/// All playback lifecycle events emitted via AsyncStream and event handlers.
public enum VAPEvent: Sendable {
    /// Playback started (first frame displayed)
    case didStart
    /// A frame was rendered
    case didPlayFrame(index: Int)
    /// One loop cycle finished (only emitted when loopCount > 1 or == 0)
    case didLoopFinish(loop: Int, totalFrames: Int)
    /// All loop cycles finished (or loopCount == 1 finished)
    case didFinish(totalFrames: Int)
    /// Playback was stopped externally
    case didStop(lastFrame: Int)
    /// Remote source is being resolved or downloaded by the configured resource loader
    case downloading(progress: Double)
    /// An error occurred
    case didFail(VAPError)
}
