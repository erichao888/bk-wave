//
//  BKRootViewController.swift
//  bk波剪 — 首页（选视频）
//
//  范围：选一条视频 → 进波剪页。不做多选取 / 草稿箱 / 回收站。
//  点格子直接 push BKEditorViewController(localID:)。
//

import UIKit
import Photos

final class BKRootViewController: UICollectionViewController {

    private var localIDs: [String] = []
    private let emptyLabel = UILabel()
    private var hasAskedPermission = false

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 8
        layout.minimumIntersectingItemSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        super.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "bk波剪"
        view.backgroundColor = BKTheme.Color.bg
        collectionView.backgroundColor = BKTheme.Color.bg
        collectionView.register(BKVideoPickCell.self, forCellWithReuseIdentifier: BKVideoPickCell.reuseID)
        collectionView.alwaysBounceVertical = true

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self, action: #selector(refreshTapped))

        emptyLabel.text = "正在读取相册…"
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
        ensurePermission { [weak self] in
            self?.reloadVideos()
        }
    }

    // MARK: - 相册权限

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
            hasAskedPermission = true
            if #available(iOS 16, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                    DispatchQueue.main.async { self?.reloadVideos() }
                }
            } else {
                PHPhotoLibrary.requestAuthorization { [weak self] _ in
                    DispatchQueue.main.async { self?.reloadVideos() }
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

    // MARK: - 数据

    private func reloadVideos() {
        let status: PHAuthorizationStatus
        if #available(iOS 16, *) {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus()
        }
        guard status == .authorized || status == .limited else {
            localIDs = []
            collectionView.reloadData()
            emptyLabel.isHidden = false
            emptyLabel.text = "没有相册访问权限\n去「设置 → 照片」允许后点右上角刷新"
            return
        }

        localIDs = BKVideoLibrary.videoLocalIDs()
        emptyLabel.isHidden = !localIDs.isEmpty
        if localIDs.isEmpty {
            emptyLabel.text = "相册里没有视频\n录一条口播视频，再来这里剪气口"
        }
        collectionView.reloadData()
    }

    @objc private func refreshTapped() {
        reloadVideos()
    }

    // MARK: - 布局

    private func itemSize() -> CGSize {
        let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
        let inset = layout?.sectionInset ?? .zero
        let gap = layout?.minimumIntersectingItemSpacing ?? 8
        let cols: CGFloat = 3
        let w = (collectionView.bounds.width - inset.left - inset.right - gap * (cols - 1)) / cols
        let h = w * 4 / 3   // 9:16 偏竖，给点余量用 4:3 占位框
        return CGSize(width: max(0, w), height: max(0, h))
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.itemSize = itemSize()
        }
    }

    // MARK: - 集合视图

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        localIDs.count
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BKVideoPickCell.reuseID, for: indexPath)
        if let pick = cell as? BKVideoPickCell {
            pick.configure(localID: localIDs[indexPath.item])
        }
        return cell
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let localID = localIDs[indexPath.item]
        let editor = BKEditorViewController(localID: localID)
        navigationController?.pushViewController(editor, animated: true)
    }
}
