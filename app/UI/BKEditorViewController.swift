//
//  BKEditorViewController.swift
//  bk波剪 — 波剪页（单素材：看波形 → 切气口 → 导出）
//
//  【本页职责】
//  选完一条视频进来，这一页就是全部工作台：
//    · 顶部预览播放原片，播放头与下方波形指针同步
//    · 中间主轨道：橙/白指针钉中央，波形按时间展开，红罩=要删的气口
//    · 底部概览条：永远显示全局 + 橙色视窗框
//    · 阈值滑杆：左静右响，拖动即按该阈值重检气口
//    · 点绿/红段 → 反选（留/删）；拖红区边缘 → 调气口大小
//    · 「试听剪后」用 composition 听去掉气口的成品；「导出」进导出面板
//
//  【时间轴口径】cuts 永远是**源时间**的删除区间，marks 由它派生。
//  主轨道、概览条、导出全部吃同一份 cuts，单一真源，不存在换算错位。
//
//  【只做第一阶段】红区折叠（redFolded）这一版不启用 —— bk波剪是单素材纯波形，
//  气口就地标红、点选反选、拖边缘调大小就够。BKTrackView 的 phase-2 长按编辑态
//  在 redFolded=false 时被手势仲裁关掉，那几个 delegate 方法留空实现即可。
//

import UIKit
import AVFoundation

final class BKEditorViewController: UIViewController {

    // MARK: - 数据

    private let localID: String
    private var asset: AVAsset?
    private var envelope: BKEnvelope?
    private var total: Double = 0

    /// 删除区间（源时间），编辑状态的唯一真源
    private var cuts: [(Double, Double)] = []
    /// 由 cuts 派生的完整覆盖序列，喂给主轨道/概览条显示
    private var marks: [BKMark] = []

    /// 当前阈值 dB。滑块拖动即按它重检
    private var thresholdDb: Double = -35
    /// 自动检测算出的阈值，给「恢复自动」用
    private var autoThresholdDb: Double = -35
    /// 素材是否适用静音检测（带 BGM/响度归一化的判不适用）
    private var applicable = true
    private var notApplicableReason: String?

    /// 撤销栈：每次改动前压一份 cuts 快照
    private var undoStack: [[(Double, Double)]] = []

    // MARK: - 播放

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var timeObserver: Any?
    private var isPlaying = false
    /// 是否在播「剪后」composition（此时指针不同步主轨道）
    private var playingCut = false

    // MARK: - 视图

    private let previewView = UIView()
    private let playButton = UIButton(type: .system)
    private let trackView = BKTrackView(frame: .zero)
    private let overviewBar = BKOverviewBar(frame: .zero)
    private let thresholdLabel = UILabel()
    private let thresholdSlider = UISlider()
    private let autoButton = UIButton(type: .system)
    private let bottomBar = UIView()
    private let cutPreviewButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .large)
    private let undoButton = UIBarButtonItem()

    // MARK: - 初始化

    init(localID: String) {
        self.localID = localID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        title = BKVideoLibrary.assetName(localID: localID)
        setupAudio()
        setupUI()
        setupPlayer()
        loadMaterial()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // AVPlayerLayer 不吃 Auto Layout，手动给 frame
        playerLayer.frame = previewView.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player.pause()
        isPlaying = false
    }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - 音频会话（铁律：不设 .playback 服从静音键，整条无声）

    private func setupAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            BKLog.shared.w("波剪页音频会话设置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - UI

    private func setupUI() {
        // 预览区
        previewView.backgroundColor = BKTheme.Color.preview
        previewView.clipsToBounds = true
        view.addSubview(previewView)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
        previewView.layer.addSublayer(playerLayer)

        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.tintColor = .white
        playButton.backgroundColor = UIColor(hex: 0x000000, alpha: 0.35)
        playButton.layer.cornerRadius = 28
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        previewView.addSubview(playButton)

        // 主轨道
        trackView.delegate = self
        trackView.allowsSiblingSwitch = false   // 单素材，禁用越界换片
        view.addSubview(trackView)

        // 概览条
        overviewBar.delegate = self
        view.addSubview(overviewBar)

        // 阈值行
        let thresholdTitle = UILabel()
        thresholdTitle.text = "阈值"
        thresholdTitle.font = BKTheme.Font.caption
        thresholdTitle.textColor = BKTheme.Color.text2
        thresholdTitle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thresholdTitle)

        thresholdLabel.font = BKTheme.Font.mono
        thresholdLabel.textColor = BKTheme.Color.warning
        thresholdLabel.text = "-35.0 dB"
        view.addSubview(thresholdLabel)

        thresholdSlider.minimumValue = Float(BKConfig.Detect.clampLow)
        thresholdSlider.maximumValue = Float(BKConfig.Detect.clampHigh)
        thresholdSlider.value = Float(thresholdDb)
        thresholdSlider.minimumTrackTintColor = BKTheme.Color.warning
        thresholdSlider.maximumTrackTintColor = BKTheme.Color.line
        thresholdSlider.addTarget(self, action: #selector(thresholdChanged), for: .valueChanged)
        view.addSubview(thresholdSlider)

        autoButton.setImage(BKIcons.backToAuto(side: 20), for: .normal)
        autoButton.tintColor = BKTheme.Color.text2
        autoButton.addTarget(self, action: #selector(backToAutoTapped), for: .touchUpInside)
        view.addSubview(autoButton)

        // 状态/提示
        statusLabel.font = BKTheme.Font.caption
        statusLabel.textColor = BKTheme.Color.text3
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        view.addSubview(statusLabel)

        // 底部操作条
        bottomBar.backgroundColor = BKTheme.Color.bar
        bottomBar.layer.borderWidth = 1
        bottomBar.layer.borderColor = BKTheme.Color.line.cgColor
        view.addSubview(bottomBar)

        cutPreviewButton.setTitle("试听剪后", for: .normal)
        cutPreviewButton.titleLabel?.font = BKTheme.Font.button
        cutPreviewButton.tintColor = BKTheme.Color.text
        cutPreviewButton.addTarget(self, action: #selector(cutPreviewTapped), for: .touchUpInside)
        bottomBar.addSubview(cutPreviewButton)

        exportButton.setTitle("导出", for: .normal)
        exportButton.titleLabel?.font = BKTheme.Font.button
        exportButton.tintColor = .white
        exportButton.backgroundColor = BKTheme.Color.accent
        exportButton.layer.cornerRadius = BKTheme.Button.radius
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)
        bottomBar.addSubview(exportButton)

        // 加载指示
        activity.color = BKTheme.Color.text
        activity.hidesWhenStopped = true
        activity.startAnimating()
        view.addSubview(activity)

        // 撤销按钮
        undoButton.title = "撤销"
        undoButton.target = self
        undoButton.action = #selector(undoTapped)
        undoButton.isEnabled = false
        navigationItem.rightBarButtonItem = undoButton

        // 布局
        for v in [previewView, trackView, overviewBar, thresholdLabel, thresholdSlider,
                  autoButton, statusLabel, bottomBar, activity, playButton,
                  cutPreviewButton, exportButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        let previewH = BKConfig.Layout.previewFixedH
        let trackH = BKConfig.Layout.trackFixedH
        let ovH: CGFloat = 36
        let bottomH: CGFloat = 56
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.heightAnchor.constraint(equalToConstant: previewH),

            playButton.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 56),
            playButton.heightAnchor.constraint(equalToConstant: 56),

            trackView.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: BKTheme.Space.sm),
            trackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trackView.heightAnchor.constraint(equalToConstant: trackH),

            overviewBar.topAnchor.constraint(equalTo: trackView.bottomAnchor, constant: BKTheme.Space.sm),
            overviewBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.md),
            overviewBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.md),
            overviewBar.heightAnchor.constraint(equalToConstant: ovH),

            thresholdTitle.topAnchor.constraint(equalTo: overviewBar.bottomAnchor, constant: BKTheme.Space.md),
            thresholdTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.md),
            thresholdTitle.centerYAnchor.constraint(equalTo: thresholdSlider.centerYAnchor),

            thresholdSlider.topAnchor.constraint(equalTo: overviewBar.bottomAnchor, constant: BKTheme.Space.md),
            thresholdSlider.leadingAnchor.constraint(equalTo: thresholdTitle.trailingAnchor, constant: BKTheme.Space.sm),
            thresholdSlider.trailingAnchor.constraint(equalTo: autoButton.leadingAnchor, constant: -BKTheme.Space.sm),

            autoButton.centerYAnchor.constraint(equalTo: thresholdSlider.centerYAnchor),
            autoButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.md),
            autoButton.widthAnchor.constraint(equalToConstant: 32),
            autoButton.heightAnchor.constraint(equalToConstant: 32),

            statusLabel.topAnchor.constraint(equalTo: thresholdSlider.bottomAnchor, constant: BKTheme.Space.xs),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.md),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.md),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: bottomH),

            cutPreviewButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: BKTheme.Space.md),
            cutPreviewButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            cutPreviewButton.widthAnchor.constraint(equalToConstant: 100),
            cutPreviewButton.heightAnchor.constraint(equalToConstant: 40),

            exportButton.leadingAnchor.constraint(equalTo: cutPreviewButton.trailingAnchor, constant: BKTheme.Space.sm),
            exportButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -BKTheme.Space.md),
            exportButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            exportButton.heightAnchor.constraint(equalToConstant: 40),

            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func setupPlayer() {
        playerLayer.videoGravity = .resizeAspect
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self = self else { return }
            // 剪后预览时间轴与源时间不一致，不驱动主轨道指针
            guard !self.playingCut else { return }
            let sec = CMTimeGetSeconds(t)
            if self.isPlaying {
                self.trackView.setPointerTime(sec)
            } else {
                self.isPlaying = false
            }
            self.syncPlayIcon()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackEnded),
            name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    // MARK: - 加载素材

    private func loadMaterial() {
        BKVideoLibrary.loadAVAsset(localID: localID) { [weak self] asset in
            guard let self = self else { return }
            guard let asset = asset else {
                DispatchQueue.main.async {
                    self.activity.stopAnimating()
                    self.statusLabel.text = "视频加载失败（可能还在 iCloud 上，联网重试一次）"
                }
                return
            }
            self.asset = asset
            BKAudioAnalyzer.extractEnvelope(from: asset) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.activity.stopAnimating()
                    switch result {
                    case .success(let env):
                        self.envelope = env
                        self.total = env.duration
                        self.runDetect(override: nil)
                    case .failure(let err):
                        self.statusLabel.text = "包络提取失败：\(err.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - 检测 / 刷新

    /// 跑一次检测（override=nil 走 Otsu 自动）。结果写进 cuts，刷新双视图
    private func runDetect(override: Double?) {
        guard let env = envelope, total > 0 else { return }
        let out = BKDetector.detect(envelope: env, totalDuration: total, overrideThreshold: override)
        applicable = out.info.applicable
        notApplicableReason = out.info.reason
        thresholdDb = out.info.thresholdDb
        autoThresholdDb = out.info.thresholdDb
        cuts = out.cuts
        marks = BKTimeline.build(duration: total, cuts: cuts)
        thresholdSlider.value = Float(thresholdDb)
        thresholdLabel.text = String(format: "%.1f dB", thresholdDb)

        if !applicable {
            statusLabel.text = notApplicableReason ?? "该素材不适用静音检测"
            statusLabel.textColor = BKTheme.Color.warning
        } else {
            statusLabel.text = String(format: "自动找到 %d 处气口 · 拖动阈值可增删", out.info.adoptedCount)
            statusLabel.textColor = BKTheme.Color.text3
        }
        refreshTrack()
        // 预览里也垫上原片，方便边看波形边听
        if let a = asset, player.currentItem == nil {
            player.replaceCurrentItem(with: AVPlayerItem(asset: a))
        }
    }

    /// marks → 连续 cut 段（源时间），作为 cuts 的唯一来源
    private func cutsFromMarks(_ m: [BKMark]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var i = 0
        while i < m.count {
            if m[i].kind == .cut {
                let s = m[i].start
                var j = i
                while j < m.count, m[j].kind == .cut { j += 1 }
                out.append((s, m[j - 1].end))
                i = j
            } else { i += 1 }
        }
        return out
    }

    /// 用当前 cuts 重画主轨道 + 概览条
    private func refreshTrack() {
        let pieces = BKTimeline.pieces(duration: total, cuts: cuts, splits: [])
        trackView.setContent(envelope: envelope, pieces: pieces, splits: [],
                             duration: total, thresholdDb: thresholdDb, redFolded: false)
        overviewBar.setContent(envelope: envelope, pieces: pieces, duration: total,
                               viewport: trackView.viewport)
    }

    // MARK: - 撤销

    private func pushUndo() {
        undoStack.append(cuts)
        if undoStack.count > BKConfig.Draft.undoLimit { undoStack.removeFirst() }
        undoButton.isEnabled = true
    }

    @objc private func undoTapped() {
        guard let prev = undoStack.popLast() else { return }
        cuts = prev
        marks = BKTimeline.build(duration: total, cuts: cuts)
        refreshTrack()
        if undoStack.isEmpty { undoButton.isEnabled = false }
    }

    // MARK: - 动作

    @objc private func thresholdChanged() {
        thresholdDb = Double(thresholdSlider.value)
        thresholdLabel.text = String(format: "%.1f dB", thresholdDb)
        // 拖动即按该阈值重检（包络已在内存，很快）
        runDetect(override: thresholdDb)
        // 阈值重检等同重做，撤销栈清空
        undoStack.removeAll()
        undoButton.isEnabled = false
    }

    @objc private func backToAutoTapped() {
        thresholdSlider.value = Float(autoThresholdDb)
        runDetect(override: nil)
        undoStack.removeAll()
        undoButton.isEnabled = false
    }

    @objc private func playTapped() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        syncPlayIcon()
    }

    private func syncPlayIcon() {
        let playing = player.timeControlStatus == .playing
        isPlaying = playing
        playButton.isHidden = playing
    }

    @objc private func playbackEnded() {
        player.seek(to: .zero)
        player.pause()
        isPlaying = false
        if playingCut {
            // 剪后播完，回到原片待播状态
            playingCut = false
            if let a = asset { player.replaceCurrentItem(with: AVPlayerItem(asset: a)) }
        }
        playButton.isHidden = false
    }

    @objc private func cutPreviewTapped() {
        guard let asset = asset else { return }
        if playingCut {
            // 退出剪后预览
            playingCut = false
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.pause()
            isPlaying = false
            playButton.isHidden = false
            cutPreviewButton.setTitle("试听剪后", for: .normal)
            return
        }
        let keeps = BKDetector.keptSegments(cuts, totalSec: total)
        guard let built = BKCompositionBuilder.make(asset: asset, keeps: keeps) else {
            statusLabel.text = "没有可保留的片段，先少删一点"
            return
        }
        let item = AVPlayerItem(asset: built.comp)
        player.replaceCurrentItem(with: item)
        playingCut = true
        player.play()
        isPlaying = true
        playButton.isHidden = true
        cutPreviewButton.setTitle("退出剪后", for: .normal)
    }

    @objc private func exportTapped() {
        guard let asset = asset, total > 0 else {
            statusLabel.text = "素材未就绪，无法导出"
            return
        }
        let title = (BKVideoLibrary.assetName(localID: localID) as NSString)
            .deletingPathExtension
        let panel = BKExportPanelViewController(asset: asset, duration: total,
                                               cuts: cuts, title: title)
        let nav = UINavigationController(rootViewController: panel)
        present(nav, animated: true)
    }

    /// 拖动/点选时把原片 player seek 到该源时间（暂停态下只更新画面）
    private func seekOriginal(to t: Double) {
        guard !playingCut, player.currentItem != nil else { return }
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - 主轨道回调

extension BKEditorViewController: BKTrackViewDelegate {

    func track(_ view: BKTrackView, didScrollTo time: Double) {
        overviewBar.setViewport(view.viewport)
        // 暂停态下拖动 = 预览画面跟着走（不出声）
        if !isPlaying { seekOriginal(to: time) }
    }

    func track(_ view: BKTrackView, didTogglePieceAt time: Double) {
        // 找到包含 time 的那一段
        guard let idx = marks.firstIndex(where: { time >= $0.start - 1e-9 && time <= $0.end + 1e-9 })
        else { return }
        pushUndo()
        let next = BKTimeline.toggle(marks: marks, at: idx)
        cuts = cutsFromMarks(next)
        marks = BKTimeline.build(duration: total, cuts: cuts)
        refreshTrack()
    }

    func track(_ view: BKTrackView, didChangeZoomTo screens: CGFloat) {
        overviewBar.setViewport(view.viewport)
    }

    func trackDidTouchDown(_ view: BKTrackView) {
        // 手指一碰轨道立刻停声，避免拖动第一帧漏音
        if isPlaying {
            player.pause()
            isPlaying = false
            playButton.isHidden = false
        }
    }

    func trackDidPullBeyondHead(_ view: BKTrackView) {
        // 单素材：无上一条，忽略
    }

    func trackDidPullBeyondTail(_ view: BKTrackView) {
        // 单素材：无下一条，忽略
    }

    func track(_ view: BKTrackView, didBeginRedEdgeDragNear time: Double) {
        pushUndo()
    }

    func track(_ view: BKTrackView, didDragRedEdgeNear near: Double, to newTime: Double) {
        guard let next = BKTimeline.moveRedEdge(cuts: cuts, near: near, to: newTime,
                                                duration: total) else { return }
        cuts = next
        marks = BKTimeline.build(duration: total, cuts: cuts)
        refreshTrack()
    }

    func trackDidEndRedEdgeDrag(_ view: BKTrackView) {
        // 拖动已逐帧提交，这里无需额外处理
    }

    // MARK: 第二阶段（红区折叠）回调 —— 本版不启用，留空

    func track(_ view: BKTrackView, didBeginRegionEditFrom start: Double, to end: Double) {}
    func track(_ view: BKTrackView, didDragRegionEdge handle: BKHandleEnd, to newTime: Double) {}
    func track(_ view: BKTrackView, didCommitRegionEditFrom start: Double, to end: Double) {}
}

// MARK: - 概览条回调

extension BKEditorViewController: BKOverviewBarDelegate {
    func overview(_ bar: BKOverviewBar, didSeekTo time: Double) {
        trackView.setPointerTime(time)
        seekOriginal(to: time)
    }
}
