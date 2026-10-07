//
//  BKRootViewController.swift
//  bk波剪 — 起始草稿页（照 bk剪辑 v2.0.0 草稿页）
//
//  【布局对照 bk剪辑截图】
//  · 导航栏：左上🗑（回收站）｜标题「草稿 (N)」｜右上 ✓（多选开关）
//  · 3 列**竖版**封面格；每格左上蓝徽标「N 刀 / N 刀 M 条」、右上「···」菜单、底部批标题
//  · 多选态：格子右上换成勾选圈，底部工具条「删除 / 全选」
//  · 右下角蓝色 FAB ⊕（导入）；底部版本行「bk波剪 … · 已导出 N 条」，连点 7 次进日志面板
//
//  【★ 为什么不是 UICollectionViewController】（2026-10-08 踩坑）
//  原来把网格当 self.view、FAB 和版本行塞进 collectionView.backgroundView ——
//  **backgroundView 在 cell 下面**，格子一多就把蓝色加号盖住、点击也吃不到。
//  改成 UIViewController + 自带 grid 子视图（和 bk剪辑一样）：
//  悬浮件直接 addSubview 到 view，永远在网格之上、不随内容滚动。
//
//  【★ 安全区】FAB 与版本行一律约束到 safeAreaLayoutGuide ——
//  早先贴 view.bottom 排版，正好压在 iPhone 底部横线（home indicator）上。
//
//  【一格 = 一批】一批 = 一次导入的多条视频，各自编辑态存在 BKClipItem 里。
//  删除走**回收站**（deletedAt 打标记，30 天内可恢复），不是真删。
//

import UIKit
import Photos

final class BKRootViewController: UIViewController {

    private var batches: [BKBatch] = []
    private var picking = false
    private var selected = Set<Int>()

    private let grid: UICollectionView
    private let emptyLabel = UILabel()
    private let versionLabel = UILabel()
    private let fab = UIButton(type: .system)

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 10, left: 10, bottom: 110, right: 10)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page

        grid.backgroundColor = BKTheme.Color.page
        grid.dataSource = self
        grid.delegate = self
        grid.alwaysBounceVertical = true
        grid.register(BKBatchCell.self, forCellWithReuseIdentifier: BKBatchCell.reuseID)
        view.addSubview(grid)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "trash"), style: .plain,
            target: self, action: #selector(trashTapped))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "回收站"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark.circle"), style: .plain,
            target: self, action: #selector(pickTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "多选"

        emptyLabel.text = "还没有草稿\n点右下角 ⊕ 导入视频"
        emptyLabel.font = BKTheme.Font.body
        emptyLabel.textColor = BKTheme.Color.text2
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        view.addSubview(emptyLabel)

        // ---- 右下角 FAB ⊕ ----（在网格之上，避开底部安全区）
        fab.setImage(UIImage(systemName: "plus"), for: .normal)
        fab.tintColor = .white
        fab.backgroundColor = BKTheme.Color.accent
        fab.layer.cornerRadius = 28
        fab.layer.shadowColor = UIColor.black.cgColor
        fab.layer.shadowOpacity = 0.25
        fab.layer.shadowOffset = CGSize(width: 0, height: 3)
        fab.layer.shadowRadius = 6
        fab.accessibilityLabel = "导入视频"
        fab.addTarget(self, action: #selector(fabTapped), for: .touchUpInside)
        view.addSubview(fab)

        // ---- 底部版本行 ----（连点 7 次进运行日志面板）
        versionLabel.font = BKTheme.Font.small
        versionLabel.textColor = BKTheme.Color.text3
        versionLabel.textAlignment = .center
        versionLabel.isUserInteractionEnabled = true
        versionLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(versionTapped))
        )
        view.addSubview(versionLabel)

        for v in [grid, emptyLabel, fab, versionLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            fab.widthAnchor.constraint(equalToConstant: 56),
            fab.heightAnchor.constraint(equalToConstant: 56),
            fab.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            fab.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),

            versionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            versionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                                constant: -4)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(!picking, animated: false)
        reload()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if let layout = grid.collectionViewLayout as? UICollectionViewFlowLayout {
            let inset = layout.sectionInset
            let gap = layout.minimumInteritemSpacing
            let cols: CGFloat = 3
            let w = (grid.bounds.width - inset.left - inset.right - gap * (cols - 1)) / cols
            // 竖版封面（≈9:16 略收），照 bk剪辑草稿格的比例
            layout.itemSize = CGSize(width: max(0, w), height: max(0, w * 1.45))
        }
    }

    // MARK: - 刷新

    private func reload() {
        batches = BKDraftStore.shared.allBatches()
        selected = selected.filter { $0 < batches.count }
        title = "草稿 (\(batches.count))"
        emptyLabel.isHidden = !batches.isEmpty
        versionLabel.text = String(format: "bk波剪 专剪口播 v%@ · 已导出 %d 条",
                                   BKConfig.appVersion, BKConfig.exportCount)
        navigationItem.rightBarButtonItem?.isEnabled = !batches.isEmpty
        grid.reloadData()
    }

    // MARK: - 导入

    @objc private func fabTapped() {
        ensurePermission { [weak self] in
            self?.presentPicker()
        }
    }

    private func presentPicker() {
        let picker = BKImportPickerViewController()
        picker.onDone = { [weak self] ids in
            self?.handleImported(ids: ids)
        }
        let nav = UINavigationController(rootViewController: picker)
        present(nav, animated: true)
    }

    private func handleImported(ids: [String]) {
        guard !ids.isEmpty else { return }
        let batch = BKDraftStore.shared.makeBatch(localIDs: ids)
        BKDraftStore.shared.save(batch)
        reload()
        let editor = BKEditorViewController(batchID: batch.id, index: 0)
        navigationController?.pushViewController(editor, animated: true)
    }

    private func ensurePermission(then: @escaping () -> Void) {
        let status: PHAuthorizationStatus
        if #available(iOS 16, *) {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus()
        }
        switch status {
        case .authorized, .limited:
            then()
        case .notDetermined:
            // 现代 API（iOS16+），老式无参回调在 iOS 26 上不触发
            if #available(iOS 16, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                    DispatchQueue.main.async { self?.reload(); then() }
                }
            } else {
                PHPhotoLibrary.requestAuthorization { [weak self] _ in
                    DispatchQueue.main.async { self?.reload(); then() }
                }
            }
        default:
            let alert = UIAlertController(
                title: "需要相册权限",
                message: "bk波剪需要读取相册来导入视频。请在「设置 → 隐私与安全 → 照片」中允许访问。",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
            present(alert, animated: true)
        }
    }

    // MARK: - 回收站 / 多选 / 日志

    @objc private func trashTapped() {
        navigationController?.pushViewController(BKTrashViewController(), animated: true)
    }

    @objc private func versionTapped() {
        BKDebug.tapVersionTag(self)
    }

    @objc private func pickTapped() {
        picking.toggle()
        grid.allowsMultipleSelection = picking
        if !picking { selected.removeAll() }
        grid.reloadData()
        navigationController?.setToolbarHidden(!picking, animated: false)
        navigationItem.rightBarButtonItem?.image =
            UIImage(systemName: picking ? "xmark.circle" : "checkmark.circle")
        updateTrashBar()
    }

    private func updateTrashBar() {
        guard picking else { return }
        let del = UIBarButtonItem(title: selected.isEmpty ? "删除" : "删除 (\(selected.count))",
                                  style: .plain, target: self, action: #selector(deleteSelectedTapped))
        del.tintColor = BKTheme.Color.danger
        let all = UIBarButtonItem(title: "全选", style: .plain, target: self,
                                  action: #selector(selectAllTapped))
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbarItems = [del, spacer, all]
    }

    @objc private func deleteSelectedTapped() {
        guard !selected.isEmpty else { return }
        let n = selected.count
        for i in selected where i < batches.count {
            BKDraftStore.shared.moveToTrash(batches[i])
        }
        selected.removeAll()
        pickTapped()
        reload()
        showAlert(title: "已移到回收站",
                  message: "\(n) 批已移入回收站，\(BKConfig.Draft.trashKeepDays) 天内可在左上角回收站里恢复。")
    }

    @objc private func selectAllTapped() {
        if selected.count == batches.count {
            selected.removeAll()
        } else {
            selected = Set(0 ..< batches.count)
        }
        grid.reloadData()
        updateTrashBar()
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - 格子「···」菜单：重命名 / 删除 / 导出

    private func showMenu(for batch: BKBatch) {
        let sheet = UIAlertController(title: batch.displayTitle, message: nil,
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
            self?.promptRename(batch)
        })
        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            BKDraftStore.shared.moveToTrash(batch)
            self.reload()
            self.showAlert(title: "已移到回收站",
                           message: "\(BKConfig.Draft.trashKeepDays) 天内可在左上角回收站里恢复。")
        })
        sheet.addAction(UIAlertAction(title: "导出", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let page = BKBatchListViewController(batchID: batch.id, selectAll: true)
            self.navigationController?.pushViewController(page, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private func promptRename(_ batch: BKBatch) {
        let alert = UIAlertController(title: "重命名", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = batch.displayTitle
            tf.placeholder = "给这一批起个名字"
        }
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            guard let self = self else { return }
            var b = batch
            b.title = alert.textFields?.first?.text ?? ""
            BKDraftStore.shared.save(b)
            self.reload()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - 网格

extension BKRootViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        batches.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BKBatchCell.reuseID,
                                                      for: indexPath) as! BKBatchCell
        let batch = batches[indexPath.item]
        cell.configure(batch: batch, picking: picking, selected: selected.contains(indexPath.item))
        cell.onMenu = { [weak self] in self?.showMenu(for: batch) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let batch = batches[indexPath.item]
        if picking {
            // 多选态：点格 = 勾选/取消
            if selected.contains(indexPath.item) {
                selected.remove(indexPath.item)
            } else {
                selected.insert(indexPath.item)
            }
            collectionView.reloadItems(at: [indexPath])
            updateTrashBar()
            return
        }
        guard batch.items.indices.contains(0) else { return }
        let editor = BKEditorViewController(batchID: batch.id, index: 0)
        navigationController?.pushViewController(editor, animated: true)
    }
}

// MARK: - 草稿格

final class BKBatchCell: UICollectionViewCell {

    static let reuseID = "BKBatchCell"

    /// 「···」菜单
    var onMenu: (() -> Void)?

    private let cover = UIImageView()
    private let shade = UIView()
    private let nameLabel = UILabel()
    private let badge = UILabel()
    private let menuButton = UIButton(type: .system)
    private let checkButton = UIButton(type: .system)
    private var localID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    private func setup() {
        contentView.backgroundColor = BKTheme.Color.track
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 8

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        contentView.addSubview(cover)

        // 底部压暗 + 批标题
        shade.backgroundColor = UIColor(hex: 0x000000, alpha: 0.45)
        contentView.addSubview(shade)

        nameLabel.font = BKTheme.Font.small
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingMiddle
        contentView.addSubview(nameLabel)

        // 左上蓝徽标：「N 刀」/「N 刀 M 条」
        badge.font = BKTheme.Font.small
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = BKTheme.Color.accent
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        contentView.addSubview(badge)

        // 右上「···」
        menuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        menuButton.tintColor = .white
        menuButton.backgroundColor = UIColor(hex: 0x000000, alpha: 0.45)
        menuButton.layer.cornerRadius = 14
        menuButton.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)
        contentView.addSubview(menuButton)

        // 多选态的勾选圈（平时隐藏）
        checkButton.layer.cornerRadius = 14
        checkButton.layer.borderWidth = 1.6
        contentView.addSubview(checkButton)

        for v in [cover, shade, nameLabel, badge, menuButton, checkButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            shade.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            shade.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            shade.heightAnchor.constraint(equalToConstant: 22),

            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            badge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            badge.heightAnchor.constraint(equalToConstant: 17),

            menuButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            menuButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            menuButton.widthAnchor.constraint(equalToConstant: 28),
            menuButton.heightAnchor.constraint(equalToConstant: 28),

            checkButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            checkButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            checkButton.widthAnchor.constraint(equalToConstant: 28),
            checkButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    func configure(batch: BKBatch, picking: Bool, selected: Bool) {
        nameLabel.text = batch.displayTitle

        // 徽标：刀数 + 条数（多条才带「N 条」，照 bk剪辑「0 刀 2 条」写法）
        let cuts = batch.totalCuts
        if batch.items.count > 1 {
            badge.text = " \(cuts) 刀 \(batch.items.count) 条 "
        } else {
            badge.text = " \(cuts) 刀 "
        }

        menuButton.isHidden = picking
        checkButton.isHidden = !picking
        if picking {
            checkButton.backgroundColor = selected ? BKTheme.Color.accent
                : UIColor(hex: 0x000000, alpha: 0.28)
            checkButton.layer.borderColor = (selected ? BKTheme.Color.accent
                : UIColor(hex: 0xFFFFFF, alpha: 0.9)).cgColor
            checkButton.setImage(selected ? UIImage(systemName: "checkmark") : nil, for: .normal)
            checkButton.tintColor = .white
            contentView.layer.borderWidth = selected ? 2 : 0
            contentView.layer.borderColor = BKTheme.Color.accent.cgColor
        } else {
            contentView.layer.borderWidth = 0
        }

        // 封面：批里第一条素材
        if let first = batch.items.first {
            localID = first.localID
            cover.image = nil
            let size = CGSize(width: bounds.width > 0 ? bounds.width : 120,
                              height: bounds.height > 0 ? bounds.height : 175)
            BKThumbnails.image(localID: first.localID, size: size, networkAllowed: false) { [weak self] img in
                guard self?.localID == first.localID else { return }
                self?.cover.image = img
            }
        }
    }

    @objc private func menuTapped() {
        onMenu?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.image = nil
        localID = nil
        onMenu = nil
    }
}