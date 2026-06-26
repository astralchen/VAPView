// VAPEvent.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation

/// 通过 AsyncStream 和事件处理器发出的所有播放生命周期事件。
public enum VAPEvent: Sendable {
    /// 播放已开始（首帧已显示）。
    case didStart
    /// 已渲染一帧。
    case didPlayFrame(index: Int)
    /// 单次循环完成（仅在 loopCount > 1 或 == 0 时发出）。
    case didLoopFinish(loop: Int, totalFrames: Int)
    /// 所有循环已完成（或 loopCount == 1 的单次播放已完成）。
    case didFinish(totalFrames: Int)
    /// 播放被外部停止。
    case didStop(lastFrame: Int)
    /// 配置的资源加载器正在解析或下载远程资源。
    case downloading(progress: Double)
    /// 发生错误。
    case didFail(VAPError)
}
