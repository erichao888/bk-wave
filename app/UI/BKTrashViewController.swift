//
//  BKTrashViewController.swift
//  bk波剪 — 回收站（首页左上🗑）
//
//  删除草稿不是真删：BKBatch 打上 deletedAt 标记，30 天内可恢复。
//  过期（deletedAt 超过 BKConfig.Draft.trashKeepDays）的进页面时自动清掉。
//

import UIKit

final class BKTrashViewController: UITableViewController {

    private var rows: [BKBatch] = []
    private let emptyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "回收站"
        view.backgroundColor = BKTheme.Color.page
        tableView.backgroundColor = BKTheme.Color.page
        tableView.separatorColor = BKTheme.Color.lineSoft
        tableView.rowHeight = 56

        emptyLabel.text = "回收站是空的"
        emptyLabel.font = BKTheme.Font.body
        emptyLabel.textColor = BKTheme.Color.text3
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 进回收站先清一遍过期批次（30 天保留期）
        BKDraftStore.shared.purgeExpiredTrash()
        reload()
    }

    private func reload() {
        rows = BKDraftStore.shared.trashBatches()
        emptyLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "trash")
        let b = rows[indexPath.item]
        cell.backgroundColor = BKTheme.Color.panel
        cell.textLabel?.text = b.displayTitle
        cell.textLabel?.textColor = BKTheme.Color.text
        cell.textLabel?.numberOfLines = 1
        cell.detailTextLabel?.text = "\(b.items.count) 条 · \(Self.dateText(b.deletedAt))"
        cell.detailTextLabel?.textColor = BKTheme.Color.text3
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let b = rows[indexPath.item]
        let sheet = UIAlertController(title: b.displayTitle, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "恢复", style: .default) { [weak self] _ in
            BKDraftStore.shared.restore(b)
            self?.reload()
        })
        sheet.addAction(UIAlertAction(title: "彻底删除", style: .destructive) { [weak self] _ in
            let alert = UIAlertController(title: "彻底删除？",
                                          message: "「\(b.displayTitle)」将被永久删除，无法恢复。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "彻底删除", style: .destructive) { _ in
                BKDraftStore.shared.delete(b)
                self?.reload()
            })
            self?.present(alert, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private static func dateText(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "删于 " + f.string(from: d)
    }
}