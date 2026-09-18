import UIKit
import AVFoundation
import XCTest
@testable import VAPView

/// 通过实际控制器的界面入口验证下载、替换和页面生命周期。
/// 加载器由事件门控，播放素材独立生成，不访问公网或清理用户缓存。
@MainActor
private final class AuditPage {
    let controller: ViewController
    let fixture: URL
    var view: UIView { controller.view }
    var views: [UIView] { allViews(view) }
    var labels: [UILabel] { views.compactMap { $0 as? UILabel } }
    var statusLabel: UILabel { labels.first { $0.accessibilityIdentifier == "playbackStatus" }! }
    var pauseResumeButton: UIButton { button("pauseResumeButton") }
    var prefetchButton: UIButton { button("prefetchButton") }
    var stopButton: UIButton { button("stopButton") }
    var progressBar: UIProgressView { view.subviews.compactMap { $0 as? UIStackView }.flatMap { $0.arrangedSubviews }.compactMap { $0 as? UIProgressView }.first! }
    var isPlaybackRunning: Bool { stopButton.isEnabled }
    var isPlaybackStarted: Bool { pauseResumeButton.isEnabled && pauseResumeButton.currentTitle?.contains("暂停") == true }
    var isPlaybackPaused: Bool { pauseResumeButton.isEnabled && pauseResumeButton.currentTitle?.contains("继续") == true }
    var isPrefetching: Bool { statusLabel.text?.hasPrefix("Prefetching") == true }
    init(loader: AuditLoader, fixture: URL) {
        self.fixture = fixture
        controller = ViewController(giftEffectsLoader: {
            [.init(name: "礼物 A", url: "https://vap-state.test/a.mp4"),
             .init(name: "礼物 B", url: "https://vap-state.test/b.mp4")]
        })
        controller.loadViewIfNeeded()
        views.compactMap { $0 as? VAPView }.first!.resourceLoader = loader
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        view.layoutIfNeeded()
    }
    private func allViews(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap { allViews($0) } }
    private func button(_ id: String) -> UIButton { views.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id }! }
    func auditSelect(_ index: Int) {
        let collection = views.compactMap { $0 as? UICollectionView }.first!
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: index, section: 0))
    }
    func prefetchTapped() { invokeAction(prefetchButton) }
    func pauseResumeTapped() { invokeAction(pauseResumeButton) }
    func stopTapped() { invokeAction(stopButton) }
    private func invokeAction(_ button: UIButton) {
        // 原生无宿主单元测试没有 UIApplication 事件分发；调用按钮实际登记的 action。
        // 禁用按钮也可用于验证动作本身的保护，避免只验证灰色外观。
        let actions = button.actions(forTarget: controller, forControlEvent: .touchUpInside) ?? []
        XCTAssertEqual(actions.count, 1)
        for action in actions { controller.perform(NSSelectorFromString(action)) }
    }
    func auditClose() {
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        try? FileManager.default.removeItem(at: fixture)
    }
    func auditLeaveAndReturn() {
        controller.beginAppearanceTransition(false, animated: false); controller.endAppearanceTransition()
        controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
    }
}

/// 生成测试独占的短视频，使真实播放器可完成解析、解码和播放启动。
@MainActor
private func makeVideo() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32,
        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 60]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<60 {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 255, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
}

/// 验证真实 VideoToolbox 解码和帧事件，不能仅以按钮标题切换判定恢复成功。
@MainActor
final class VAPPlayerPauseResumeTests: XCTestCase {
    func testResumeMidGOPKeepsFramesAndLoopProgress() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try VAPMP4Parser.parse(localFilePath: url.path)
        XCTAssertTrue(info.videoSamples.dropFirst().contains { !$0.isKeySample })
        let player = VAPPlayer()
        defer { player.stop() }
        var frames: [Int] = []
        var starts = 0
        var loops: [Int] = []
        var finished = false
        var failures: [String] = []
        player.play(.init(source: url.path, playsAudio: false, loopCount: 2)) { event in
            switch event {
            case .didStart: starts += 1
            case .didPlayFrame(let index): frames.append(index)
            case .didLoopFinish(let loop, _): loops.append(loop)
            case .didFinish: finished = true
            case .didFail(let error): failures.append(String(describing: error))
            default: break
            }
        }
        try await waitFor { (frames.last ?? -1) >= 10 || !failures.isEmpty }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
        player.pause()
        let pausedFrames = frames
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(frames, pausedFrames)
        player.resume()
        player.resume() // 重复继续不能启动第二个播放任务。
        try await waitFor { frames.count >= pausedFrames.count + 5 || !failures.isEmpty }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
        XCTAssertEqual(starts, 1, "继续不能重新发出 didStart")
        XCTAssertGreaterThan(frames.count, pausedFrames.count)
        // 第二轮中再暂停，确保 loopCount 没有被重置。
        try await waitFor { starts == 2 && (frames.last ?? -1) >= 10 || !failures.isEmpty }
        player.pause()
        try await Task.sleep(nanoseconds: 100_000_000)
        player.resume()
        try await waitFor { finished || !failures.isEmpty }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: ", "))
        XCTAssertTrue(finished)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(loops, [1])
        XCTAssertEqual(frames.filter { $0 == 0 }.count, 2)
    }

    func testPauseBeforePreparationAndStopWhilePaused() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = VAPPlayer()
        defer { player.stop() }
        var frames: [Int] = []
        var starts = 0
        var stops = 0
        var failures = 0
        player.play(.init(source: url.path, playsAudio: false)) { event in
            switch event {
            case .didStart: starts += 1
            case .didPlayFrame(let index): frames.append(index)
            case .didStop: stops += 1
            case .didFail: failures += 1
            default: break
            }
        }
        player.pause()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(frames.isEmpty)
        player.resume()
        try await waitFor { frames.count >= 5 || failures > 0 }
        player.pause()
        let count = frames.count
        player.stop()
        player.resume()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(frames.count, count)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(failures, 0)
    }

    func testPausedFrameCallbackCanReplacePlayback() async throws {
        let url = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = VAPPlayer()
        defer { player.stop() }
        var oldFrames: [Int] = []
        var newFrames: [Int] = []
        var failures = 0
        player.play(.init(source: url.path, playsAudio: false)) { event in
            if case .didPlayFrame(let index) = event {
                oldFrames.append(index)
                if index >= 10 { player.pause() }
            }
            if case .didFail = event { failures += 1 }
        }
        try await waitFor { (oldFrames.last ?? -1) >= 10 || failures > 0 }
        let paused = oldFrames
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(oldFrames, paused)
        player.play(.init(source: url.path, playsAudio: false)) { event in
            if case .didPlayFrame(let index) = event { newFrames.append(index) }
            if case .didFail = event { failures += 1 }
        }
        // 新任务已经运行，resume 应无副作用。
        player.resume()
        try await waitFor { newFrames.count >= 15 || failures > 0 }
        XCTAssertEqual(oldFrames, paused)
        XCTAssertEqual(newFrames.first, 0)
        XCTAssertGreaterThanOrEqual(newFrames.count, 15)
        XCTAssertEqual(failures, 0)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待真实播放事件超时")
        throw NSError(domain: "VAPPauseResumeTests", code: 1)
    }
}

private actor AuditLoader: VAPResourceLoader {
    let localPath: String
    init(localPath: String) { self.localPath = localPath }
    struct Request {
        let source: String
        let progress: @MainActor @Sendable (Double) -> Void
        let continuation: CheckedContinuation<String, any Error>
    }
    private var requests: [UUID: Request] = [:]
    private var cancelled: Set<UUID> = []
    private(set) var cancellationCount = 0
    @concurrent func resolveLocalPath(for source: String, progressHandler: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await add(id, source, progressHandler)
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func add(_ id: UUID, _ source: String, _ progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            if cancelled.contains(id) { continuation.resume(throwing: CancellationError()) }
            else { requests[id] = Request(source: source, progress: progress, continuation: continuation) }
        }
    }
    private func cancel(_ id: UUID) {
        cancelled.insert(id)
        if let request = requests.removeValue(forKey: id) {
            cancellationCount += 1
            request.continuation.resume(throwing: CancellationError())
        }
    }
    func has(_ suffix: String) -> Bool { requests.values.contains { $0.source.hasSuffix(suffix) } }
    func progress(_ suffix: String) -> (@MainActor @Sendable (Double) -> Void)? { requests.values.first { $0.source.hasSuffix(suffix) }?.progress }
    func finish(_ suffix: String, failure: Bool = false) {
        guard let entry = requests.first(where: { $0.value.source.hasSuffix(suffix) }) else { return }
        requests[entry.key] = nil
        if failure { entry.value.continuation.resume(throwing: VAPError.fileNotFound("audit failed")) }
        else { entry.value.continuation.resume(returning: localPath) }
    }
}

@MainActor
final class VAPDemoPlaybackStateTests: XCTestCase {
    private func make() async throws -> (AuditPage, AuditLoader) {
        let url = try await makeVideo()
        let loader = AuditLoader(localPath: url.path)
        return (AuditPage(loader: loader, fixture: url), loader)
    }
    private func waitFor(_ description: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待超时: \(description)")
        throw NSError(domain: "VAPAudit", code: 1)
    }
    private func flush() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
    private func start(_ c: AuditPage, _ l: AuditLoader) async throws {
        c.auditSelect(0); try await waitFor("A 注册") { await l.has("a.mp4") }
        await l.finish("a.mp4")
        try await waitFor("A 实际开始播放") { c.isPlaybackStarted }
    }
    private func capture(_ name: String, _ c: AuditPage) {
        c.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: c.view.bounds).image { c.view.layer.render(in: $0.cgContext) }
        let a = XCTAttachment(image: image); a.name = name; a.lifetime = .keepAlways; add(a)
        print("VAP_STATE \(name) status=\(c.statusLabel.text ?? "") pause=\(c.pauseResumeButton.isEnabled) prefetch=\(c.prefetchButton.currentTitle ?? "") progressHidden=\(c.progressBar.isHidden)")
    }
    func testColdDownloadDisablesPauseAndAutoplayResetsTitle() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        c.auditSelect(0); try await waitFor("A 注册") { await l.has("a.mp4") }
        let p = await l.progress("a.mp4"); p?(0.5); await flush()
        XCTAssertFalse(c.pauseResumeButton.isEnabled)
        c.pauseResumeTapped()
        XCTAssertFalse(c.isPlaybackPaused)
        await l.finish("a.mp4")
        try await waitFor("开始播放") { c.isPlaybackStarted }
        XCTAssertEqual(c.pauseResumeButton.currentTitle?.trimmingCharacters(in: .whitespaces), "暂停")
        XCTAssertTrue(c.progressBar.isHidden)
        c.pauseResumeTapped(); XCTAssertTrue(c.isPlaybackPaused)
        c.pauseResumeTapped(); XCTAssertTrue(c.isPlaybackStarted)
        capture("加载完成及暂停继续", c)
    }
    func testFailedReplacementCannotResumeOldGift() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        try await start(c,l); c.auditSelect(1)
        try await waitFor("B 注册") { await l.has("b.mp4") }
        await l.finish("b.mp4", failure: true)
        try await waitFor("失败通知") { c.statusLabel.text?.hasPrefix("Error:") == true }
        XCTAssertFalse(c.pauseResumeButton.isEnabled)
        c.pauseResumeTapped(); XCTAssertFalse(c.isPlaybackRunning)
        XCTAssertTrue(c.statusLabel.text?.hasPrefix("Error:") == true)
        capture("新礼物失败不会恢复旧礼物", c)
    }
    func testLeavingDuringDownloadCancelsAndHidesProgress() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        c.auditSelect(0); try await waitFor("A 注册") { await l.has("a.mp4") }
        let p = await l.progress("a.mp4"); p?(0.5); await flush()
        c.auditLeaveAndReturn(); try await waitFor("页面离开后取消播放加载") { await l.cancellationCount == 1 }
        capture("下载中离开返回", c)
        XCTAssertTrue(c.progressBar.isHidden, "返回后不能保留后台继续运行的旧下载")
        XCTAssertFalse(c.isPlaybackRunning)
        let pending = await l.has("a.mp4"); XCTAssertFalse(pending, "离开应取消加载需求")
    }
    func testLeavingDuringPrefetchCancelsAndHidesProgress() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        c.prefetchTapped(); try await waitFor("预下载注册") { await l.has("a.mp4") }
        let p = await l.progress("a.mp4"); p?(0.5)
        c.auditLeaveAndReturn(); try await waitFor("页面离开后取消预下载") { await l.cancellationCount == 1 }
        capture("预下载中离开返回", c)
        XCTAssertFalse(c.isPrefetching)
        XCTAssertTrue(c.progressBar.isHidden)
        let pending = await l.has("a.mp4"); XCTAssertFalse(pending)
    }
    func testStopDuringDownloadRestoresPrefetchButton() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        c.auditSelect(0); try await waitFor("A 注册") { await l.has("a.mp4") }
        let p = await l.progress("a.mp4"); p?(0.5); await flush()
        c.stopTapped()
        try await waitFor("停止取消加载") { await l.cancellationCount == 1 }
        capture("下载中停止", c)
        XCTAssertTrue(c.progressBar.isHidden)
        XCTAssertTrue(c.prefetchButton.isEnabled, "已停止下载不能一直显示下载中并禁用预下载")
        XCTAssertFalse(c.labels.contains { $0.text == "下载中 50%" })
    }
    func testQueuedOldProgressCannotOverwriteReplacementStatus() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        c.auditSelect(0); try await waitFor("A 注册") { await l.has("a.mp4") }
        let p = await l.progress("a.mp4")
        // 回调已由框架交付，Demo 自己入队；同一主 Actor 执行片段内切换到 B。
        p?(0.5); c.auditSelect(1)
        await flush()
        capture("切换后旧进度迟到", c)
        XCTAssertTrue(c.statusLabel.text?.contains("礼物 B") == true, "旧 A 的已入队回调不能覆盖新 B")
        XCTAssertTrue(c.progressBar.isHidden, "B 尚未发布进度时不能显示 A 的 50%")
    }
    func testStopAfterPlaybackDisablesPlaybackControls() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        try await start(c,l); c.stopTapped(); await flush()
        XCTAssertFalse(c.pauseResumeButton.isEnabled)
        XCTAssertFalse(c.stopButton.isEnabled)
        XCTAssertTrue(c.progressBar.isHidden)
    }
    func testLeavingDuringPlaybackStopsOldPlayback() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        try await start(c,l); c.auditLeaveAndReturn(); await flush()
        capture("播放中离开返回", c)
        XCTAssertFalse(c.isPlaybackRunning, "离开页面应停止播放")
        XCTAssertFalse(c.pauseResumeButton.isEnabled)
    }

    func testReturningCanRestartCancelledDownload() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        c.auditSelect(0); try await waitFor("首次加载") { await l.has("a.mp4") }
        c.auditLeaveAndReturn()
        try await waitFor("旧加载退出") { await l.cancellationCount == 1 }
        c.auditSelect(0); try await waitFor("新加载") { await l.has("a.mp4") }
        await l.finish("a.mp4")
        try await waitFor("返回后实际播放") { c.isPlaybackStarted }
        XCTAssertTrue(c.progressBar.isHidden)
    }
    func testPrefetchOfPreviousGiftDoesNotOverwriteCurrentGift() async throws {
        let (c,l) = try await make(); defer { c.auditClose() }
        c.prefetchTapped(); try await waitFor("A 预下载") { await l.has("a.mp4") }
        c.auditSelect(1); try await waitFor("B 播放加载") { await l.has("b.mp4") }
        let p = await l.progress("a.mp4"); p?(0.5)
        XCTAssertTrue(c.statusLabel.text?.contains("礼物 B") == true)
        await l.finish("a.mp4"); await flush()
        XCTAssertTrue(c.statusLabel.text?.contains("礼物 B") == true)
        await l.finish("b.mp4")
        try await waitFor("B 实际播放") { c.isPlaybackStarted }
    }
}
