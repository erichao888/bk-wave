//
//  BKEditorViewController.swift
//  bk波剪 — 波剪页（单素材：看波形 → 切气口 → 导出）
//
//  【这份代码的上级 = ck剪辑 v2.0 波剪子页的界面布局（皓哥 2026-10-07 截图拍板）】
//  布局照 ck v2.0 移植：导航栏（返回+清单+文件名）→ 预览 → 数字行
//  → 主轨道 → 概览条 → 阈值行 → 状态行 → 两排工具栏（7 键 + ✕ − +）。
//  与 ck v2.0 的差异只有一处：导出入口放在导航栏右上角（ck 的导出在主编辑页，
//  bk波剪是单素材独立 App，波剪页就是全部工作台，导出必须有地方放）。
//
//  【本页承担什么】
//  波形可视化 + 自动检测 + 手动微调 + 撤销重做 + 播放校对 + 导出。
//
//  【数据流】
//  asset → BKAudioAnalyzer 提取包络 → BKDetector 出切点
//        → BKTimeline.build 合成 marks → 轨道画出来
//  手动拖红区边缘 / 点片段 → 改 cuts → pushUndo 入撤销栈 → 重画
//
//  【时间轴口径】cuts 永远是**源时间**的删除区间，marks 由它派生。
//  主轨道、概览条、导出全部吃同一份 cuts，单一真源，不存在换算错位。
//
//  【两个播放键】
//  ▶ 原片播（红区绿区都播） ｜ `|▶|` 联播（按 keeps 拼起来播，跳过红区）
//  两者起点都是指针那一帧（指针在红区时联播跳到下一个绿区），互斥。
//  停止一律**停在原地**（ck 定稿 4.5.2）。
//
//  ✗✗ 键在单素材版里的语义 = 「清空全部红区」（ck 里它是「删红折叠进第二阶段」，
//  bk波剪没有第二阶段，cuts 就是最终删除区间，所以等价动作是全部恢复）。
//  ✕ 键 = 把这条从本批素材列表清除，并**自动跳到下一条继续剪**（ck 里它就是「从批次移除」）。
//  废片（整条口播都不对）没必要剪也没必要导，清掉后接着剪下一条，流程不中断。
//
//  【指针居中带来的一个连锁变化】
//  指针不动、内容滚，所以「预览画面跟指针跳帧」变成了：
//  滚动回调 → seek 播放器。预览画面本身不需要任何动效代码。
//

import UIKit
import AVFoundation

final class BKEditorViewController: UIViewController {

    // MARK: - 播放模式

    private enum PlayMode {
        case idle
        /// ▶ 原片播
        case straight
        /// `|▶|` 联播（拼起来的成品）
        case joint
    }

    /// 撤销栈快照：cuts + 显示接缝 + 折叠态。
    /// 阈值重检也会先把旧状态压栈，手调过的刀口能靠撤销找回来
    private struct EditState {
        var cuts: [(Double, Double)]
        var splits: [Double]
        var keepBase: [(Double, Double)]?
    }

    // MARK: - 数据

    /// 当前素材的相册 localID（从草稿批里取，加载后才有值）
    private var localID: String = ""
    /// 所属草稿批 + 批内序号；切素材时会被改，所以是 var
    private let batchID: UUID?
    private var itemIndex: Int
    private var asset: AVAsset?
    private var envelope: BKEnvelope?
    private var total: Double = 0

    /// 删除区间（源时间），编辑状态的唯一真源
    private var cuts: [(Double, Double)] = []
    /// 由 cuts 派生的完整覆盖序列，喂给主轨道/概览条显示
    private var marks: [BKMark] = []
    /// 纯显示接缝（✂ 加的分割线，不改数据，ck Q3 拍板）
    private var splits: [Double] = []
    /// 素材原始时长（检测/导出永远以它为基准，不被折叠态改动）
    private var assetTotal: Double = 0
    /// 折叠后的「保留段」（源时间）。nil = 未折叠（红区还在，cuts 是删除区间）。
    /// 非 nil = 已点✗✗，主轨只剩这些绿段，total 已被重映射成折叠后时长。
    private var keepBase: [(Double, Double)]? = nil

    /// 当前阈值 dB。滑块拖动即按它重检
    private var thresholdDb: Double = -35
    /// 自动检测算出的阈值，给「恢复自动」用
    private var autoThresholdDb: Double?
    /// 素材是否适用静音检测（带 BGM/响度归一化的判不适用）
    private var applicable = true

    /// 用户是否动过刀（决定 ☰ 列表里文件名是否标红）
    private var everEdited: Bool = false
    /// 折叠红区时的删除区间数（首页「N 刀」徽标用；折叠后 cuts 清空，只能靠它记）
    private var redCount = 0
    /// 落盘 debounce 任务
    private var persistWork: DispatchWorkItem?

    /// 撤销 / 重做栈
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []

    // MARK: - 播放

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var timeObserver: Any?
    private var playMode: PlayMode = .idle
    /// 原片的 item 常驻；联播时临时换成 composition 的 item，停了再换回来
    private var originalItem: AVPlayerItem?
    private var jointBuild: BKCompositionBuild?
    /// 阈值滑杆的防抖（停 0.4 秒才真正重算）
    private var sliderWork: DispatchWorkItem?

    private var lastTime: Double = 0

    // MARK: - 视图

    private let previewContainer = UIView()
    private let trackContainer = UIView()
    private let trackView = BKTrackView(frame: .zero)
    private let overviewBar = BKOverviewBar(frame: .zero)

    // 工具栏第一排：撤销 / 重做 / 联播 / 播放 / 清红 / 切割 / 检测
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let jointButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let deleteRedButton = UIButton(type: .system)
    private let cutButton = UIButton(type: .system)
    private let detectButton = UIButton(type: .system)

    // 工具栏第二排：✕（清除本条，红色圆）在 − + 左边
    private let removeButton = UIButton(type: .system)
    private let zoomOutButton = UIButton(type: .system)
    private let zoomInButton = UIButton(type: .system)

    private let thresholdTitle = UILabel()
    private let thresholdSlider = UISlider()
    private let thresholdAutoButton = UIButton(type: .system)
    private let timeLabel = UILabel()
    private let infoLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    // MARK: - 初始化

    init(batchID: UUID, index: Int) {
        self.batchID = batchID
        self.itemIndex = index
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        setupNav()
        setupAudio()
        setupPlayer()
        setupUI()
        loadMaterial()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 边缘右滑返回和「拖红区边缘」是死敌：手指从屏幕左缘起手往右拖，
        // 系统会当成返回手势，整个编辑页跟着滑走。剪辑页一律用左上角按钮返回
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        persistItem()
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        stopPlayback()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // AVPlayerLayer 不吃 Auto Layout，手动给 frame
        playerLayer.frame = previewContainer.bounds
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

    // MARK: - 导航栏

    private func setupNav() {
        // 标题在 loadMaterial 里按草稿名设置

        // 左上角返回（关闭）：回首页草稿列表
        let backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(closeTapped))
        backItem.accessibilityLabel = "返回草稿列表"

        // ☰ 素材清单：本批所有素材，点开勾选导出 / 切换编辑
        let listItem = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal"),
                                       style: .plain,
                                       target: self,
                                       action: #selector(listTapped))
        listItem.accessibilityLabel = "本批素材清单"
        navigationItem.leftBarButtonItems = [backItem, listItem]

        // 导出放导航栏右上角（ck 的导出在主编辑页；本 App 波剪页就是全部工作台）
        let exportItem = UIBarButtonItem(title: "导出",
                                         style: .plain,
                                         target: self,
                                         action: #selector(exportTapped))
        exportItem.tintColor = BKTheme.Color.accent
        navigationItem.rightBarButtonItem = exportItem
    }

    // MARK: - 播放器

    private func setupPlayer() {
        player.automaticallyWaitsToMinimizeStalling = false
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player

        // 0.033 ≈ 30fps。滚动是连续画面，20fps 会明显一格一格地跳
        let interval = CMTime(seconds: 0.033, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self = self else { return }
            let sec = CMTimeGetSeconds(t)
            switch self.playMode {
            case .idle:
                break
            case .straight:
                // 原片 player 报的是原片时间，折叠态要反查回显示轴
                self.syncPlayhead(to: self.displayTime(of: sec))
            case .joint:
                guard let j = self.jointBuild else { return }
                if sec >= j.total - 0.02 {
                    self.stopPlayback()
                } else {
                    // 折叠态：主轨就是成品时间轴，指针直接落在成品时间上；
                    // 未折叠：成品时间 → 反查原片时间，指针在原片轴上连贯前进
                    let pointerT = (self.keepBase != nil) ? sec
                        : BKCompositionBuilder.sourceTime(j, outputTime: sec)
                    self.syncPlayhead(to: pointerT)
                }
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackEnded),
            name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    @objc private func playbackEnded() {
        stopPlayback()
    }

    /// 播放回调 / 手动 seek 之后统一走这里：
    /// 时间码、指针、概览条视窗框三处必须同时跟上，漏一处就会看到「画面和框对不上」
    private func syncPlayhead(to t: Double) {
        guard total > 0 else { return }
        let clamped = min(max(t, 0), total)
        lastTime = clamped
        timeLabel.text = "\(formatClock(clamped)) / \(formatClock(total))"
        trackView.setPointerTime(clamped)
        overviewBar.setViewport(trackView.viewport)
    }

    // MARK: - UI

    private func setupUI() {
        // ---- 预览画面：固定高度框，横竖屏都 letterbox 进这个区域 ----
        let previewH = BKConfig.Layout.previewFixedH
        let trackH = BKConfig.Layout.trackFixedH

        previewContainer.backgroundColor = BKTheme.Color.preview
        previewContainer.layer.cornerRadius = BKTheme.Radius.card
        previewContainer.clipsToBounds = true
        previewContainer.layer.addSublayer(playerLayer)

        trackContainer.backgroundColor = BKTheme.Color.page
        trackContainer.layer.cornerRadius = BKTheme.Radius.card
        trackContainer.clipsToBounds = true
        trackView.delegate = self
        trackView.allowsSiblingSwitch = true   // 拖到头/尾再继续拖可切上/下一条素材
        trackContainer.addSubview(trackView)
        trackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            trackView.leadingAnchor.constraint(equalTo: trackContainer.leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: trackContainer.trailingAnchor),
            trackView.topAnchor.constraint(equalTo: trackContainer.topAnchor),
            trackView.bottomAnchor.constraint(equalTo: trackContainer.bottomAnchor)
        ])

        overviewBar.delegate = self

        // ---- 数字行：紧贴画面下面 ----
        timeLabel.font = BKTheme.Font.monoBig
        timeLabel.textColor = BKTheme.Color.text
        timeLabel.text = "00:00 / 00:00"
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        infoLabel.font = BKTheme.Font.monoSmall
        infoLabel.textColor = BKTheme.Color.text2
        infoLabel.numberOfLines = 2
        infoLabel.textAlignment = .right
        infoLabel.text = ""

        let statsSpacer = UIView()
        let statsRow = UIStackView(arrangedSubviews: [timeLabel, statsSpacer, infoLabel])
        statsRow.axis = .horizontal
        statsRow.spacing = BKTheme.Space.md
        statsRow.alignment = .center
        // 时间码数字行必须完整显示：竖直方向设为最高抗压
        statsRow.setContentCompressionResistancePriority(.required, for: .vertical)

        // ---- 阈值行 + 恢复自动按钮 ----
        thresholdTitle.font = BKTheme.Font.mono
        thresholdTitle.textColor = BKTheme.Color.text
        thresholdTitle.setContentHuggingPriority(.required, for: .horizontal)
        thresholdTitle.text = String(format: "阈值 %.1f dB", thresholdDb)

        thresholdSlider.minimumValue = Float(BKConfig.Detect.clampLow)
        thresholdSlider.maximumValue = Float(BKConfig.Detect.clampHigh)
        thresholdSlider.value = Float(thresholdDb)
        thresholdSlider.minimumTrackTintColor = BKTheme.Color.warning
        thresholdSlider.maximumTrackTintColor = BKTheme.Color.line
        thresholdSlider.addTarget(self, action: #selector(thresholdChanged), for: .valueChanged)

        thresholdAutoButton.setImage(BKIcons.backToAuto(side: 20), for: .normal)
        thresholdAutoButton.tintColor = BKTheme.Color.text
        thresholdAutoButton.addTarget(self, action: #selector(thresholdAutoTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            thresholdAutoButton.widthAnchor.constraint(equalToConstant: 24),
            thresholdAutoButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        let thresholdRow = UIStackView(arrangedSubviews: [thresholdTitle, thresholdSlider, thresholdAutoButton])
        thresholdRow.axis = .horizontal
        thresholdRow.spacing = BKTheme.Space.sm
        thresholdRow.alignment = .center

        statusLabel.font = BKTheme.Font.caption
        statusLabel.textColor = BKTheme.Color.warning
        statusLabel.numberOfLines = 0

        spinner.hidesWhenStopped = true
        spinner.color = BKTheme.Color.accent

        // 提示文案贴在工具栏正上方，独立于内容栈：
        // 无论上方内容多高，提示区永远不会被底部工具栏遮住（小屏最容易触发遮挡）
        let statusBar = UIStackView(arrangedSubviews: [statusLabel, spinner])
        statusBar.axis = .horizontal
        statusBar.spacing = BKTheme.Space.sm
        statusBar.alignment = .center

        // 顺序：画面 → 数字行 → 主轨道 → 概览 → 阈值
        let filler = UIView()
        let stack = UIStackView(arrangedSubviews: [
            previewContainer, statsRow, trackContainer, overviewBar, thresholdRow, filler
        ])
        stack.axis = .vertical
        stack.spacing = BKTheme.Space.sm
        stack.alignment = .fill

        let toolbar = makeToolbar()

        view.addSubview(stack)
        view.addSubview(toolbar)
        view.addSubview(statusBar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        // 小屏竖向预算不够时宁可让内容栈向下溢出、也不能把提示文字压扁
        statusLabel.backgroundColor = BKTheme.Color.page
        statusBar.backgroundColor = BKTheme.Color.page

        // 内容栈底 ≤ 状态栏顶，优先级 999（全场最低，约束打架时第一个断它）
        let stackUnderStatus = stack.bottomAnchor.constraint(
            lessThanOrEqualTo: statusBar.topAnchor, constant: -BKTheme.Space.md)
        stackUnderStatus.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.lg),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.lg),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: BKTheme.Space.sm),
            stackUnderStatus,

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.lg),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.lg),
            statusBar.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -BKTheme.Space.md),

            previewContainer.heightAnchor.constraint(equalToConstant: previewH),
            trackContainer.heightAnchor.constraint(equalToConstant: trackH),
            overviewBar.heightAnchor.constraint(equalToConstant: 30),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.lg),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.lg),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 100)
        ])

        updateThresholdAutoButton()
        updateUndoButtons()
    }

    /// 工具栏两排：
    /// 第一排 7 个圆钮：`↩ ↪ |▶| ▶ ✗✗ ✂ 💉`
    /// 第二排 `✕ − +` 三个小圆靠右 —— ✕ 放弃本条；− + 是捏合失灵时的缩放保底
    private func makeToolbar() -> UIStackView {
        configureTool(undoButton, systemName: "arrow.uturn.backward", action: #selector(undoTapped))
        configureTool(redoButton, systemName: "arrow.uturn.forward", action: #selector(redoTapped))

        // 联播键 `|▶|`
        jointButton.setImage(BKIcons.skip(), for: .normal)
        applyToolStyle(jointButton, action: #selector(jointTapped))
        // 播放 / 停止是同一个键
        configureTool(playButton, systemName: "play.fill", action: #selector(playTapped))

        // ✗✗ 清空全部红区（自定义纯红双 X，非模板图）
        deleteRedButton.setImage(BKIcons.deleteRedDoubleX(), for: .normal)
        applyToolStyle(deleteRedButton, action: #selector(deleteRedTapped))
        configureTool(cutButton, systemName: "scissors", action: #selector(cutTapped))
        configureTool(detectButton, systemName: "eyedropper", action: #selector(detectTapped))

        let row1 = UIStackView(arrangedSubviews: [
            undoButton, redoButton, jointButton, playButton, deleteRedButton, cutButton, detectButton
        ])
        row1.axis = .horizontal
        row1.spacing = BKTheme.Space.sm
        row1.alignment = .center
        // 均分可用宽度：7 个按钮在任何屏宽下都平分 row1 内部空间，永不溢出挤压
        row1.distribution = .fillEqually
        // 组间 16 = 默认 8 再补 8（撤销重做一组 | 播放联播一组 | 后三个编辑键一组）
        row1.setCustomSpacing(BKTheme.Space.lg, after: redoButton)
        row1.setCustomSpacing(BKTheme.Space.lg, after: playButton)

        styleRemoveStep(removeButton, action: #selector(removeTapped))
        zoomOutButton.setImage(UIImage(systemName: "minus"), for: .normal)
        styleZoomStep(zoomOutButton, action: #selector(zoomOutTapped))
        zoomInButton.setImage(UIImage(systemName: "plus"), for: .normal)
        styleZoomStep(zoomInButton, action: #selector(zoomInTapped))

        let spacer2 = UIView()
        let row2 = UIStackView(arrangedSubviews: [spacer2, removeButton, zoomOutButton, zoomInButton])
        row2.axis = .horizontal
        row2.spacing = BKTheme.Space.sm
        row2.alignment = .center

        let toolbar = UIStackView(arrangedSubviews: [row1, row2])
        toolbar.axis = .vertical
        toolbar.spacing = BKTheme.Space.sm
        toolbar.alignment = .fill
        // 不要灰色底框：按钮直接贴内容区左右边(16pt)，更紧凑。
        // 底色用页面色而非透明：小屏内容栈溢出时穿过工具栏区，页面色能把它盖住
        toolbar.backgroundColor = BKTheme.Color.page
        return toolbar
    }

    private func configureTool(_ button: UIButton, systemName: String, action: Selector) {
        let cfg = UIImage.SymbolConfiguration(pointSize: BKTheme.Button.iconPoint, weight: .regular)
        button.setImage(UIImage(systemName: systemName, withConfiguration: cfg), for: .normal)
        applyToolStyle(button, action: action)
    }

    /// 只套皮 + 挂 action，不动图。自定义图标（联播 `|▶|`、✗✗）用这个入口
    private func applyToolStyle(_ button: UIButton, action: Selector) {
        button.tintColor = BKTheme.Color.text
        button.backgroundColor = BKTheme.Color.panel
        button.layer.cornerRadius = BKTheme.Button.radius
        button.layer.borderWidth = BKTheme.Button.border
        button.layer.borderColor = BKTheme.Color.line.cgColor
        button.clipsToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        // 正方形靠「高 = 宽」保持正圆；宽度不写死，交给 row1 的 fillEqually 按可用宽度均分。
        // 这样 7 个按钮在 15 PM(430pt) 上仍是 44pt，在 16/16 Pro(390/402pt) 上自动缩到
        // 约 38/40pt，不会被 UIStackView 挤成一团。
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalTo: button.widthAnchor)
        ])
    }

    private func styleZoomStep(_ button: UIButton, action: Selector) {
        button.tintColor = BKTheme.Color.text2
        button.backgroundColor = BKTheme.Color.panel
        button.layer.cornerRadius = 14
        button.layer.borderWidth = BKTheme.Button.border
        button.layer.borderColor = BKTheme.Color.line.cgColor
        button.clipsToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    /// ✕ 按钮：红色实心圆 + 白叉，一眼认出是「危险操作」。
    /// 点下去**先弹确认框**，确认后从本批清除这条并自动跳下一条 —— 不直接动手
    private func styleRemoveStep(_ button: UIButton, action: Selector) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        button.setImage(UIImage(systemName: "xmark", withConfiguration: cfg), for: .normal)
        button.tintColor = .white
        button.backgroundColor = BKTheme.Color.danger
        button.layer.cornerRadius = 14
        button.clipsToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    /// 播放键图标 + 联播键高亮，两处一起收在这里，免得改了形状忘了另一处
    private func updatePlayIcons() {
        let cfg = UIImage.SymbolConfiguration(pointSize: BKTheme.Button.iconPoint, weight: .regular)
        playButton.setImage(UIImage(systemName: playMode == .straight ? "stop.fill" : "play.fill",
                                    withConfiguration: cfg), for: .normal)
        jointButton.backgroundColor = (playMode == .joint)
            ? BKTheme.Color.selectBg
            : BKTheme.Color.panel
    }

    // MARK: - 加载素材

    private func loadMaterial() {
        guard let bid = batchID,
              let batch = BKDraftStore.shared.batch(id: bid),
              batch.items.indices.contains(itemIndex) else {
            statusLabel.text = "草稿找不到（可能已被删除）"
            return
        }
        let item = batch.items[itemIndex]
        self.localID = item.localID
        navigationItem.title = item.assetName

        spinner.startAnimating()
        setControlsEnabled(false)
        statusLabel.text = "正在提取音频波形…"
        BKVideoLibrary.loadAVAsset(localID: localID) { [weak self] asset in
            guard let self = self else { return }
            guard let asset = asset else {
                DispatchQueue.main.async {
                    self.spinner.stopAnimating()
                    self.statusLabel.text = "视频加载失败（可能还在 iCloud 上，联网重试一次）"
                }
                return
            }
            self.asset = asset
            DispatchQueue.main.async {
                // 原片 item 常驻；联播只临时换 item，绝不重建 AVPlayer
                let it = AVPlayerItem(asset: asset)
                self.originalItem = it
                self.player.replaceCurrentItem(with: it)
            }
            BKAudioAnalyzer.extractEnvelope(from: asset) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.spinner.stopAnimating()
                    switch result {
                    case .success(let env):
                        self.envelope = env
                        self.assetTotal = env.duration
                        self.total = env.duration
                        self.keepBase = nil
                        self.lastTime = 0
                        self.timeLabel.text = "\(self.formatClock(0)) / \(self.formatClock(self.total))"
                        self.setControlsEnabled(true)
                        // 草稿里已有刀口 → 直接还原，不重跑自动检测（保留上次手调结果）
                        if item.everEdited || !item.cuts.isEmpty || item.keepBase != nil {
                            self.restoreEdits(from: item)
                        } else {
                            self.runDetection(override: nil)
                        }
                    case .failure(let err):
                        self.statusLabel.text = "包络提取失败：\(err.localizedDescription)"
                    }
                }
            }
        }
    }

    /// 从草稿还原编辑态（刀口 / 折叠 / 阈值），不重跑 Otsu
    private func restoreEdits(from item: BKClipItem) {
        self.cuts = item.cuts.tuples
        self.keepBase = item.keepBase?.tuples
        self.thresholdDb = item.thresholdDb
        self.autoThresholdDb = item.autoThresholdDb
        self.everEdited = item.everEdited
        self.redCount = item.redCount ?? 0
        self.thresholdSlider.value = Float(self.thresholdDb)
        self.thresholdTitle.text = String(format: "阈值 %.1f dB", self.thresholdDb)
        if let base = self.keepBase {
            self.total = base.reduce(0.0) { $0 + max(0, $1.1 - $1.0) }
            self.marks = []
            self.statusLabel.text = String(format: "已还原 %d 段保留（剪后 %.1fs）", base.count, self.total)
        } else {
            self.marks = BKTimeline.build(duration: self.assetTotal, cuts: self.cuts)
            self.statusLabel.text = self.cuts.isEmpty
                ? "这条还没动过刀"
                : String(format: "已还原 %d 处气口", self.cuts.count)
        }
        self.refreshTrack()
        self.updateInfo()
        self.updateThresholdAutoButton()
    }

    // MARK: - 检测

    /// 跑一次检测（override=nil 走 Otsu 自动）。
    /// recordUndo=true 时先把当前刀口压进撤销栈 —— 阈值重检会整体重算 cuts，
    /// 手动调过的边界要能靠撤销找回来
    private func runDetection(override: Double?, recordUndo: Bool = false) {
        guard let env = envelope, assetTotal > 0 else { return }
        statusLabel.text = "正在检测气口…"
        spinner.startAnimating()

        let dur = assetTotal
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = BKDetector.detect(envelope: env,
                                            totalDuration: dur,
                                            overrideThreshold: override)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                if recordUndo { self.pushUndo() }
                // 重新检测 = 退折叠，回到原始时间轴
                self.keepBase = nil
                self.total = self.assetTotal
                // ★ 退折叠必须清 splits：折叠态的分割线存的是**成品时间轴**坐标，
                //   换回源轴后继续用会错位（未折叠时显示轴≡源轴）
                self.splits = []
                self.cuts = outcome.cuts
                self.marks = BKTimeline.build(duration: dur, cuts: self.cuts)
                self.thresholdDb = outcome.info.thresholdDb
                if override == nil {
                    // 记下这次自动算出来的**实际使用值**（夹逼之后的）——
                    // 「恢复自动」要回到的就是它，不是未夹逼的原始 Otsu
                    self.autoThresholdDb = outcome.info.thresholdDb
                }
                self.applicable = outcome.info.applicable

                // 程序设值不触发 valueChanged，不会造成重入
                self.thresholdSlider.value = Float(outcome.info.thresholdDb)
                self.thresholdTitle.text = String(format: "阈值 %.1f dB", outcome.info.thresholdDb)

                if !self.applicable {
                    self.statusLabel.text = outcome.info.reason ?? "该素材不适用静音检测"
                } else {
                    self.statusLabel.text = String(format: "自动找到 %d 处气口 · 拖动阈值可增删",
                                                   outcome.info.adoptedCount)
                }
                self.detectButton.isEnabled = self.applicable
                self.detectButton.alpha = self.applicable ? 1.0 : 0.35

                self.refreshTrack()
                self.updateInfo()
                self.updateUndoButtons()
                self.updateThresholdAutoButton()
                // 手动重检（拖阈值 / 点💉）算「动过刀」；首次自动检测不算
                if recordUndo {
                    self.everEdited = true
                    self.schedulePersist()
                }
            }
        }
    }

    /// 轨道 + 概览条一起刷新。分开刷迟早会出现「轨道已经切了，概览条还画着旧的」
    private func refreshTrack() {
        if let base = keepBase {
            // 折叠态：轨道画成「成品时间轴」，靠 foldMap 把显示坐标映射回原片包络
            var acc = 0.0
            var map: [(out: Double, src: Double, dur: Double)] = []
            var foldedPieces: [BKMark] = []
            for (s, e) in base {
                let len = max(0, e - s)
                map.append((out: acc, src: s, dur: len))
                // 段内按 ✂ 分割线（成品时间轴坐标）细分
                var c = acc
                let inner = splits.filter { $0 > acc + 0.05 && $0 < acc + len - 0.05 }.sorted()
                for sp in inner {
                    foldedPieces.append(BKMark(start: c, end: sp, kind: .keep))
                    foldedPieces.append(BKMark(start: sp, end: sp, kind: .keep))
                    c = sp
                }
                foldedPieces.append(BKMark(start: c, end: acc + len, kind: .keep))
                // 段间插零长度标记当分割线（redFolded 时画缝，保留「可单独编辑」的视觉）
                foldedPieces.append(BKMark(start: acc + len, end: acc + len, kind: .keep))
                acc += len
            }
            if foldedPieces.count > 1 { foldedPieces.removeLast() }
            trackView.setContent(envelope: envelope, pieces: foldedPieces, splits: [],
                                 duration: total, thresholdDb: thresholdDb,
                                 foldMap: map, redFolded: true)
            overviewBar.setContent(envelope: envelope, pieces: foldedPieces, duration: total,
                                   viewport: trackView.viewport)
        } else {
            let pieces = BKTimeline.pieces(duration: total, cuts: cuts, splits: splits)
            trackView.setContent(envelope: envelope, pieces: pieces, splits: splits,
                                 duration: total, thresholdDb: thresholdDb, redFolded: false)
            overviewBar.setContent(envelope: envelope, pieces: pieces, duration: total,
                                   viewport: trackView.viewport)
        }
    }

    private func updateInfo() {
        if let base = keepBase {
            let outDur = base.reduce(0.0) { $0 + max(0, $1.1 - $1.0) }
            infoLabel.text = String(format: "原 %@ · 剪后 %@ · 已折叠红区 · 保留 %d 段",
                                    formatClock(assetTotal), formatClock(outDur), base.count)
            return
        }
        let removed = cuts.reduce(0.0) { $0 + ($1.1 - $1.0) }
        let outDur = max(0, assetTotal - removed)
        if cuts.isEmpty {
            infoLabel.text = String(format: "原 %@ · 剪后 %@ · 还没有刀口",
                                    formatClock(assetTotal), formatClock(outDur))
        } else {
            let ratio = assetTotal > 0 ? removed / assetTotal : 0
            infoLabel.text = String(format: "原 %@ · 剪后 %@ · %d 刀 · 删 %.1fs（%.1f%%）",
                                    formatClock(assetTotal), formatClock(outDur),
                                    cuts.count, removed, ratio * 100)
        }
    }

    // MARK: - 撤销 / 重做

    private func pushUndo() {
        undoStack.append(EditState(cuts: cuts, splits: splits, keepBase: keepBase))
        if undoStack.count > BKConfig.Draft.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoButtons()
    }

    private func apply(_ s: EditState) {
        cuts = s.cuts
        splits = s.splits
        keepBase = s.keepBase
        if let base = keepBase {
            // 还原折叠态：total 重映射成折叠后时长，红区已不在
            total = base.reduce(0.0) { $0 + max(0, $1.1 - $1.0) }
            marks = []
        } else {
            // 还原未折叠态：回到原始时间轴
            total = assetTotal
            marks = BKTimeline.build(duration: assetTotal, cuts: cuts)
        }
        refreshTrack()
        updateInfo()
        schedulePersist()
    }

    @objc private func undoTapped() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(EditState(cuts: cuts, splits: splits))
        apply(prev)
        updateUndoButtons()
        statusLabel.text = "已撤销"
    }

    @objc private func redoTapped() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(EditState(cuts: cuts, splits: splits))
        apply(next)
        updateUndoButtons()
        statusLabel.text = "已重做"
    }

    /// 撤销 / 重做按钮的可用性。灰掉比点了没反应好 ——
    /// 点了没反应，用户会以为是 App 卡了
    private func updateUndoButtons() {
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
        undoButton.alpha = undoStack.isEmpty ? 0.35 : 1.0
        redoButton.alpha = redoStack.isEmpty ? 0.35 : 1.0
    }

    // MARK: - 编辑操作

    /// ✂ 把指针所在的地方切开。**切开 ≠ 删除**：切口不进 cuts，
    /// 导出时长纹丝不动。作用是把一段划成两段，好让你单独处理其中一半
    ///
    /// 【折叠态也能切】splits 一律存**显示时间轴**坐标：未折叠时显示轴≡源轴（同一套），
    /// 折叠后显示轴是成品时间轴。★ 退折叠时必须清空 splits（见 runDetection），
    /// 否则成品轴坐标会被当源轴用，切缝错位。
    @objc private func cutTapped() {
        let t = min(max(lastTime, 0), total)
        guard t > 0.05, t < total - 0.05 else {
            statusLabel.text = "指针太靠两头了，这里切不出东西"
            return
        }
        guard !splits.contains(where: { abs($0 - t) < 0.05 }) else {
            statusLabel.text = "这里已经有一道切口了"
            return
        }
        pushUndo()
        splits.append(t)
        splits.sort()
        statusLabel.text = String(format: "在 %.2fs 处加了一道分割线（仅显示）", t)
        refreshTrack()
    }

    /// ✗✗ = 折叠红区：把当前红区（删除区间）对应的视频段真正从主轨去掉，
    /// 只留绿区拼成新主轨。ck v2.0 的「删红折叠」同款语义。
    /// 不是「清空红区」—— 那等于什么都不删（旧实现的反向 bug）。
    @objc private func deleteRedTapped() {
        guard keepBase == nil else {
            statusLabel.text = "已经折叠过红区了，拖动阈值重检可还原"
            return
        }
        guard !cuts.isEmpty else {
            statusLabel.text = "当前没有红区可删"
            return
        }
        pushUndo()
        let keeps = BKDetector.keptSegments(cuts, totalSec: assetTotal)
        keepBase = keeps
        let folded = keeps.reduce(0.0) { $0 + max(0, $1.1 - $1.0) }
        total = folded
        marks = []
        splits = []
        refreshTrack()
        updateInfo()
        statusLabel.text = String(format: "已删除 %d 处红区，主轨仅剩保留段（%d 段 · 剪后 %.1fs）",
                                  cuts.count, keeps.count, folded)
        // 折叠后红区已并入主轨之外，删除区间无需再持有；
        // 刀数先记下来（首页「N 刀」徽标用，cuts 一清空就数不到了）
        redCount = cuts.count
        cuts = []
        everEdited = true
        schedulePersist()
    }

    /// 点段 toggle 绿↔红。命中用 `pieces`（含 ✂ 分割线），
    /// 这样「两道分割线之间的子段」能单独转红，而不是整段一起翻。
    /// 折叠态下主轨已无红区，点选无意义。
    private func togglePiece(at time: Double) {
        guard keepBase == nil else {
            statusLabel.text = "已折叠，拖动阈值重检后可再编辑"
            return
        }
        let ps = BKTimeline.pieces(duration: assetTotal, cuts: cuts, splits: splits)
        guard let idx = ps.firstIndex(where: { time >= $0.start - 1e-9 && time <= $0.end + 1e-9 })
        else {
            statusLabel.text = "指针这儿没有片段"
            return
        }
        let piece = ps[idx]
        pushUndo()
        let next = BKTimeline.toggle(marks: ps, at: idx)
        cuts = cutsFromMarks(next)
        marks = BKTimeline.build(duration: assetTotal, cuts: cuts)
        refreshTrack()
        updateInfo()
        if piece.kind == .cut {
            statusLabel.text = String(format: "恢复 %.2f~%.2fs", piece.start, piece.end)
        } else {
            statusLabel.text = String(format: "删掉 %.2f~%.2fs", piece.start, piece.end)
        }
        everEdited = true
        schedulePersist()
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

    // MARK: - ✕ 从视频列表清除本条（清完自动接下一条）

    /// ✕ = 把当前这条从**本批素材列表**里清掉（不动相册原片），然后自动跳到下一条继续剪。
    ///
    /// 场景（皓哥 2026-10-08）：挑进来一条发现整条都是废口播 —— 没必要剪、也没必要导，
    /// 就别让它占着列表。清掉之后直接接着剪下一条，流程不中断。
    @objc private func removeTapped() {
        let name = BKVideoLibrary.assetName(localID: localID)
        let alert = UIAlertController(
            title: "将当前视频从视频列表清除吗？",
            message: "「\(name)」会从本批素材里移除（相册里的原片不受影响），并自动接着剪下一条。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "确定", style: .destructive) { [weak self] _ in
            self?.removeCurrentItem()
        })
        present(alert, animated: true)
    }

    /// 移除当前条 → 整批落盘 → 跳到下一条的波剪页继续剪
    private func removeCurrentItem() {
        guard let bid = batchID else { return }
        stopPlayback()
        guard var batch = BKDraftStore.shared.batch(id: bid),
              batch.items.indices.contains(itemIndex) else { return }

        let removed = batch.items.remove(at: itemIndex)
        BKLog.shared.i("从本批移除素材 \(removed.assetName)")

        // 批里一条都不剩 → 整批也删掉，别在首页留个 0 条的空批
        if batch.items.isEmpty {
            BKDraftStore.shared.delete(batch)
            navigationController?.popToRootViewController(animated: true)
            return
        }
        BKDraftStore.shared.save(batch)

        // 跳到下一条：删掉之后原本的下一条会落到同一个 index；删的是最后一条就退到前一条。
        // 重排 nav 栈为 [首页, 新编辑器]，避免 首页→编辑器→编辑器 无限堆叠
        guard let nav = navigationController, let root = nav.viewControllers.first else { return }
        let nextIndex = min(itemIndex, batch.items.count - 1)
        let editor = BKEditorViewController(batchID: bid, index: nextIndex)
        nav.setViewControllers([root, editor], animated: true)
    }

    // MARK: - 阈值

    @objc private func thresholdChanged() {
        let v = Double(thresholdSlider.value)
        thresholdDb = v
        thresholdTitle.text = String(format: "阈值 %.1f dB", v)
        updateThresholdAutoButton()
        // 滑杆是连续动作，停下 0.4 秒才真正重算 —— 手感优先
        sliderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runDetection(override: v, recordUndo: true)
        }
        sliderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 「恢复自动」：当前就是自动值时置灰，手动拖过就亮，按一下回到 Otsu 的值并重算
    @objc private func thresholdAutoTapped() {
        guard let auto = autoThresholdDb else {
            statusLabel.text = "还没有自动值，先等首次检测完成"
            return
        }
        thresholdSlider.value = Float(auto)
        thresholdTitle.text = String(format: "阈值 %.1f dB", auto)
        thresholdDb = auto
        runDetection(override: auto, recordUndo: true)
        statusLabel.text = String(format: "已回到自动值 %.1f dB", auto)
    }

    /// 💉 按当前阈值重算气口
    @objc private func detectTapped() {
        runDetection(override: Double(thresholdSlider.value), recordUndo: true)
    }

    /// 阈值是不是还停在自动算出来的那个值上
    private func updateThresholdAutoButton() {
        guard let auto = autoThresholdDb else {
            thresholdAutoButton.isEnabled = false
            thresholdAutoButton.alpha = 0.30
            return
        }
        let isAuto = abs(thresholdDb - auto) < 0.01
        thresholdAutoButton.isEnabled = !isAuto
        thresholdAutoButton.alpha = isAuto ? 0.30 : 1.0
    }

    // MARK: - 播放

    /// ▶ 原片播：从指针处起播，红区绿区都播
    @objc private func playTapped() {
        if playMode == .straight { stopPlayback(); return }
        stopPlayback()
        guard originalItem != nil else { return }
        // 折叠态：显示时间 → 原片时间，从指针处起播
        let src = sourceTime(of: lastTime)
        player.seek(to: CMTime(seconds: src, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        playMode = .straight
        updatePlayIcons()
    }

    /// `|▶|` 联播：按保留段临时拼一条来播，等于预演成品
    @objc private func jointTapped() {
        if playMode == .joint { stopPlayback(); return }
        stopPlayback()
        guard let a = asset, total > 0 else { return }

        let keeps = keepBase ?? BKDetector.keptSegments(cuts, totalSec: assetTotal)
        guard let built = BKCompositionBuilder.make(asset: a, keeps: keeps) else {
            statusLabel.text = "没有可保留的片段，先少删一点"
            return
        }
        // 指针在绿区就从指针处播，指针在红区就跳下一个绿区
        guard let startSrc = startKeptTime(for: sourceTime(of: lastTime), keeps: keeps) else {
            statusLabel.text = "指针后面没有可播的片段了"
            return
        }
        let startOut = outputTime(of: built, at: startSrc)

        let item = AVPlayerItem(asset: built.comp)
        // 接缝淡入淡出挂在 item 上才生效（导出侧由 BKExporter 自己处理）
        item.audioMix = BKCompositionBuilder.makeFadeMix(built)
        jointBuild = built
        player.replaceCurrentItem(with: item)
        player.seek(to: CMTime(seconds: startOut, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        // 指针跟着挪到对应位置，跳转是瞬间的。
        // 未折叠：主轨画原片轴，指针落原片时间 startSrc；
        // 已折叠：主轨就是成品轴，指针落成品时间 startOut
        syncPlayhead(to: (keepBase != nil) ? startOut : startSrc)

        player.play()
        playMode = .joint
        updatePlayIcons()
    }

    /// 指针在某个保留段里 → 从指针处起播；在红区 → 跳下一个保留段的开头
    private func startKeptTime(for t: Double, keeps: [(Double, Double)]) -> Double? {
        for k in keeps where t >= k.0 - 1e-9 && t <= k.1 + 1e-9 { return t }
        for k in keeps where k.0 >= t - 1e-9 { return k.0 }
        return nil
    }

    /// 原片时间 → 成品时间（BKCompositionBuilder 只给了反向的 sourceTime，这里就地反查）
    private func outputTime(of build: BKCompositionBuild, at src: Double) -> Double {
        for seg in build.table {
            let srcEnd = seg.src + seg.dur * seg.speed
            if src >= seg.src - 1e-9 && src <= srcEnd + 1e-9 {
                return seg.out + (src - seg.src) / seg.speed
            }
        }
        return build.table.first?.out ?? 0
    }

    /// 停止。**指针停原地** —— 旧版「停止 = 暂停 + 回 0 秒」已作废
    private func stopPlayback() {
        player.pause()
        if playMode == .joint {
            // 画面切回原片，并把播放位置挪回指针 —— 这样退出联播之后画面接得上
            if let it = originalItem { player.replaceCurrentItem(with: it) }
            jointBuild = nil
        }
        playMode = .idle
        if total > 0 {
            // ★ lastTime 是**显示时间**，而这里 player 已经切回原片 item（源时间轴）。
            //   折叠态两者不是一回事，不换算会把画面 seek 到错误的源位置。
            //   未折叠时 sourceTime 恒等，所以这一改对普通情况零影响
            let src = sourceTime(of: lastTime)
            player.seek(to: CMTime(seconds: src, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updatePlayIcons()
    }

    // MARK: - 缩放

    /// ± 每次走 2 屏。1 屏一档太慢，从 6 屏拉到 20 屏要按 14 下
    @objc private func zoomInTapped() { zoomStep(by: 2) }

    @objc private func zoomOutTapped() { zoomStep(by: -2) }

    private func zoomStep(by delta: CGFloat) {
        trackView.setZoomScreens(trackView.zoomScreens + delta)
        overviewBar.setViewport(trackView.viewport)
    }

    // MARK: - 导出 / 返回

    /// 导出：统一走「本批清单 + 导出选项 + 开始导出」那一页，并**自动勾选当前这条**。
    /// 不再单独弹导出面板 —— 那会造成「批量导出选不了规格、单条反而能选」两套行为打架
    @objc private func exportTapped() {
        guard let bid = batchID, assetTotal > 0 else {
            statusLabel.text = "素材未就绪，无法导出"
            return
        }
        stopPlayback()
        // 先落盘：合并页是从草稿里读刀口的，不落的话刚改的刀口可能还没写进去
        persistItem()
        let page = BKBatchListViewController(batchID: bid, preselect: itemIndex)
        navigationController?.pushViewController(page, animated: true)
    }

    @objc private func closeTapped() {
        stopPlayback()
        navigationController?.popViewController(animated: true)
    }

    // MARK: - 草稿持久化

    /// 当前所属批（磁盘上的最新状态）
    private var currentBatch: BKBatch? {
        guard let bid = batchID else { return nil }
        return BKDraftStore.shared.batch(id: bid)
    }

    /// 轨道拖拽换素材（bk剪辑早期那套「拖过头切上/下一条」）：
    /// 停播 → 手上这条先存回草稿 → 清撤销栈（跨素材撤销没意义）→ 载入新的一条
    private func switchToItem(_ newIndex: Int) {
        guard let b = currentBatch, b.items.indices.contains(newIndex) else { return }
        stopPlayback()
        persistItem()
        undoStack.removeAll()
        redoStack.removeAll()
        itemIndex = newIndex
        localID = b.items[newIndex].localID
        loadMaterial()
        BKLog.shared.i("轨道拖拽：切到第 \(newIndex + 1)/\(b.items.count) 条")
    }

    /// 把当前编辑态写回所属草稿批（整批 JSON 落盘）
    private func persistItem() {
        guard let bid = batchID else { return }
        guard var batch = BKDraftStore.shared.batch(id: bid),
              batch.items.indices.contains(itemIndex) else { return }
        batch.items[itemIndex].cuts = self.cuts.ranges
        batch.items[itemIndex].keepBase = self.keepBase?.ranges
        batch.items[itemIndex].thresholdDb = self.thresholdDb
        batch.items[itemIndex].autoThresholdDb = self.autoThresholdDb
        batch.items[itemIndex].everEdited = self.everEdited
        // 只有折叠态才记刀数（未折叠时刀数 = cuts.count 现场可数）
        batch.items[itemIndex].redCount = (self.keepBase != nil) ? self.redCount : nil
        BKDraftStore.shared.save(batch)
    }

    /// debounce 落盘：编辑过程中最多每 1s 写一次，退页面时再强制写一次
    private func schedulePersist() {
        persistWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.persistItem() }
        persistWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    /// ☰ 打开本批素材清单
    @objc private func listTapped() {
        guard let bid = batchID else { return }
        let list = BKBatchListViewController(batchID: bid)
        navigationController?.pushViewController(list, animated: true)
    }

    /// 拖动/点选时把原片 player seek 到该源时间（暂停态下只更新画面）
    private func seekOriginal(to t: Double) {
        guard player.currentItem != nil else { return }
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 状态机统一入口：提波形期间把整个工具栏灰掉，
    /// 免得在半成品状态上再叠一层编辑
    private func setControlsEnabled(_ enabled: Bool) {
        let buttons = [undoButton, redoButton, jointButton, playButton, deleteRedButton,
                       cutButton, detectButton, zoomOutButton, zoomInButton]
        for b in buttons {
            b.isEnabled = enabled
            b.alpha = enabled ? 1.0 : 0.4
        }
        thresholdSlider.isEnabled = enabled
        // 撤销 / 重做 / 恢复自动 三个按钮的可用性各有各的判据，不能一刀切全亮
        if enabled {
            updateUndoButtons()
            updateThresholdAutoButton()
        }
    }

    // MARK: - 工具

    // MARK: - 折叠态时间映射

    /// 显示时间（折叠后成品时间轴）→ 原片时间。未折叠时恒等。
    /// 播放 / 手动 seek 都要拿它去定位原片 player。
    private func sourceTime(of displayT: Double) -> Double {
        guard let base = keepBase, !base.isEmpty else { return displayT }
        var acc = 0.0
        for (s, e) in base {
            let len = max(0, e - s)
            if displayT <= acc + len + 1e-9 { return s + max(0, displayT - acc) }
            acc += len
        }
        return base.last?.1 ?? 0
    }

    /// 原片时间 → 显示时间（折叠后成品时间轴）。未折叠时恒等。
    /// 播放回调里 AVPlayer 报的是原片时间，要反查回显示轴才对得上指针。
    private func displayTime(of srcT: Double) -> Double {
        guard let base = keepBase, !base.isEmpty else { return srcT }
        var acc = 0.0
        for (s, e) in base {
            let len = max(0, e - s)
            // ★ 源时间落在**被删掉的红区里**（还没到下一段起点）→ 停在上一段末尾（接缝处）。
            //   没有这一条的话，红区内的源时间会一路走到函数末尾 return acc（= 所有保留段
            //   之和 = 结尾），指针在折叠态原片播经过红区时会瞬间跳到结尾、出了红区再跳回来。
            //   （▶ 原片播的语义就是红区绿区都播，所以指针停在缝上、画面继续往前走是对的）
            if srcT < s { return acc }
            if srcT >= s - 1e-9 && srcT <= e + 1e-9 {
                return acc + max(0, srcT - s)
            }
            acc += len
        }
        return acc
    }

    /// mm:ss。时间码用这个：小数点后一位在剪辑场景里是噪音
    private func formatClock(_ t: Double) -> String {
        let s = max(0, t)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - 主轨道回调

extension BKEditorViewController: BKTrackViewDelegate {

    func track(_ view: BKTrackView, didScrollTo time: Double) {
        let t = min(max(time, 0), total)
        // 手动找位置一律静音：播放中先停，再 seek（rate==0 的 seek 天然不出声）
        if playMode != .idle { stopPlayback() }
        seekOriginal(to: sourceTime(of: t))
        lastTime = t
        timeLabel.text = "\(formatClock(t)) / \(formatClock(total))"
        overviewBar.setViewport(view.viewport)
    }

    func track(_ view: BKTrackView, didTogglePieceAt time: Double) {
        togglePiece(at: time)
    }

    func track(_ view: BKTrackView, didChangeZoomTo screens: CGFloat) {
        overviewBar.setViewport(view.viewport)
    }

    /// 手指一碰轨道就停。播放中一拖就暂停，不存在松手续播
    func trackDidTouchDown(_ view: BKTrackView) {
        if playMode != .idle { stopPlayback() }
    }

    func trackDidPullBeyondHead(_ view: BKTrackView) {
        guard let b = currentBatch, b.items.count > 1, itemIndex > 0 else {
            statusLabel.text = "已经是第一条了"
            return
        }
        switchToItem(itemIndex - 1)
    }

    func trackDidPullBeyondTail(_ view: BKTrackView) {
        guard let b = currentBatch, b.items.count > 1, itemIndex < b.items.count - 1 else {
            statusLabel.text = "已经是最后一条了"
            return
        }
        switchToItem(itemIndex + 1)
    }

    // MARK: 拖红区边缘调气口大小

    /// 按下红区边缘开始拖。VC 收到就压一次撤销 —— 拖动过程每帧都回调，
    /// 不合并的话撤销栈会被一帧一帧塞满，撤一次只退一帧
    func track(_ view: BKTrackView, didBeginRedEdgeDragNear time: Double) {
        pushUndo()
    }

    func track(_ view: BKTrackView, didDragRedEdgeNear near: Double, to newTime: Double) {
        guard keepBase == nil else { return }
        guard let next = BKTimeline.moveRedEdge(cuts: cuts, near: near, to: newTime,
                                                duration: assetTotal) else { return }
        cuts = next
        marks = BKTimeline.build(duration: assetTotal, cuts: cuts)
        refreshTrack()
        updateInfo()
        everEdited = true
        schedulePersist()
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
        let t = min(max(time, 0), total)
        if playMode != .idle { stopPlayback() }
        trackView.setPointerTime(t)
        overviewBar.setViewport(trackView.viewport)
        seekOriginal(to: sourceTime(of: t))
        lastTime = t
        timeLabel.text = "\(formatClock(t)) / \(formatClock(total))"
    }
}
