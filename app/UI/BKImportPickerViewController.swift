//
//  BKImportPickerViewController.swift
//  bk波剪 — 导入勾选页（照 bk剪辑 v1.2.7 勾选页原样移植）
//
//  【为什么自建，不用系统 PHPicker】
//  系统 PHPicker 的选择态是「整格高亮 + 对勾」，没有「点圈选 / 点圈外预览」这套手势。
//  皓哥要的是挑素材时能当场看片段对不对，所以照 bk剪辑勾选页搭一个。
//
//  【手势分工】
//  · 点格子右上角小圆圈 → 勾选 / 取消（红底 + 序号，整格红描边）
//  · 点圆圈以外         → 70% 半屏预览（底下列表还露着，可上拖全屏）
//  · 右上角红色角标     → 已选条数，点它切「只看已选」
//  · 底部蓝色按钮       → 「添加 N 条」回传（按点选顺序，先点的在前）
//
//  【预览必须显式设音频会话】默认 soloAmbient 服从静音键，挑素材听不清就白挑了。
//

import UIKit
import Photos
import AVFoundation

final class BKImportPickerViewController: UIViewController {

    /// 完成回传：选中的 localID（按点选顺序）
    var onDone: (([String]) -> Void)?

    // MARK: - 数据

    private var allIDs: [String] = []
    /// 已选，保持点选顺序（先点的在前）
    private var picked: [String] = []
    private var pickedSet: Set<String> = []
    private var onlyPicked = false

    // MARK: - 界面

    private let grid: UICollectionView
    private let countButton = UIButton(type: .system)
    private let footer = UIView()
    private let doneButton = UIButton(type: .system)

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 10, left: 10, bottom: 90, right: 10)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        title = "选视频"
        setupUI()
        setupAudio()
        loadLibrary()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 预览页可能还在播，走的时候收掉
        BKVideoLibrary.stopPreview()
    }

    /// App 内播视频必须显式设音频会话，否则静音键一按整条无声
    private func setupAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            BKLog.shared.w("勾选页音频会话设置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 布局

    private func setupUI() {
        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(BKVideoPickCell.self, forCellWithReuseIdentifier: BKVideoPickCell.reuseID)
        view.addSubview(grid)

        // 右上角：已选条数角标（红底白字），点它切「只看已选」
        countButton.titleLabel?.font = BKTheme.Font.button
        countButton.setTitleColor(.white, for: .normal)
        countButton.backgroundColor = BKTheme.Color.danger
        countButton.layer.cornerRadius = 15
        countButton.addTarget(self, action: #selector(filterTapped), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: countButton)

        // 左上角返回：dismiss 整个 modal（外层包了 UINavigationController，一起收掉）
        let back = UIBarButtonItem(image: UIImage(systemName: "chevron.left"),
                                   style: .plain, target: self, action: #selector(closeTapped))
        back.tintColor = BKTheme.Color.text
        navigationItem.leftBarButtonItem = back

        // 底部：确认条
        footer.backgroundColor = BKTheme.Color.bar
        view.addSubview(footer)

        doneButton.setTitle("添加", for: .normal)
        doneButton.titleLabel?.font = BKTheme.Font.button
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.backgroundColor = BKTheme.Color.accent
        doneButton.layer.cornerRadius = 22
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.isEnabled = false
        doneButton.alpha = 0.4
        footer.addSubview(doneButton)

        for v in [grid, footer, countButton, doneButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 88),

            doneButton.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            doneButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 12),
            doneButton.widthAnchor.constraint(equalToConstant: 160),
            doneButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        updateCount()
    }

    // MARK: - 素材库

    private func loadLibrary() {
        // 双保险：首页已拉过授权，这里再查一次。
        // iOS 16+ 用现代 authorizationStatus(for: .readWrite)，老式无参回调在 iOS 26 不触发
        let status: PHAuthorizationStatus = {
            if #available(iOS 16.0, *) { return PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            return PHPhotoLibrary.authorizationStatus()
        }()
        guard status == .authorized || status == .limited else {
            requestAccessThenLoad()
            return
        }
        allIDs = BKVideoLibrary.videoLocalIDs()
        grid.reloadData()
        if allIDs.isEmpty { showEmpty() }
    }

    /// 没权限时自己再拉一次授权（双保险，防根页的拉授权在某些系统上没生效）
    private func requestAccessThenLoad() {
        let decide: (PHAuthorizationStatus) -> Void = { [weak self] s in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if s == .authorized || s == .limited {
                    self.loadLibrary()
                } else {
                    self.showDenied()
                }
            }
        }
        if #available(iOS 16.0, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { decide($0) }
        } else {
            PHPhotoLibrary.requestAuthorization { decide($0) }
        }
    }

    private func showDenied() {
        let label = UILabel()
        label.text = "没有相册权限\n去「设置 › 隐私 › 相册」打开"
        label.font = BKTheme.Font.body
        label.textColor = BKTheme.Color.text2
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func showEmpty() {
        let label = UILabel()
        label.text = "相册里没有视频"
        label.font = BKTheme.Font.body
        label.textColor = BKTheme.Color.text3
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    /// 当前要显示的列表。onlyPicked 时只留已选
    private var visibleIDs: [String] {
        onlyPicked ? allIDs.filter { pickedSet.contains($0) } : allIDs
    }

    /// 勾选序号（1 起）。没选中返回 0
    private func pickIndex(of id: String) -> Int {
        guard let i = picked.firstIndex(of: id) else { return 0 }
        return i + 1
    }

    private func updateCount() {
        let n = picked.count
        countButton.setTitle(" \(n) ", for: .normal)
        countButton.isHidden = n == 0
        doneButton.isEnabled = n > 0
        doneButton.alpha = n > 0 ? 1.0 : 0.4
        doneButton.setTitle(n > 0 ? "添加 \(n) 条" : "添加", for: .normal)
    }

    // MARK: - 动作

    @objc private func filterTapped() {
        onlyPicked.toggle()
        grid.reloadData()
    }

    @objc private func doneTapped() {
        guard !picked.isEmpty else { return }
        // ★ 必须先 dismiss 整个勾选页、再回调 —— 否则 modal 一直盖在首页上，
        //   Root 往被遮住的那个导航栈 push 波剪页，用户看着就是「点了添加没反应」。
        //   （v1.1.1 漏了这步：onDone 里既没 dismiss 也没等动画结束）
        let ids = picked
        dismiss(animated: true) { [weak self] in
            self?.onDone?(ids)
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    /// 勾选切换。名字带 Pick 后缀是为了不和 Bool 的内建 toggle() 撞车
    private func togglePick(_ id: String) {
        if pickedSet.contains(id) {
            pickedSet.remove(id)
            if let i = picked.firstIndex(of: id) { picked.remove(at: i) }
        } else {
            pickedSet.insert(id)
            picked.append(id)
        }
        updateCount()
        // 只重载这一格，别整屏闪（几百条视频整屏 reload 会明显卡）
        let rows = visibleIDs.enumerated()
            .filter { $0.element == id }
            .map { IndexPath(item: $0.offset, section: 0) }
        if rows.isEmpty {
            // 「只看已选」里取消了某条 → 列表少一格，条数变了必须整表刷
            grid.reloadData()
        } else {
            grid.reloadItems(at: rows)
        }
    }

    private func preview(_ id: String) {
        BKVideoLibrary.stopPreview()
        let vc = BKVideoPreviewViewController(localID: id, isPicked: pickedSet.contains(id))
        // 【70% 半屏卡】底下勾选页还露着 —— 挑这条的时候还能看到列表和别的素材，
        // 不用退出去再进来。半屏卡可以往上拖成全屏（iOS 原生手势）。
        // ⚠️ Detent.custom 是 iOS 16.0+ API，部署目标 15.0，必须 #available 包一层。
        vc.modalPresentationStyle = .pageSheet
        if let sheet = vc.sheetPresentationController {
            if #available(iOS 16.0, *) {
                let id = UISheetPresentationController.Detent.Identifier("bkPreview70")
                let seventy = UISheetPresentationController.Detent.custom(identifier: id) { ctx in
                    ctx.maximumDetentValue * 0.7
                }
                sheet.detents = [seventy, .large()]
                sheet.selectedDetentIdentifier = id
            } else {
                // iOS 15 只有 medium / large 两档，用 medium 顶一下
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = .medium
            }
            sheet.prefersGrabberVisible = true
        }
        // 预览页里点右上角小圆圈 = 选中/取消这条，直接同步回列表
        vc.onTogglePick = { [weak self] toggledID in
            self?.togglePick(toggledID)
        }
        vc.onClose = { [weak self] in
            self?.dismiss(animated: true)
        }
        present(vc, animated: true)
    }
}

// MARK: - 网格

extension BKImportPickerViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleIDs.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BKVideoPickCell.reuseID, for: indexPath) as! BKVideoPickCell
        let id = visibleIDs[indexPath.item]
        cell.setID(id)
        cell.setPickIndex(pickIndex(of: id))
        cell.onToggle = { [weak self] in self?.togglePick(id) }
        cell.onPreview = { [weak self] in self?.preview(id) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // cell 自己的手势管点圆圈/点圈外，这里只在空白处兜底当预览
        preview(visibleIDs[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        // 三列正方形，间距跟着 sectionInset 走
        let spacing: CGFloat = 6
        let insets: CGFloat = 10
        let columns: CGFloat = 3
        let w = floor((collectionView.bounds.width - insets * 2 - spacing * (columns - 1)) / columns)
        return CGSize(width: max(0, w), height: max(0, w))
    }
}
