//
//  BKRootViewController.swift
//  bk波剪 — 首页（草稿 / 批列表）
//
//  【一格 = 一批（一次导入的多条视频）】
//  点格进该批第一条的波剪页；右上「+」多选相册视频建批。
//  编辑态持久化在 BKDraftStore，所以关掉 App 再打开，草稿还在。
//
//  【不做回收站 / 多选取删】单功能工具，删单批的需求还没提，先不堆。
//

import UIKit
import Photos

final class BKRootViewController: UICollectionViewController {

    private var batches: [BKBatch] = []
    private let emptyLabel = UILabel()
    private let addButton = UIBarButtonItem()

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 90, right: 12)
        super.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "bk波剪"
        view.backgroundColor = BKTheme.Color.bg
        collectionView.backgroundColor = BKTheme.Color.bg
        collectionView.register(BKBatchCell.self, forCellWithReuseIdentifier: BKBatchCell.reuseID)
        collectionView.alwaysBounceVertical = true

        addButton.image = UIImage(systemName: "plus")
        addButton.style = .plain
        addButton.target = self
        addButton.action = #selector(addTapped)
        navigationItem.rightBarButtonItem = addButton

        emptyLabel.text = "还没有草稿\n点右上角 + 导入视频"
        emptyLabel.font = BKTheme.Font.body
        emptyLabel.textColor = BKTheme.Color.text2
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let inset = layout.sectionInset
            let gap = layout.minimumInteritemSpacing
            let cols: CGFloat = 2
            let w = (collectionView.bounds.width - inset.left - inset.right - gap * (cols - 1)) / cols
            layout.itemSize = CGSize(width: max(0, w), height: max(0, w * 1.25))
        }
    }

    // MARK: - 数据

    private func reload() {
        batches = BKDraftStore.shared.allBatches()
        // ⚠️ 不能把 collectionView 整个隐藏：UICollectionViewController 的 view 就是
        //    collectionView，连 emptyLabel 是它的子视图 —— 一隐藏连空态文案都没了
        emptyLabel.isHidden = !batches.isEmpty
        collectionView.reloadData()
    }

    // MARK: - 导入

    @objc private func addTapped() {
        ensurePermission { [weak self] in
            self?.presentPicker()
        }
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
            showPermissionAlert()
        }
    }

    private func showPermissionAlert() {
        let alert = UIAlertController(
            title: "需要相册权限",
            message: "bk波剪需要读取相册来导入视频。请在「设置 → 隐私与安全 → 照片」中允许访问。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
        present(alert, animated: true)
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

    // MARK: - 集合视图

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        batches.count
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BKBatchCell.reuseID,
                                                      for: indexPath) as! BKBatchCell
        cell.configure(batch: batches[indexPath.item])
        return cell
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let batch = batches[indexPath.item]
        guard batch.items.indices.contains(0) else { return }
        let editor = BKEditorViewController(batchID: batch.id, index: 0)
        navigationController?.pushViewController(editor, animated: true)
    }
}

// MARK: - 批 cell

final class BKBatchCell: UICollectionViewCell {

    static let reuseID = "BKBatchCell"

    private let cover = UIImageView()
    private let titleLabel = UILabel()
    private let subLabel = UILabel()
    private var localID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = BKTheme.Color.panel
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cover)

        titleLabel.font = BKTheme.Font.body
        titleLabel.textColor = BKTheme.Color.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        subLabel.font = BKTheme.Font.small
        subLabel.textColor = BKTheme.Color.text2
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subLabel)

        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cover.heightAnchor.constraint(equalTo: contentView.heightAnchor, multiplier: 0.62),

            titleLabel.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),

            subLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            subLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    func configure(batch: BKBatch) {
        titleLabel.text = batch.displayTitle
        let edited = batch.items.filter { $0.hasDeletedRed }.count
        subLabel.text = "\(batch.items.count) 条 · 已剪 \(edited)"
        if let first = batch.items.first {
            localID = first.localID
            cover.image = nil
            let size = CGSize(width: bounds.width > 0 ? bounds.width : 180,
                              height: bounds.height > 0 ? bounds.height * 0.62 : 110)
            BKThumbnails.image(localID: first.localID, size: size, networkAllowed: false) { [weak self] img in
                guard self?.localID == first.localID else { return }
                self?.cover.image = img
            }
        }
    }
}
