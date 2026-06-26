import UIKit
import VAPView

final class ViewController: UIViewController {

    private struct GiftEffect: Decodable, Hashable {
        let name: String
        let url: String
    }

    private enum Layout {
        static let pageInset: CGFloat = 16
        static let controlHeight: CGFloat = 44
        static let spacing: CGFloat = 12
    }

    private var giftEffects: [GiftEffect] = []
    private var selectedGiftIndex: Int?
    private var selectedAlphaPlacement: VAPAlphaPlacement = .right

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

    private let playLeftButton = UIButton(type: .system)
    private let playRightButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let clearCacheButton = UIButton(type: .system)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Gift Effects"
        view.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.1, alpha: 1)

        configureButtons()
        setupLayout()
        loadGiftEffects()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    // MARK: - Setup

    private func configureButtons() {
        makeButton(playLeftButton, title: "Alpha Left", color: .systemBlue)
        makeButton(playRightButton, title: "Alpha Right", color: .systemIndigo)
        makeButton(stopButton, title: "Stop", color: .systemRed)
        makeButton(clearCacheButton, title: "Clear Cache", color: .systemOrange)

        playLeftButton.addTarget(self, action: #selector(playLeftTapped), for: .touchUpInside)
        playRightButton.addTarget(self, action: #selector(playRightTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        clearCacheButton.addTarget(self, action: #selector(clearCacheTapped), for: .touchUpInside)

        updateAlphaButtons()
    }

    private func makeButton(_ button: UIButton, title: String, color: UIColor) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = color
        button.layer.cornerRadius = 8
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.72
    }

    private func setupLayout() {
        let controlsStack = UIStackView(arrangedSubviews: [
            playLeftButton,
            playRightButton,
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
            guard let url = Bundle.main.url(forResource: "gift_effects_mp4", withExtension: "json") else {
                giftEffects = []
                selectedGiftIndex = nil
                collectionView.reloadData()
                giftNameLabel.text = "No gift list"
                setStatus("gift_effects_mp4.json not found")
                return
            }

            let data = try Data(contentsOf: url)
            giftEffects = try JSONDecoder().decode([GiftEffect].self, from: data)
            selectedGiftIndex = giftEffects.isEmpty ? nil : 0
            collectionView.reloadData()
            updateSelectedGiftText()

            if giftEffects.isEmpty {
                setStatus("Gift list is empty")
            } else {
                setStatus("Ready - \(giftEffects.count) gifts - \(alphaPlacementTitle(selectedAlphaPlacement))")
            }
        } catch {
            giftEffects = []
            selectedGiftIndex = nil
            collectionView.reloadData()
            giftNameLabel.text = "Load failed"
            setStatus("Gift list error: \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    @objc private func playLeftTapped() {
        selectedAlphaPlacement = .left
        updateAlphaButtons()
        startSelectedGift()
    }

    @objc private func playRightTapped() {
        selectedAlphaPlacement = .right
        updateAlphaButtons()
        startSelectedGift()
    }

    @objc private func stopTapped() {
        vapView.stop()
        progressBar.isHidden = true
        setStatus("Stopped - \(selectedGift?.name ?? "No gift")")
    }

    @objc private func clearCacheTapped() {
        do {
            try VAPDiskCache.shared.clearCache()
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
        startPlay(effect: selectedGift, alphaPlacement: selectedAlphaPlacement)
    }

    private func startPlay(effect: GiftEffect, alphaPlacement: VAPAlphaPlacement) {
        print("[VAPDemo] play gift=\(effect.name) alphaPlacement=\(alphaPlacement)")
        progressBar.isHidden = true
        progressBar.progress = 0
        setStatus("Starting - \(alphaPlacementTitle(alphaPlacement))")

        let config = VAPPlayConfig(
            filePath: effect.url,
            alphaPlacement: alphaPlacement,
            backgroundPolicy: .pauseAndResume,
            contentMode: .aspectFit,
            loopCount: 1
        )

        vapView.play(config: config) { [weak self] event in
            DispatchQueue.main.async {
                self?.handlePlaybackEvent(event, giftName: effect.name)
            }
        }
    }

    private func handlePlaybackEvent(_ event: VAPEvent, giftName: String) {
        switch event {
        case .downloading(let progress):
            progressBar.isHidden = false
            progressBar.setProgress(Float(progress), animated: true)
            setStatus(String(format: "Downloading %.0f%% - %@", progress * 100, giftName))
        case .didStart:
            progressBar.isHidden = true
            setStatus("Playing - \(giftName)")
        case .didPlayFrame(let index):
            if index % 15 == 0 {
                setStatus("Frame \(index) - \(giftName)")
            }
        case .didLoopFinish(let loop, let totalFrames):
            setStatus("Loop \(loop) done - \(totalFrames) frames")
        case .didFinish(let totalFrames):
            progressBar.isHidden = true
            setStatus("Finished - \(totalFrames) frames")
        case .didStop(let lastFrame):
            progressBar.isHidden = true
            setStatus("Stopped - frame \(lastFrame)")
        case .didFail(let error):
            progressBar.isHidden = true
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
    }

    private func updateAlphaButtons() {
        playLeftButton.alpha = selectedAlphaPlacement == .left ? 1 : 0.58
        playRightButton.alpha = selectedAlphaPlacement == .right ? 1 : 0.58
    }

    private func alphaPlacementTitle(_ alphaPlacement: VAPAlphaPlacement) -> String {
        switch alphaPlacement {
        case .left:
            return "Alpha Left"
        case .right:
            return "Alpha Right"
        case .top:
            return "Alpha Top"
        case .bottom:
            return "Alpha Bottom"
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
            isSelected: indexPath.item == selectedGiftIndex
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

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        contentView.layer.cornerRadius = 8
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        contentView.clipsToBounds = true

        contentView.addSubview(indexLabel)
        contentView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            indexLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            indexLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            indexLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),

            nameLabel.topAnchor.constraint(equalTo: indexLabel.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configure(name: nil, index: nil, isSelected: false)
    }

    func configure(name: String?, index: Int?, isSelected: Bool) {
        nameLabel.text = name
        if let index {
            indexLabel.text = String(format: "%03d", index)
        } else {
            indexLabel.text = nil
        }

        if isSelected {
            contentView.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.2)
            contentView.layer.borderColor = UIColor.systemCyan.cgColor
            indexLabel.textColor = UIColor.systemCyan.withAlphaComponent(0.9)
        } else {
            contentView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
            indexLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        }
    }
}
