//
//  BKBatchListViewController.swift
//  bk波剪 — 波剪页 ☰ 进来的「本批素材清单」
//
//  【两个用途】
//  ① 点某条 → 进该条的波剪页（替换 nav 栈为 [首页, 编辑器]，不无限堆叠）
//  ② 勾选多条 → 底部「导出选中(N)」逐个导出并存入相册
//
//  【文件名配色】删过红区（用户动过刀 / 已折叠）标红（BKTheme.Color.danger），
//  没动过的用默认文字色 —— 一眼看出哪几条已经剪过。
//

import UIKit
import AVFoundation
import Photos

final class BKBatchListViewController: UIViewController {

    private let batchID: UUID
    private var batch: BKBatch?
    private var selected = Set<Int>()

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let exportButton = UIBarButtonItem()
    private let selectAllButton = UIBarButtonItem(title: "全选", style: .plain, target: nil, action: nil)

    init(batchID: UUID) {
        self.batchID = batchID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        title = "本批素材"
        setupUI()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        navigationController?.setToolbarHidden(true, animated: false)
        super.viewWillDisappear(animated)
    }

    // MARK: - 布局

    private func setupUI() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "返回", style: .plain,
                                                           target: self, action: #selector(backTapped))
        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllTapped)
        navigationItem.rightBarButtonItem = selectAllButton

        exportButton.title = "导出选中"
        exportButton.target = self
        exportButton.action = #selector(exportSelectedTapped)
        exportButton.tintColor = BKTheme.Color.accent
        exportButton.isEnabled = false
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        setToolbarItems([spacer, exportButton, spacer], animated: false)
        navigationController?.setToolbarHidden(false, animated: false)

        tableView.backgroundColor = BKTheme.Color.page
        tableView.separatorColor = BKTheme.Color.line
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 56, right: 0)
        tableView.register(BatchRowCell.self, forCellReuseIdentifier: BatchRowCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

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
        updateExportButton()
    }

    // MARK: - 动作

    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func selectAllTapped() {
        guard let b = batch else { return }
        if selected.count == b.items.count {
            selected.removeAll()
        } else {
            selected = Set(0 ..< b.items.count)
        }
        tableView.reloadData()
        updateExportButton()
    }

    private func updateExportButton() {
        let n = selected.count
        exportButton.title = n == 0 ? "导出选中" : "导出选中 \(n)"
        exportButton.isEnabled = n > 0
    }

    /// 导航到某条编辑页：把 nav 栈重排成 [首页, 编辑器]，避免 首页→编辑器→列表→编辑器 无限堆叠
    private func openItem(_ index: Int) {
        guard let nav = navigationController, let root = nav.viewControllers.first else { return }
        let editor = BKEditorViewController(batchID: batchID, index: index)
        nav.setViewControllers([root, editor], animated: true)
    }

    @objc private func exportSelectedTapped() {
        guard let b = batch, !selected.isEmpty else { return }
        let items = selected.sorted().compactMap { b.items.indices.contains($0) ? b.items[$0] : nil }
        runExport(items: items)
    }

    private func toggle(_ index: Int) {
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
        tableView.reloadRows(at: [IndexPath(item: index, section: 0)], with: .none)
        updateExportButton()
    }

    // MARK: - 批量导出（逐条排队，单条失败继续，末弹汇总）

    private func runExport(items: [BKClipItem]) {
        let hud = UIAlertController(title: "正在导出", message: "准备中…", preferredStyle: .alert)
        present(hud, animated: true)
        let spec = BKConfig.ExportSpec()
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
                            if okSave { ok += 1 } else { failed.append(item.assetName) }
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

    /// mm:ss。列表里一律用这个口径，别出现「1:23」和「01:23」两种写法
    private static func clock(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60)
    }

    @objc private func checkTapped() {
        onToggle?()
    }
}
