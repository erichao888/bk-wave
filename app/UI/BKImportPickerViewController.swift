//
//  BKImportPickerViewController.swift
//  bk波剪 — 导入时多选相册视频
//
//  【为什么自建勾选页，不走系统 PHPicker】
//  系统选择器没有「点格当场播 / 点圆圈勾选」这套手势，挑素材时看不到片段对不对。
//  这里复用首页的 BKVideoPickCell 做格子：
//    · 点格子   → 选中（描蓝边）+ 立刻进 BKVideoPreviewViewController 全屏播放
//    · 预览页右上角的圆圈 → 当场勾选 / 取消，不用退回网格再找
//    · 右上「导入(N)」回传选中的 localID 列表（按相册顺序）
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
        // 选中态自己维护：点格子 = 选中 + 当场进全屏预览播放。
        // 交给系统多选的话，再点一次已选的格子会触发 didDeselect（把选中取消掉），
        // 而皓哥要的是「点了就播」，取消勾选统一放到预览页右上角的圆圈里
        collectionView.allowsMultipleSelection = false
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从预览页回来（可能在那里取消了勾选），重画蓝框与计数
        refreshBorders()
        updateDone()
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

    /// 点格子 = 选中（蓝框）+ **当场进全屏预览播放**。
    /// 取消选中的入口放在预览页右上角的圆圈里（与 ck v1.2.7 勾选页同一套手势）：
    /// 挑素材时先听一耳朵看一眼，不对就在预览页里直接取消，不用退回网格再找
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < localIDs.count else { return }
        let id = localIDs[indexPath.item]
        selected.insert(id)
        refreshBorders()
        updateDone()
        openPreview(localID: id)
    }

    /// 全屏预览：进来直接播，右上角圆圈可当场勾选 / 取消
    private func openPreview(localID: String) {
        let preview = BKVideoPreviewViewController(localID: localID,
                                                   isPicked: selected.contains(localID))
        preview.modalPresentationStyle = .fullScreen
        preview.onTogglePick = { [weak self, weak preview] id in
            guard let self = self else { return }
            let on = preview?.isPicked ?? false
            if on { self.selected.insert(id) } else { self.selected.remove(id) }
            self.updateDone()
            self.refreshBorders()
        }
        present(preview, animated: true)
    }

    /// 按当前选中集合重画所有可见格的蓝框
    private func refreshBorders() {
        for ip in collectionView.indexPathsForVisibleItems where ip.item < localIDs.count {
            guard let cell = collectionView.cellForItem(at: ip) else { continue }
            let on = selected.contains(localIDs[ip.item])
            cell.contentView.layer.borderWidth = on ? 3 : 0
            cell.contentView.layer.borderColor = BKTheme.Color.accent.cgColor
        }
    }
}
