//
//  BKVideoPickCell.swift
//  bk波剪 — 首页相册视频格子
//
//  纯展示：封面（BKThumbnails 异步取）+ 时长 + 素材名。点按由 UICollectionViewController 处理。
//

import UIKit

final class BKVideoPickCell: UICollectionViewCell {

    static let reuseID = "BKVideoPickCell"

    private let cover = UIImageView()
    private let durationLabel = UILabel()
    private let nameLabel = UILabel()
    private let playBadge = UIImageView()

    private var localID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("本 App 不走 storyboard") }

    private func setup() {
        contentView.backgroundColor = BKTheme.Color.track
        contentView.layer.cornerRadius = 8
        contentView.clipsToBounds = true

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cover)

        playBadge.image = UIImage(systemName: "play.fill")
        playBadge.tintColor = UIColor(hex: 0xFFFFFF, alpha: 0.85)
        playBadge.contentMode = .center
        playBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playBadge)

        durationLabel.font = BKTheme.Font.monoSmall
        durationLabel.textColor = .white
        durationLabel.textAlignment = .right
        durationLabel.backgroundColor = UIColor(hex: 0x000000, alpha: 0.35)
        durationLabel.layer.cornerRadius = 4
        durationLabel.clipsToBounds = true
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)

        nameLabel.font = BKTheme.Font.small
        nameLabel.textColor = UIColor(hex: 0xEAF0F7, alpha: 0.9)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.backgroundColor = UIColor(hex: 0x000000, alpha: 0.3)
        nameLabel.layer.cornerRadius = 4
        nameLabel.clipsToBounds = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            playBadge.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playBadge.widthAnchor.constraint(equalToConstant: 26),
            playBadge.heightAnchor.constraint(equalToConstant: 26),

            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            durationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            durationLabel.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -6),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            nameLabel.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    /// 配置格子。复用时会重新取图，回调里核对 id 防止错位。
    func configure(localID: String) {
        self.localID = localID
        cover.image = nil
        durationLabel.text = BKVideoLibrary.formatDuration(BKVideoLibrary.duration(localID: localID))
        nameLabel.text = " " + BKVideoLibrary.assetName(localID: localID)

        let size = CGSize(width: bounds.width > 0 ? bounds.width : 180,
                          height: bounds.height > 0 ? bounds.height : 240)
        BKThumbnails.image(localID: localID, size: size, networkAllowed: false) { [weak self] img in
            guard self?.localID == localID else { return }
            self?.cover.image = img
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        localID = nil
        cover.image = nil
        durationLabel.text = nil
        nameLabel.text = nil
    }
}
