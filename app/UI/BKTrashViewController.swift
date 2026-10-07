//
//  BKTrashViewController.swift
//  bk波剪 — 回收站（首页左上🗑）
//
//  删除草稿不是真删：BKBatch 打上 deletedAt 标记，30 天内可恢复。
//  过期（deletedAt 超过 BKConfig.Draft.trashKeepDays）的进页面时自动清掉。
//
//  【三个键，默认状态就都看得见（皓哥 2026-10-08）】
//  · 导航右上「全选」→ 一键全选并进入多选态（再按变「取消」退出）
//  · 导航右上「清空」→ 一键清空回收站（全部真删，二次确认）
//  · 多选态底栏「彻底删除 (N)」；单个勾选/取消 = 点行
//  （原来「全选」藏在多选态底栏里，不直观，等于没有）
//

import UIKit

final class BKTrashViewController: UITableViewController {

    private var rows: [BKBatch] = []
    private var picking = false
    private var selected = Set<Int>()

    private let emptyLabel = UILabel()
    /// 非多选态显示「全选」（一点直接全选并进入多选态）、多选态显示「取消」
    private lazy var pickButton = UIBarButtonItem(title: "全选", style: .plain,
                                                   target: self, action: #selector(pickTapped))
    /// 清空回收站（真删全部）
    private lazy var clearButton = UIBarButtonItem(title: "清空", style: .plain,
                                                   target: self, action: #selector(clearTapped))

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "回收站"
        view.backgroundColor = BKTheme.Color.page
        tableView.backgroundColor = BKTheme.Color.page
        tableView.separatorColor = BKTheme.Color.lineSoft
        tableView.rowHeight = 56
        navigationItem.rightBarButtonItems = [pickButton, clearButton]

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
        navigationController?.setToolbarHidden(!picking, animated: false)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: false)
    }

    private func reload() {
        rows = BKDraftStore.shared.trashBatches()
        selected = selected.filter { $0 < rows.count }
        emptyLabel.isHidden = !rows.isEmpty
        pickButton.isEnabled = !rows.isEmpty
        clearButton.isEnabled = !rows.isEmpty
        tableView.reloadData()
        updateBar()
    }

    // MARK: - 选择 / 清空

    /// 「全选 / 取消」两态键：
    /// 非多选态 = 直接**全选并进入多选态**（省掉「先进多选再全选」两次点按）；
    /// 多选态 = 退出多选并清空勾选。单个勾选/取消靠**点行**完成。
    @objc private func pickTapped() {
        if picking {
            picking = false
            selected.removeAll()
            pickButton.title = "全选"
            navigationController?.setToolbarHidden(true, animated: false)
            reload()
            return
        }
        guard !rows.isEmpty else { return }
        picking = true
        selected = Set(0 ..< rows.count)
        pickButton.title = "取消"
        navigationController?.setToolbarHidden(false, animated: false)
        reload()
    }

    /// 一键清空回收站（真删，不可恢复）
    @objc private func clearTapped() {
        guard !rows.isEmpty else { return }
        let alert = UIAlertController(title: "清空回收站？",
                                      message: "\(rows.count) 批将被永久删除，无法恢复。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            for b in self.rows {
                BKDraftStore.shared.delete(b)
            }
            self.reload()
        })
        present(alert, animated: true)
    }

    @objc private func deleteSelectedTapped() {
        guard !selected.isEmpty else { return }
        let n = selected.count
        let alert = UIAlertController(title: "彻底删除？",
                                      message: "选中的 \(n) 批将被永久删除，无法恢复。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "彻底删除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            for i in self.selected where i < self.rows.count {
                BKDraftStore.shared.delete(self.rows[i])
            }
            self.selected.removeAll()
            self.reload()
        })
        present(alert, animated: true)
    }

    /// 底栏只留「彻底删除」——全选已提到导航右上，按钮不在这里重复
    private func updateBar() {
        guard picking else { return }
        let del = UIBarButtonItem(title: selected.isEmpty ? "彻底删除" : "彻底删除 (\(selected.count))",
                                  style: .plain, target: self, action: #selector(deleteSelectedTapped))
        del.tintColor = BKTheme.Color.danger
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbarItems = [del, spacer]
    }

    // MARK: - 表格

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
        if picking {
            cell.accessoryType = selected.contains(indexPath.item) ? .checkmark : .none
        } else {
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let b = rows[indexPath.item]
        if picking {
            if selected.contains(indexPath.item) {
                selected.remove(indexPath.item)
            } else {
                selected.insert(indexPath.item)
            }
            tableView.reloadRows(at: [indexPath], with: .none)
            updateBar()
            return
        }
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