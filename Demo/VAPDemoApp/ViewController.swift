import UIKit
import VAPView

final class ViewController: UIViewController {

    struct GiftEffect: Decodable, Hashable {
        let name: String
        let url: String
    }

    fileprivate enum GiftDownloadState: Equatable {
        case idle
        case downloading(Double)
        case cached
        case failed
    }

    private enum Layout {
        static let pageInset: CGFloat = 16
        static let controlHeight: CGFloat = 44
        static let spacing: CGFloat = 12
    }

    private var giftEffects: [GiftEffect] = []
    private var selectedGiftIndex: Int?
    private let defaultAlphaPlacement: VAPAlphaPlacement = .right
    private var prefetchTask: Task<Void, Never>?
    private var prefetchingSource: String?
    /// 每次预下载独立的请求身份；同一 URL 再次提交也不能接收旧任务的完成通知。
    private var prefetchID: UUID?
    /// 当前播放请求的身份和资源来源，用于隔离替换与停止后的迟到事件。
    private var playbackID: UUID?
    private var playbackSource: String?
    private var downloadStates: [String: GiftDownloadState] = [:]
    private var isPrefetching = false
    private var isPlaybackRunning = false
    private var isPlaybackStarted = false
    private var isPlaybackPaused = false

    private var selectedGift: GiftEffect? {
        guard let selectedGiftIndex, giftEffects.indices.contains(selectedGiftIndex) else {
            return nil
        }
        return giftEffects[selectedGiftIndex]
    }

    private lazy var vapView: VAPView = {
        let v = VAPView(frame: .zero)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .black
        v.clipsToBounds = true
        return v
    }()

    private lazy var giftNameLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textColor = .white
        l.font = .systemFont(ofSize: 18, weight: .semibold)
        l.numberOfLines = 1
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.75
        l.text = "Loading gifts"
        return l
    }()

    private lazy var statusLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textColor = UIColor.white.withAlphaComponent(0.78)
        l.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        l.numberOfLines = 2
        l.text = "Ready"
        return l
    }()

    private lazy var progressBar: UIProgressView = {
        let p = UIProgressView(progressViewStyle: .bar)
        p.translatesAutoresizingMaskIntoConstraints = false
        p.trackTintColor = UIColor.white.withAlphaComponent(0.12)
        p.progressTintColor = .systemCyan
        p.isHidden = true
        return p
    }()

    private lazy var infoStack: UIStackView = {
        let s = UIStackView(arrangedSubviews: [giftNameLabel, statusLabel, progressBar])
        s.translatesAutoresizingMaskIntoConstraints = false
        s.axis = .vertical
        s.spacing = 6
        return s
    }()

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        let c = UICollectionView(frame: .zero, collectionViewLayout: layout)
        c.translatesAutoresizingMaskIntoConstraints = false
        c.backgroundColor = .clear
        c.alwaysBounceVertical = true
        c.dataSource = self
        c.delegate = self
        c.register(GiftCell.self, forCellWithReuseIdentifier: GiftCell.reuseIdentifier)
        return c
    }()

    private let prefetchButton = UIButton(type: .system)
    private let pauseResumeButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let clearCacheButton = UIButton(type: .system)

    private let giftEffectsLoader: @MainActor () throws -> [GiftEffect]

    /// 创建礼物演示页，并指定礼物目录的加载方式。
    ///
    /// - Parameter giftEffectsLoader: 默认读取应用中的目录；测试可提供独立资源。
    init(giftEffectsLoader: @escaping @MainActor () throws -> [GiftEffect] = ViewController.loadBundledGiftEffects) {
        self.giftEffectsLoader = giftEffectsLoader
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        giftEffectsLoader = Self.loadBundledGiftEffects
        super.init(coder: coder)
    }

    private static func loadBundledGiftEffects() throws -> [GiftEffect] {
        guard let url = Bundle.main.url(forResource: "gift_effects_mp4", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([GiftEffect].self, from: Data(contentsOf: url))
    }

    deinit { prefetchTask?.cancel() }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Gift Effects"
        view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.1, alpha: 1)

        configureButtons()
        setupLayout()
        giftNameLabel.accessibilityIdentifier = "selectedGiftName"
        statusLabel.accessibilityIdentifier = "playbackStatus"
        collectionView.accessibilityIdentifier = "giftList"
        prefetchButton.accessibilityIdentifier = "prefetchButton"
        pauseResumeButton.accessibilityIdentifier = "pauseResumeButton"
        stopButton.accessibilityIdentifier = "stopButton"
        clearCacheButton.accessibilityIdentifier = "clearCacheButton"
        loadGiftEffects()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelPrefetch()
        stopPlayback()
        setStatus("Stopped - 点击礼物重新播放")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    // MARK: - 界面搭建

    private func configureButtons() {
        makeToolbarButton(prefetchButton, title: "预下载", systemImage: "arrow.down.circle.fill", tintColor: .systemCyan)
        makeToolbarButton(pauseResumeButton, title: "暂停", systemImage: "pause.fill", tintColor: .systemBlue)
        makeToolbarButton(stopButton, title: "停止", systemImage: "stop.fill", tintColor: .systemRed)
        makeToolbarButton(clearCacheButton, title: "清缓存", systemImage: "trash.fill", tintColor: .systemOrange)

        prefetchButton.addTarget(self, action: #selector(prefetchTapped), for: .touchUpInside)
        pauseResumeButton.addTarget(self, action: #selector(pauseResumeTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        clearCacheButton.addTarget(self, action: #selector(clearCacheTapped), for: .touchUpInside)

        updateControlButtonStates()
    }

    private func makeToolbarButton(_ button: UIButton, title: String, systemImage: String, tintColor: UIColor) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = tintColor.withAlphaComponent(0.14)
        button.tintColor = tintColor
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 1
        button.layer.borderColor = tintColor.withAlphaComponent(0.38).cgColor
        button.contentHorizontalAlignment = .center
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.72
        button.setTitleColor(tintColor, for: .normal)
        button.setTitleColor(tintColor.withAlphaComponent(0.5), for: .disabled)
        setToolbarButtonContent(button, title: title, systemImage: systemImage)
    }

    private func setToolbarButtonContent(_ button: UIButton, title: String, systemImage: String) {
        button.setTitle(" \(title)", for: .normal)
        button.setImage(UIImage(systemName: systemImage), for: .normal)
    }

    private func setupLayout() {
        let controlsStack = UIStackView(arrangedSubviews: [
            prefetchButton,
            pauseResumeButton,
            stopButton,
            clearCacheButton
        ])
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.axis = .horizontal
        controlsStack.spacing = 8
        controlsStack.distribution = .fillEqually

        view.addSubview(vapView)
        view.addSubview(infoStack)
        view.addSubview(collectionView)
        view.addSubview(controlsStack)

        NSLayoutConstraint.activate([
            vapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Layout.spacing),
            vapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vapView.heightAnchor.constraint(equalTo: vapView.widthAnchor, multiplier: 0.78),

            infoStack.topAnchor.constraint(equalTo: vapView.bottomAnchor, constant: Layout.spacing),
            infoStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.pageInset),
            infoStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.pageInset),

            controlsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.pageInset),
            controlsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.pageInset),
            controlsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Layout.spacing),
            controlsStack.heightAnchor.constraint(equalToConstant: Layout.controlHeight),

            collectionView.topAnchor.constraint(equalTo: infoStack.bottomAnchor, constant: Layout.spacing),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Layout.pageInset),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.pageInset),
            collectionView.bottomAnchor.constraint(equalTo: controlsStack.topAnchor, constant: -Layout.spacing)
        ])
    }

    private func loadGiftEffects() {
        do {
            giftEffects = try giftEffectsLoader()
            selectedGiftIndex = giftEffects.isEmpty ? nil : 0
            restoreCachedDownloadStates()
            collectionView.reloadData()
            updateSelectedGiftText()

            if giftEffects.isEmpty {
                setStatus("Gift list is empty")
            } else {
                setStatus("Ready - \(giftEffects.count) gifts")
            }
        } catch {
            giftEffects = []
            selectedGiftIndex = nil
            collectionView.reloadData()
            giftNameLabel.text = "Load failed"
            setStatus("Gift list error: \(error.localizedDescription)")
            updateControlButtonStates()
        }
    }

    // MARK: - 操作

    @objc private func prefetchTapped() {
        guard let selectedGift else {
            setStatus("Select a gift first")
            return
        }

        cancelPrefetch()

        let source = selectedGift.url
        let giftName = selectedGift.name
        let id = UUID()
        let loader = vapView.resourceLoader
        prefetchID = id
        isPrefetching = true
        prefetchingSource = source
        progressBar.isHidden = false
        progressBar.progress = 0
        setDownloadState(.downloading(0), forSource: source)
        setStatus("Prefetching - \(giftName)")

        // 等待资源期间不强持有页面；页面销毁时仍能取消自己持有的加载需求。
        prefetchTask = Task { @MainActor [weak self] in
            do {
                _ = try await VAPView.prefetch(source: source, using: loader) { [weak self] progress in
                    guard let self, self.prefetchID == id else { return }
                    self.setDownloadState(.downloading(progress), forSource: source)
                    guard self.selectedGift?.url == source, !self.isPlaybackRunning else { return }
                    self.progressBar.isHidden = false
                    self.progressBar.setProgress(Float(progress), animated: true)
                    self.setStatus(String(format: "Prefetching %.0f%% - %@", progress * 100, giftName))
                }
                guard let self, !Task.isCancelled, self.prefetchID == id else { return }
                self.completePrefetch(source: source, state: .cached, message: "Prefetched - \(giftName)")
            } catch is CancellationError {
                guard let self, self.prefetchID == id else { return }
                self.completePrefetch(source: source, state: .idle, message: "Prefetch cancelled - \(giftName)")
            } catch {
                guard let self, self.prefetchID == id else { return }
                self.completePrefetch(source: source, state: .failed, message: "Prefetch failed: \(error.localizedDescription)")
            }
        }
    }

    /// 结束当前预下载的界面状态，不覆盖仍在播放的礼物状态。
    private func completePrefetch(source: String, state: GiftDownloadState, message: String) {
        prefetchID = nil
        prefetchTask = nil
        prefetchingSource = nil
        isPrefetching = false
        if playbackSource != source { setDownloadState(state, forSource: source) }
        if selectedGift?.url == source, !isPlaybackRunning {
            progressBar.isHidden = true
            setStatus(message)
        }
        updateControlButtonStates()
    }

    /// 撤销预下载身份后再取消句柄，防止取消完成回调清理新请求。
    private func cancelPrefetch() {
        let source = prefetchingSource
        prefetchID = nil
        prefetchingSource = nil
        isPrefetching = false
        let task = prefetchTask
        prefetchTask = nil
        task?.cancel()
        if let source, playbackSource != source { restoreDownloadState(for: source) }
        if !isPlaybackRunning { progressBar.isHidden = true }
        updateControlButtonStates()
    }

    /// 清理没有有效加载需求的下载标记，同时保留可复用的缓存状态。
    private func restoreDownloadState(for source: String) {
        guard case .downloading = downloadState(for: source) else { return }
        let cached = VAPDiskCache.shared.cachedLocalPath(for: source) != nil
        setDownloadState(cached ? .cached : .idle, forSource: source)
    }

    /// 停止当前播放，并同步恢复与该请求关联的按钮和下载状态。
    private func stopPlayback() {
        let source = playbackSource
        // stop() 可同步发送事件；先使旧身份失效，旧事件便不能重入更新界面。
        playbackID = nil
        playbackSource = nil
        vapView.stop()
        isPlaybackRunning = false
        isPlaybackStarted = false
        isPlaybackPaused = false
        progressBar.isHidden = true
        progressBar.progress = 0
        if let source, prefetchingSource != source { restoreDownloadState(for: source) }
        updateControlButtonStates()
    }

    @objc private func pauseResumeTapped() {
        guard isPlaybackRunning, isPlaybackStarted || isPlaybackPaused else { return }

        if isPlaybackPaused {
            vapView.resume()
            isPlaybackPaused = false
            isPlaybackStarted = true
            setStatus("Resumed - \(selectedGift?.name ?? "No gift")")
        } else {
            vapView.pause()
            isPlaybackPaused = true
            isPlaybackStarted = false
            setStatus("Paused - \(selectedGift?.name ?? "No gift")")
        }
        updateControlButtonStates()
    }

    @objc private func stopTapped() {
        cancelPrefetch()
        stopPlayback()
        setStatus("Stopped - \(selectedGift?.name ?? "No gift")")
    }

    @objc private func clearCacheTapped() {
        cancelPrefetch()
        progressBar.isHidden = true
        downloadStates.removeAll()
        collectionView.reloadData()
        updateControlButtonStates()

        do {
            try VAPDiskCache.shared.removeAllCachedResources()
            setStatus("Cache cleared")
        } catch {
            setStatus("Clear failed: \(error.localizedDescription)")
        }
    }

    private func startSelectedGift() {
        guard let selectedGift else {
            setStatus("Select a gift first")
            return
        }
        startPlay(effect: selectedGift)
    }

    private func startPlay(effect: GiftEffect) {
        stopPlayback()
        let id = UUID()
        playbackID = id
        playbackSource = effect.url
        print("[VAPDemo] play gift=\(effect.name) alphaPlacement=\(defaultAlphaPlacement)")
        progressBar.isHidden = true
        progressBar.progress = 0
        isPlaybackRunning = true
        isPlaybackStarted = false
        isPlaybackPaused = false
        updateControlButtonStates()
        setStatus("Starting - \(effect.name)")

        let playbackConfiguration = VAPPlaybackConfiguration(
            source: effect.url,
            alphaPlacement: defaultAlphaPlacement,
            backgroundPolicy: .pauseAndResume,
            contentMode: .aspectFit,
            loopCount: 1
        )

        vapView.play(playbackConfiguration, eventHandler: { [weak self] event in
            // SDK 已在主 Actor 同步交付事件，无需再次入队；消费时仍校验请求身份。
            guard let self, self.playbackID == id else { return }
            self.handlePlaybackEvent(event, giftName: effect.name, source: effect.url)
        })
    }

    private func handlePlaybackEvent(_ event: VAPEvent, giftName: String, source: String) {
        switch event {
        case .downloading(let progress):
            progressBar.isHidden = false
            progressBar.setProgress(Float(progress), animated: true)
            setDownloadState(.downloading(progress), forSource: source)
            setStatus(String(format: "Downloading %.0f%% - %@", progress * 100, giftName))
        case .didStart:
            isPlaybackRunning = true
            isPlaybackStarted = true
            isPlaybackPaused = false
            progressBar.isHidden = true
            setDownloadState(.cached, forSource: source)
            updateControlButtonStates()
            setStatus("Playing - \(giftName)")
        case .didPlayFrame(let index):
            if index % 15 == 0 {
                setStatus("Frame \(index) - \(giftName)")
            }
        case .didLoopFinish(let loop, let totalFrames):
            setStatus("Loop \(loop) done - \(totalFrames) frames")
        case .didFinish(let totalFrames):
            isPlaybackRunning = false
            isPlaybackStarted = false
            isPlaybackPaused = false
            progressBar.isHidden = true
            updateControlButtonStates()
            setStatus("Finished - \(totalFrames) frames")
        case .didStop(let lastFrame):
            isPlaybackRunning = false
            isPlaybackStarted = false
            isPlaybackPaused = false
            progressBar.isHidden = true
            updateControlButtonStates()
            setStatus("Stopped - frame \(lastFrame)")
        case .didFail(let error):
            isPlaybackRunning = false
            isPlaybackStarted = false
            isPlaybackPaused = false
            progressBar.isHidden = true
            setDownloadState(.failed, forSource: source)
            updateControlButtonStates()
            let message = "Error: \(error)"
            print("[VAPDemo] \(message)")
            setStatus(message)
        }
    }

    private func updateSelectedGiftText() {
        if let selectedGift {
            giftNameLabel.text = selectedGift.name
        } else {
            giftNameLabel.text = "Select a gift"
        }
        updateControlButtonStates()
    }

    private func restoreCachedDownloadStates() {
        downloadStates.removeAll()
        for effect in giftEffects where VAPDiskCache.shared.cachedLocalPath(for: effect.url) != nil {
            downloadStates[effect.url] = .cached
        }
    }

    private func updateControlButtonStates() {
        let selectedDownloadState = selectedGift.map { downloadState(for: $0.url) } ?? .idle
        let selectedGiftIsCached = selectedDownloadState == .cached
        let selectedGiftIsDownloading: Bool
        if case .downloading = selectedDownloadState {
            selectedGiftIsDownloading = true
        } else {
            selectedGiftIsDownloading = false
        }

        prefetchButton.isEnabled = selectedGift != nil && !isPrefetching && !selectedGiftIsCached && !selectedGiftIsDownloading
        pauseResumeButton.isEnabled = isPlaybackStarted || isPlaybackPaused
        stopButton.isEnabled = isPlaybackRunning

        let prefetchTitle: String
        let prefetchImage: String
        if selectedGiftIsCached {
            prefetchTitle = "已缓存"
            prefetchImage = "checkmark.circle.fill"
        } else if isPrefetching || selectedGiftIsDownloading {
            prefetchTitle = "下载中"
            prefetchImage = "arrow.down.circle.fill"
        } else {
            prefetchTitle = "预下载"
            prefetchImage = "arrow.down.circle.fill"
        }
        setToolbarButtonContent(prefetchButton, title: prefetchTitle, systemImage: prefetchImage)
        setToolbarButtonContent(
            pauseResumeButton,
            title: isPlaybackPaused ? "继续" : "暂停",
            systemImage: isPlaybackPaused ? "play.fill" : "pause.fill"
        )

        [prefetchButton, pauseResumeButton, stopButton, clearCacheButton].forEach { button in
            button.alpha = button.isEnabled ? 1 : 0.45
        }
    }

    private func downloadState(for source: String) -> GiftDownloadState {
        downloadStates[source] ?? .idle
    }

    private func setDownloadState(_ state: GiftDownloadState, forSource source: String) {
        let normalizedState = normalizedDownloadState(state, currentState: downloadState(for: source))
        if normalizedState == .idle {
            downloadStates.removeValue(forKey: source)
        } else {
            downloadStates[source] = normalizedState
        }
        refreshGiftItems(matching: source)
        updateControlButtonStates()
    }

    private func normalizedDownloadState(_ state: GiftDownloadState,
                                         currentState: GiftDownloadState) -> GiftDownloadState {
        if currentState == .cached, case .downloading = state {
            return .cached
        }
        if case .downloading(let progress) = state, progress >= 1.0 {
            return .cached
        }
        return state
    }

    private func refreshGiftItems(matching source: String) {
        let indexPaths = giftEffects.enumerated().compactMap { index, effect -> IndexPath? in
            effect.url == source ? IndexPath(item: index, section: 0) : nil
        }
        guard !indexPaths.isEmpty else { return }

        for indexPath in indexPaths {
            guard collectionView.indexPathsForVisibleItems.contains(indexPath),
                  let cell = collectionView.cellForItem(at: indexPath) as? GiftCell else {
                continue
            }

            cell.updateDownloadState(downloadState(for: source))
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.text = text
    }
}

extension ViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        giftEffects.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: GiftCell.reuseIdentifier,
            for: indexPath
        ) as? GiftCell else {
            return UICollectionViewCell()
        }

        let effect = giftEffects[indexPath.item]
        cell.configure(
            name: effect.name,
            index: indexPath.item + 1,
            isSelected: indexPath.item == selectedGiftIndex,
            downloadState: downloadState(for: effect.url)
        )
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let previousIndex = selectedGiftIndex
        selectedGiftIndex = indexPath.item
        updateSelectedGiftText()

        var reloadIndexPaths = [indexPath]
        if let previousIndex, previousIndex != indexPath.item {
            reloadIndexPaths.append(IndexPath(item: previousIndex, section: 0))
        }
        collectionView.reloadItems(at: reloadIndexPaths)

        startSelectedGift()
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns: CGFloat = collectionView.bounds.width >= 430 ? 3 : 2
        let spacing: CGFloat = 10
        let totalSpacing = spacing * (columns - 1)
        let width = floor((collectionView.bounds.width - totalSpacing) / columns)
        return CGSize(width: width, height: 58)
    }
}

private final class GiftCell: UICollectionViewCell {
    static let reuseIdentifier = "GiftCell"
    private var isCellSelected = false

    private lazy var nameLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textColor = .white
        l.font = .systemFont(ofSize: 14, weight: .semibold)
        l.numberOfLines = 2
        l.textAlignment = .center
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.78
        return l
    }()

    private lazy var indexLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textColor = UIColor.white.withAlphaComponent(0.58)
        l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        l.textAlignment = .center
        return l
    }()

    private lazy var statusBadgeLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textAlignment = .center
        l.layer.cornerRadius = 8
        l.clipsToBounds = true
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }()

    private lazy var downloadProgressView: UIProgressView = {
        let p = UIProgressView(progressViewStyle: .bar)
        p.translatesAutoresizingMaskIntoConstraints = false
        p.trackTintColor = UIColor.white.withAlphaComponent(0.12)
        p.progressTintColor = .systemCyan
        p.isHidden = true
        return p
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        contentView.layer.cornerRadius = 8
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        contentView.clipsToBounds = true

        contentView.addSubview(indexLabel)
        contentView.addSubview(statusBadgeLabel)
        contentView.addSubview(nameLabel)
        contentView.addSubview(downloadProgressView)

        NSLayoutConstraint.activate([
            indexLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            indexLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            indexLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBadgeLabel.leadingAnchor, constant: -6),

            statusBadgeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            statusBadgeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            statusBadgeLabel.heightAnchor.constraint(equalToConstant: 17),

            nameLabel.topAnchor.constraint(equalTo: indexLabel.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: downloadProgressView.topAnchor, constant: -4),

            downloadProgressView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            downloadProgressView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            downloadProgressView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            downloadProgressView.heightAnchor.constraint(equalToConstant: 3)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configure(name: nil, index: nil, isSelected: false, downloadState: .idle)
    }

    func configure(name: String?, index: Int?, isSelected: Bool, downloadState: ViewController.GiftDownloadState) {
        isCellSelected = isSelected
        nameLabel.text = name
        if let index {
            indexLabel.text = String(format: "%03d", index)
        } else {
            indexLabel.text = nil
        }

        configureDownloadState(downloadState)

        if isSelected {
            contentView.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.2)
            contentView.layer.borderColor = UIColor.systemCyan.cgColor
            indexLabel.textColor = UIColor.systemCyan.withAlphaComponent(0.9)
        } else {
            updateCardChrome(for: downloadState)
            indexLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        }
    }

    func updateDownloadState(_ state: ViewController.GiftDownloadState) {
        configureDownloadState(state, animated: false)
        if isCellSelected {
            contentView.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.2)
            contentView.layer.borderColor = UIColor.systemCyan.cgColor
        } else {
            updateCardChrome(for: state)
        }
    }

    private func updateCardChrome(for state: ViewController.GiftDownloadState) {
        switch state {
        case .cached:
            contentView.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.12)
            contentView.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.62).cgColor
        case .failed:
            contentView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.1)
            contentView.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.48).cgColor
        case .downloading:
            contentView.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.1)
            contentView.layer.borderColor = UIColor.systemCyan.withAlphaComponent(0.48).cgColor
        case .idle:
            contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        }
    }

    private func configureDownloadState(_ state: ViewController.GiftDownloadState, animated: Bool = false) {
        switch state {
        case .idle:
            statusBadgeLabel.isHidden = true
            statusBadgeLabel.text = nil
            downloadProgressView.isHidden = true
            downloadProgressView.progress = 0
        case .downloading(let progress):
            let percent = min(99, max(0, Int(progress * 100)))
            statusBadgeLabel.isHidden = false
            statusBadgeLabel.text = "下载中 \(percent)%"
            statusBadgeLabel.textColor = .systemCyan
            statusBadgeLabel.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.16)
            downloadProgressView.isHidden = false
            downloadProgressView.progressTintColor = .systemCyan
            downloadProgressView.setProgress(Float(progress), animated: animated)
        case .cached:
            statusBadgeLabel.isHidden = false
            statusBadgeLabel.text = "已缓存"
            statusBadgeLabel.textColor = .systemGreen
            statusBadgeLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.16)
            downloadProgressView.isHidden = true
            downloadProgressView.progress = 1
        case .failed:
            statusBadgeLabel.isHidden = false
            statusBadgeLabel.text = "失败"
            statusBadgeLabel.textColor = .systemRed
            statusBadgeLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.16)
            downloadProgressView.isHidden = true
            downloadProgressView.progress = 0
        }
    }
}
