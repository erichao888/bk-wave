//
//  BKImportPickerViewController.swift
//  bk波剪 — 导入时多选相册视频
//
//  【为什么自建勾选页，不走系统 PHPicker】
//  系统选择器没有「点格即选、再点取消」这套手势，挑素材时看不到片段对不对。
//  这里复用首页的 BKVideoPickCell 做格子，开启 allowsMultipleSelection，
//  选中格描蓝边，右上「导入(N)」回传选中的 localID 列表。
//

import UIKit
import Photos

final class BKImportPickerViewController: UICollectionViewController {

    /// 完成回调：回传选中的 localID（按相册顺序）
    var onDone: (([String]) -> Void)?

    private var localIDs: [String] = []
    private var selected: Set<String> = []
    private let doneButton = UIBarButtonItem()
    private let cancelButton = UIBarButtonItem()

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        super.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.bg
        title = "选择视频"
        collectionView.backgroundColor = BKTheme.Color.bg
        collectionView.register(BKVideoPickCell.self, forCellWithReuseIdentifier: BKVideoPickCell.reuseID)
        collectionView.allowsMultipleSelection = true
        collectionView.alwaysBounceVertical = true

        cancelButton.title = "取消"
        cancelButton.style = .plain
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        navigationItem.leftBarButtonItem = cancelButton

        doneButton.title = "导入"
        doneButton.style = .done
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        doneButton.isEnabled = false
        navigationItem.rightBarButtonItem = doneButton

        reloadVideos()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            let inset = layout.sectionInset
            let gap = layout.minimumInteritemSpacing
            let cols: CGFloat = 3
            let w = (collectionView.bounds.width - inset.left - inset.right - gap * (cols - 1)) / cols
            layout.itemSize = CGSize(width: max(0, w), height: max(0, w * 4 / 3))
        }
    }

    private func reloadVideos() {
        localIDs = BKVideoLibrary.videoLocalIDs()
        collectionView.reloadData()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        guard !selected.isEmpty else { return }
        let ids = localIDs.filter { selected.contains($0) }
        dismiss(animated: true) { [weak self] in
            self?.onDone?(ids)
        }
    }

    private func updateDone() {
        doneButton.title = selected.isEmpty ? "导入" : "导入 \(selected.count)"
        doneButton.isEnabled = !selected.isEmpty
    }

    // MARK: - 集合视图

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        localIDs.count
    }

    override func collectionView(_ collectionView: UICollectionView,
                                 cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BKVideoPickCell.reuseID,
                                                      for: indexPath)
        if let pick = cell as? BKVideoPickCell {
            pick.configure(localID: localIDs[indexPath.item])
        }
        let on = selected.contains(localIDs[indexPath.item])
        cell.contentView.layer.borderWidth = on ? 3 : 0
        cell.contentView.layer.borderColor = BKTheme.Color.accent.cgColor
        return cell
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let id = localIDs[indexPath.item]
        selected.insert(id)
        if let cell = collectionView.cellForItem(at: indexPath) {
            cell.contentView.layer.borderWidth = 3
            cell.contentView.layer.borderColor = BKTheme.Color.accent.cgColor
        }
        updateDone()
    }

    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        let id = localIDs[indexPath.item]
        selected.remove(id)
        if let cell = collectionView.cellForItem(at: indexPath) {
            cell.contentView.layer.borderWidth = 0
        }
        updateDone()
    }
}
