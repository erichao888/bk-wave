//
//  BKBatchListViewController.swift
//  bk波剪 — 导出页（本批素材清单 + 导出选项 + 开始导出）
//
//  【为什么要合并（皓哥 2026-10-08 拍板）】
//  以前「☰ 列表」和「导出面板」是两个入口，而且批量导出**根本选不了规格**（写死同源），
//  单条反而能选 —— 两套行为对不上，导出面板很尴尬。合并成一屏：
//    上部 = 本批素材清单（点行进编辑 / 圆圈勾选 / 红名=删过红区 / 原时长→剪后时长）
//    中部 = 导出选项（分辨率 / 帧率，整批统一）+ 已选条数与合计时长
//    底部 = 蓝色「开始导出 N 条」（未选时**仍为蓝色**，点了弹「未选择视频，无法导出」）
//
//  【两个入口怎么进来】
//  · ☰            → 本批清单，默认不勾选
//  · 波剪页「导出」→ 同一页，但**自动勾选当前这一条**（preselect）
//
//  【导出】逐条排队调用 BKExporter.export（Part 化），单条失败继续，末弹汇总。
//  进度沿用 HUD 弹窗（第几条 + 总% + 本条%）。
//

import UIKit
import AVFoundation

final class BKBatchListViewController: UIViewController {

    private let batchID: UUID
    private var batch: BKBatch?
    private var selected = Set<Int>()

    // MARK: - 界面

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let optionsCard = UIView()
    private let resSeg = UISegmentedControl(items: BKConfig.Resolution.allCases.map { $0.rawValue })
    private let fpsSeg = UISegmentedControl(items: BKConfig.FrameRate.allCases.map { $0.rawValue })
    private let summaryLabel = UILabel()
    private let exportButton = UIButton(type: .system)
    private let selectAllButton = UIBarButtonItem(title: "全选", style: .plain, target: nil, action: nil)

    /// - Parameters:
    ///   - preselect: 进来就勾上的序号（波剪页「导出」传当前条）
    ///   - selectAll: 进来就全勾（首页草稿格「···」→ 导出 用）
    init(batchID: UUID, preselect: Int? = nil, selectAll: Bool = false) {
        self.batchID = batchID
        super.init(nibName: nil, bundle: nil)
        if let p = preselect { selected.insert(p) }
        if selectAll { selected = Set(0 ..< 64) }   // 上限放宽，reload 时会按实际条数裁掉
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        title = "导出"
        setupUI()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    // MARK: - 布局

    private func setupUI() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "返回", style: .plain,
                                                           target: self, action: #selector(backTapped))
        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllTapped)
        navigationItem.rightBarButtonItem = selectAllButton

        // ---- 上部：素材清单 ----
        tableView.backgroundColor = BKTheme.Color.page
        tableView.separatorColor = BKTheme.Color.line
        tableView.register(BatchRowCell.self, forCellReuseIdentifier: BatchRowCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self

        // ---- 中部：导出选项 ----
        optionsCard.backgroundColor = BKTheme.Color.panel
        optionsCard.layer.cornerRadius = BKTheme.Radius.card
        optionsCard.layer.borderWidth = 1
        optionsCard.layer.borderColor = BKTheme.Color.line.cgColor

        let resTitle = sectionTitle("分辨率")
        let fpsTitle = sectionTitle("帧率")

        resSeg.selectedSegmentIndex = 0
        styleSeg(resSeg)
        resSeg.addTarget(self, action: #selector(specChanged), for: .valueChanged)

        fpsSeg.selectedSegmentIndex = 0
        styleSeg(fpsSeg)
        fpsSeg.addTarget(self, action: #selector(specChanged), for: .valueChanged)

        summaryLabel.font = BKTheme.Font.caption
        summaryLabel.textColor = BKTheme.Color.text2
        summaryLabel.numberOfLines = 2

        let optStack = UIStackView(arrangedSubviews: [resTitle, resSeg, fpsTitle, fpsSeg, summaryLabel])
        optStack.axis = .vertical
        optStack.spacing = 6
        optStack.alignment = .fill
        optionsCard.addSubview(optStack)

        // ---- 底部：主行动按钮（常蓝，未选时点了才提示）----
        exportButton.setTitle("开始导出", for: .normal)
        exportButton.titleLabel?.font = BKTheme.Font.button
        exportButton.setTitleColor(.white, for: .normal)
        exportButton.backgroundColor = BKTheme.Color.accent
        exportButton.layer.cornerRadius = 22
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)

        for v in [tableView, optionsCard, exportButton, optStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(tableView)
        view.addSubview(optionsCard)
        view.addSubview(exportButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: optionsCard.topAnchor, constant: -8),

            optionsCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.lg),
            optionsCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.lg),
            optionsCard.heightAnchor.constraint(equalToConstant: 190),
            optionsCard.bottomAnchor.constraint(equalTo: exportButton.topAnchor, constant: -BKTheme.Space.md),

            optStack.topAnchor.constraint(equalTo: optionsCard.topAnchor, constant: 12),
            optStack.leadingAnchor.constraint(equalTo: optionsCard.leadingAnchor, constant: 12),
            optStack.trailingAnchor.constraint(equalTo: optionsCard.trailingAnchor, constant: -12),

            exportButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.lg),
            exportButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.lg),
            exportButton.heightAnchor.constraint(equalToConstant: 48),
            exportButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                 constant: -BKTheme.Space.md)
        ])
    }

    private func sectionTitle(_ t: String) -> UILabel {
        let l = UILabel()
        l.text = t
        l.font = BKTheme.Font.caption
        l.textColor = BKTheme.Color.text2
        return l
    }

    private func styleSeg(_ seg: UISegmentedControl) {
        seg.backgroundColor = BKTheme.Color.panel2
        seg.setTitleTextAttributes([.foregroundColor: BKTheme.Color.text], for: .normal)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
    }

    // MARK: - 数据

    private func reload() {
        batch = BKDraftStore.shared.batch(id: batchID)
        // 选中的序号若超出当前条数（理论上不会），清掉多余的。
        // ⚠️ Set.filter 返回的是 Array，必须再包一层 Set(...) 才赋得回来
        if let b = batch {
            selected = Set(selected.filter { $0 < b.items.count })
        } else {
            selected.removeAll()
        }
        tableView.reloadData()
        updateSummary()
    }

    /// 当前选中的导出规格（整批统一）
    private func currentSpec() -> BKConfig.ExportSpec {
        let r = BKConfig.Resolution.allCases[resSeg.selectedSegmentIndex]
        let f = BKConfig.FrameRate.allCases[fpsSeg.selectedSegmentIndex]
        return BKConfig.ExportSpec(resolution: r, frameRate: f)
    }

    /// 已选素材的成品时长合计（没删过红的按原时长算）
    private func totalSeconds(_ indices: [Int]) -> Double {
        guard let b = batch else { return 0 }
        var sum = 0.0
        for i in indices where b.items.indices.contains(i) {
            let it = b.items[i]
            sum += it.trimmedDuration ?? (it.duration ?? BKVideoLibrary.duration(localID: it.localID))
        }
        return sum
    }

    private func updateSummary() {
        let n = selected.count
        exportButton.setTitle(n > 0 ? "开始导出 \(n) 条" : "开始导出", for: .normal)
        let total = totalSeconds(Array(selected))
        summaryLabel.text = "已选 \(n) 条 · 合计 \(BatchRowCell.clock(total))\n规格：\(currentSpec().summary)"
    }

    // MARK: - 动作

    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func specChanged() {
        updateSummary()
    }

    @objc private func selectAllTapped() {
        guard let b = batch else { return }
        if selected.count == b.items.count {
            selected.removeAll()
        } else {
            selected = Set(0 ..< b.items.count)
        }
        tableView.reloadData()
        updateSummary()
    }

    @objc private func exportTapped() {
        guard let b = batch else { return }
        guard !selected.isEmpty else {
            // 按钮保持蓝色不置灰（皓哥定），未选时点了给明确提示
            let a = UIAlertController(title: nil, message: "未选择视频，无法导出", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "好", style: .cancel))
            present(a, animated: true)
            return
        }
        let items = selected.sorted().compactMap { b.items.indices.contains($0) ? b.items[$0] : nil }
        runExport(items: items)
    }

    /// 导航到某条编辑页：把 nav 栈重排成 [首页, 编辑器]，避免 首页→编辑器→列表→编辑器 无限堆叠
    private func openItem(_ index: Int) {
        guard let nav = navigationController, let root = nav.viewControllers.first else { return }
        let editor = BKEditorViewController(batchID: batchID, index: index)
        nav.setViewControllers([root, editor], animated: true)
    }

    private func toggle(_ index: Int) {
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
        tableView.reloadRows(at: [IndexPath(item: index, section: 0)], with: .none)
        updateSummary()
    }

    // MARK: - 批量导出（逐条排队，单条失败继续，末弹汇总）

    private func runExport(items: [BKClipItem]) {
        let hud = UIAlertController(title: "正在导出", message: "准备中…", preferredStyle: .alert)
        present(hud, animated: true)
        // ★ 用页面上选的规格（整批统一），不再写死同源
        let spec = currentSpec()
        var ok = 0
        var failed: [String] = []

        // 进度文案：第几条 + 总进度% + 本条%。
        // 只报「第 i/N」用户根本不知道要等多久（BKExporter 注释里那条铁律），百分比才是人能感知的
        func message(_ i: Int, _ name: String, _ frac: Double) -> String {
            let f = min(max(frac, 0), 1)
            let overall = (Double(i) + f) / Double(items.count)
            let line1 = "正在导出 \(i + 1)/\(items.count) · 总 \(Int(overall * 100))%"
            return line1 + "\n" + name + "\n本条 \(Int(f * 100))%"
        }

        func step(_ i: Int) {
            if i >= items.count {
                hud.dismiss(animated: true) {
                    let title = failed.isEmpty ? "导出完成" : "部分完成"
                    let msg = failed.isEmpty
                        ? "\(ok) 条已存入相册"
                        : "\(ok) 条成功，\(failed.count) 条失败：\n" + failed.joined(separator: "\n")
                    let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "好", style: .cancel))
                    self.present(a, animated: true)
                }
                return
            }
            let item = items[i]
            hud.message = message(i, item.assetName, 0)
            BKVideoLibrary.loadAVAsset(localID: item.localID) { asset in
                guard let asset = asset else {
                    failed.append(item.assetName + "（读取失败）")
                    step(i + 1)
                    return
                }
                let dur = CMTimeGetSeconds(asset.duration)
                let keeps = item.keepBase?.tuples
                    ?? BKDetector.keptSegments(item.cuts.tuples, totalSec: dur)
                guard !keeps.isEmpty else {
                    failed.append(item.assetName + "（无保留段）")
                    step(i + 1)
                    return
                }
                let part = BKCompositionBuilder.Part(asset: asset, name: item.assetName,
                                                     keeps: keeps, speed: 1.0)
                BKExporter.export(title: item.assetName, sources: [part], spec: spec,
                                 progress: { _, _, frac in
                                     // BKExporter 的 progress 已切回主线程，直接刷文案
                                     hud.message = message(i, item.assetName, frac)
                                 },
                                 completion: { result in
                    switch result {
                    case .success(let url):
                        BKExporter.saveToPhotos(url: url, fileName: url.lastPathComponent) { okSave in
                            if okSave {
                                ok += 1
                                BKConfig.incrementExportCount()   // 首页版本行「已导出 N 条」
                            } else {
                                failed.append(item.assetName)
                            }
                            step(i + 1)
                        }
                    case .failure:
                        failed.append(item.assetName)
                        step(i + 1)
                    }
                })
            }
        }
        step(0)
    }
}

// MARK: - 表格

extension BKBatchListViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        batch?.items.count ?? 0
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 60 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: BatchRowCell.reuseID,
                                                 for: indexPath) as! BatchRowCell
        if let item = batch?.items[indexPath.item] {
            // 老草稿（v1.1.2 之前存的）没有 duration 字段，现场向相册补一次
            let raw = item.duration ?? BKVideoLibrary.duration(localID: item.localID)
            cell.configure(name: item.assetName,
                           edited: item.hasDeletedRed,
                           selected: selected.contains(indexPath.item),
                           rawDuration: raw,
                           trimmed: item.trimmedDuration)
            cell.onToggle = { [weak self] in self?.toggle(indexPath.item) }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        openItem(indexPath.item)
    }
}

// MARK: - 行 cell

final class BatchRowCell: UITableViewCell {

    static let reuseID = "BatchRowCell"

    private let nameLabel = UILabel()
    private let subLabel = UILabel()
    private let checkButton = UIButton(type: .system)

    var onToggle: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BKTheme.Color.panel
        contentView.backgroundColor = BKTheme.Color.panel
        selectionStyle = .none

        nameLabel.font = BKTheme.Font.body
        nameLabel.textColor = BKTheme.Color.text
        contentView.addSubview(nameLabel)

        // 第二行：原时长 → 删红后时长；没删过红就标「无删红」
        subLabel.font = BKTheme.Font.monoSmall
        subLabel.textColor = BKTheme.Color.text3
        contentView.addSubview(subLabel)

        checkButton.setImage(UIImage(systemName: "circle"), for: .normal)
        checkButton.tintColor = BKTheme.Color.text2
        checkButton.addTarget(self, action: #selector(checkTapped), for: .touchUpInside)
        contentView.addSubview(checkButton)

        for v in [nameLabel, subLabel, checkButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            checkButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            checkButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            checkButton.widthAnchor.constraint(equalToConstant: 28),
            checkButton.heightAnchor.constraint(equalToConstant: 28),

            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkButton.leadingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),

            subLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkButton.leadingAnchor, constant: -12),
            subLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3)
        ])
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    func configure(name: String, edited: Bool, selected: Bool,
                   rawDuration: Double, trimmed: Double?) {
        nameLabel.text = name
        // 删过红区标红，没动过的默认色
        nameLabel.textColor = edited ? BKTheme.Color.danger : BKTheme.Color.text
        if let t = trimmed {
            subLabel.text = "原 \(Self.clock(rawDuration)) → 剪后 \(Self.clock(t))"
            subLabel.textColor = BKTheme.Color.success
        } else {
            // 没进行过删红操作：只显示原时长，标注「无删红」
            subLabel.text = "原 \(Self.clock(rawDuration)) · 无删红"
            subLabel.textColor = BKTheme.Color.text3
        }
        let img = selected ? "checkmark.circle.fill" : "circle"
        checkButton.setImage(UIImage(systemName: img), for: .normal)
        checkButton.tintColor = selected ? BKTheme.Color.accent : BKTheme.Color.text2
    }

    /// mm:ss。列表与合计时长共用这一个口径，别出现「1:23」和「01:23」两种写法
    static func clock(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60)
    }

    @objc private func checkTapped() {
        onToggle?()
    }
}
