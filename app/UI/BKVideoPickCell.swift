//
//  BKVideoPickCell.swift
//  bk波剪 — 勾选页视频格（照 bk剪辑 v1.2.7 原样移植）
//
//  【手势分工（bk剪辑定稿 6.1）】
//  · 点右上角小圆圈 → 勾选 / 取消（不触发预览）
//  · 点圆圈以外     → 半屏预览（底下列表还露着）
//  选中：圆圈填红 + 序号，整格红描边 —— bk剪辑里皓哥用熟的那套。
//

import UIKit

final class BKVideoPickCell: UICollectionViewCell {

    static let reuseID = "BKVideoPickCell"

    /// 点小圆圈：切换勾选
    var onToggle: (() -> Void)?
    /// 点圆圈以外：预览
    var onPreview: (() -> Void)?

    private let cover = UIImageView()
    private let shade = UIView()
    private let durLabel = UILabel()
    private let circle = UIButton(type: .system)
    private let numLabel = UILabel()
    /// iCloud 原件未下载时的占位图标：本机没缩略图就显示，绝不偷拉网络
    private let cloudBadge = UIImageView()
    private var pick = 0
    private var lastID = ""

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

        shade.backgroundColor = UIColor(hex: 0x000000, alpha: 0.45)
        contentView.addSubview(shade)

        durLabel.font = BKTheme.Font.monoSmall
        durLabel.textColor = .white
        durLabel.textAlignment = .right
        contentView.addSubview(durLabel)

        // 小圆圈本体。参考图是空心圈，选中后填红 + 序号
        circle.backgroundColor = UIColor(hex: 0x000000, alpha: 0.28)
        circle.layer.cornerRadius = 12
        circle.layer.borderWidth = 1.6
        circle.layer.borderColor = UIColor(hex: 0xFFFFFF, alpha: 0.9).cgColor
        circle.addTarget(self, action: #selector(circleTapped), for: .touchUpInside)
        contentView.addSubview(circle)

        numLabel.font = .systemFont(ofSize: 12, weight: .bold)
        numLabel.textColor = .white
        numLabel.textAlignment = .center
        numLabel.isUserInteractionEnabled = false
        contentView.addSubview(numLabel)

        cloudBadge.image = UIImage(systemName: "icloud")
        cloudBadge.tintColor = UIColor(hex: 0xAEAEB2)
        cloudBadge.contentMode = .center
        cloudBadge.isHidden = true
        contentView.addSubview(cloudBadge)

        for v in [cover, shade, durLabel, circle, numLabel, cloudBadge] {
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
            shade.heightAnchor.constraint(equalToConstant: 20),

            durLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            durLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            circle.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            circle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            circle.widthAnchor.constraint(equalToConstant: 24),
            circle.heightAnchor.constraint(equalToConstant: 24),

            numLabel.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            numLabel.centerYAnchor.constraint(equalTo: circle.centerYAnchor),

            cloudBadge.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            cloudBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            cloudBadge.widthAnchor.constraint(equalToConstant: 30),
            cloudBadge.heightAnchor.constraint(equalToConstant: 30)
        ])

        // 整格点击 = 预览。小圆圈盖在上面，它的点击优先（后加的子视图在上层）
        let tap = UITapGestureRecognizer(target: self, action: #selector(cellTapped))
        contentView.addGestureRecognizer(tap)
    }

    /// 装填。id 存一份：缩略图是异步的，回调要靠它比对，
    /// 否则会出现「A 的封面画到 B 上面」（cell 复用高频）
    func setID(_ id: String) {
        lastID = id
        durLabel.text = BKVideoLibrary.formatDuration(BKVideoLibrary.duration(localID: id))
        cover.image = nil
        cloudBadge.isHidden = true
        // 滚动时只取本机已缓存缩略图（networkAllowed:false），绝不偷拉 iCloud 原件流量；
        // 本机没有缩略图（云上未下载）就给云占位图标
        BKThumbnails.image(localID: id, size: CGSize(width: 200, height: 200), networkAllowed: false) { [weak self] img in
            guard let self = self, self.lastID == id else { return }
            if let img = img {
                self.cover.image = img
                self.cloudBadge.isHidden = true
            } else {
                self.cloudBadge.isHidden = false
            }
        }
        applyPick()
    }

    /// 勾选序号（1 起），0 = 未选
    func setPickIndex(_ idx: Int) {
        pick = idx
        applyPick()
    }

    private func applyPick() {
        if pick > 0 {
            circle.backgroundColor = BKTheme.Color.danger
            circle.layer.borderColor = BKTheme.Color.danger.cgColor
            numLabel.text = "\(pick)"
            numLabel.isHidden = false
            contentView.layer.borderWidth = 2
            contentView.layer.borderColor = BKTheme.Color.danger.cgColor
        } else {
            circle.backgroundColor = UIColor(hex: 0x000000, alpha: 0.28)
            circle.layer.borderColor = UIColor(hex: 0xFFFFFF, alpha: 0.9).cgColor
            numLabel.text = nil
            numLabel.isHidden = true
            contentView.layer.borderWidth = 0
        }
    }

    @objc private func circleTapped() {
        onToggle?()
    }

    @objc private func cellTapped() {
        onPreview?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.image = nil
        cloudBadge.isHidden = true
        onToggle = nil
        onPreview = nil
        lastID = ""
    }
}
