import UIKit
import VAPPlayer

final class ViewController: UIViewController {

//    private let remoteURL = "https://qiniu-xbyy.yinyou.live/channel/gift/QFB6BC-1774343076586.mp4"
    private let remoteURL = "https://qiniu-xbyy.yinyou.live/channel/gift/nHXSQ3-1770173189405.mp4"

    private lazy var vapView: VAPView = {
        let v = VAPView(frame: .zero)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .black
        return v
    }()

    private lazy var statusLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textAlignment = .center
        l.textColor = .white
        l.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        l.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        l.numberOfLines = 0
        l.layer.cornerRadius = 8
        l.clipsToBounds = true
        l.text = "Ready"
        return l
    }()

    private lazy var progressBar: UIProgressView = {
        let p = UIProgressView(progressViewStyle: .bar)
        p.translatesAutoresizingMaskIntoConstraints = false
        p.isHidden = true
        return p
    }()

    private let playLeftButton = UIButton(type: .system)
    private let playRightButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let clearCacheButton = UIButton(type: .system)

    private func makeButton(_ b: UIButton, title: String, color: UIColor) {
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = color
        b.layer.cornerRadius = 8
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "VAPPlayer Demo"
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        makeButton(playLeftButton, title: "Alpha Left", color: .systemBlue)
        makeButton(playRightButton, title: "Alpha Right", color: .systemIndigo)
        makeButton(stopButton, title: "Stop", color: .systemRed)
        makeButton(clearCacheButton, title: "Clear Cache", color: .systemOrange)
        playLeftButton.addTarget(self, action: #selector(playLeftTapped), for: .touchUpInside)
        playRightButton.addTarget(self, action: #selector(playRightTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        clearCacheButton.addTarget(self, action: #selector(clearCacheTapped), for: .touchUpInside)
        setupLayout()
    }

    private func setupLayout() {
        view.addSubview(vapView)
        view.addSubview(progressBar)
        view.addSubview(statusLabel)
        view.addSubview(stopButton)
        view.addSubview(clearCacheButton)

        let buttonStack = UIStackView(arrangedSubviews: [playLeftButton, playRightButton, stopButton, clearCacheButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            vapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            vapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vapView.heightAnchor.constraint(equalTo: vapView.widthAnchor),

            progressBar.topAnchor.constraint(equalTo: vapView.bottomAnchor, constant: 8),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            buttonStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // MARK: - Actions

    @objc private func playLeftTapped() {
        startPlay(blendMode: .alphaLeft)
    }

    @objc private func playRightTapped() {
        startPlay(blendMode: .alphaRight)
    }

    private func startPlay(blendMode: VAPTextureBlendMode) {
        print("[VAPDemo] startPlay blendMode=\(blendMode)")
        setStatus("Starting...")
        progressBar.isHidden = true
        progressBar.progress = 0

        let config = VAPPlayConfig(
            filePath: remoteURL,
            blendMode: blendMode,
            backgroundPolicy: .pauseAndResume,
            contentMode: .aspectFit,
            loopCount: 1
        )

        vapView.play(config: config) { [weak self] event in
            guard let self else { return }
//            print("[VAPDemo] onEvent \(event)")
//            DispatchQueue.main.async {
//                switch event {
//                case .downloading(let p):
//                    self.progressBar.isHidden = false
//                    self.progressBar.setProgress(Float(p), animated: true)
//                    self.setStatus(String(format: "Downloading… %.0f%%", p * 100))
//                case .didStart:
//                    self.progressBar.isHidden = true
//                    self.setStatus("▶ Playing")
//                case .didPlayFrame(let idx):
//                    if idx % 10 == 0 { self.setStatus("Frame \(idx)") }
//                case .didLoopFinish(let loop, let total):
//                    self.setStatus("Loop \(loop) done — \(total) frames")
//                case .didFinish(let total):
//                    self.setStatus("✓ Finished — \(total) frames")
//                case .didStop(let last):
//                    self.setStatus("■ Stopped at frame \(last)")
//                case .didFail(let err):
//                    let msg = "✗ Error: \(err)"
//                    print("[VAPDemo] \(msg)")
//                    self.setStatus(msg)
//                }
//            }
        }
    }

    @objc private func stopTapped() {
        vapView.stop()
        setStatus("Stopped")
    }

    @objc private func clearCacheTapped() {
        do {
            try VAPDiskCache.shared.clearCache()
            setStatus("Cache cleared")
        } catch {
            setStatus("Clear failed: \(error.localizedDescription)")
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.text = text
    }
}
