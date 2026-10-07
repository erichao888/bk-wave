//
//  BKDebugConsole.swift
//  bk波剪 — App 内运行日志（调试面板）
//
//  【为什么必须有这个页面】
//  皓哥没有 Mac，看不到 Xcode 控制台。真机上出问题时，**日志是我唯一的远程眼睛**：
//  他在这个面板里点「分享」把 bk.log 发过来，我就能定位。bk剪辑 v1.2.x 就是靠它
//  抓到 iOS 26 上相册授权回调不触发的（当时没有任何报错，只有日志时序能证明）。
//
//  【唤出方式：连点版本号 7 次】
//  不放显眼位置——现实里误触的概率比想 debug 的概率高得多。
//  摇一摇走路必误触，所以没开（bk剪辑里也是默认关的）。
//
//  【绝不能用 #if DEBUG】
//  Ad Hoc 分发出来的是 Release 构建，编译宏不生效。开关走 UserDefaults 运行时判断。
//
//  日志核心在 Core/BKLog.swift，系统探针在 UI/BKProbe.swift，本文件只做「显示 + 入口」。
//

import UIKit

// MARK: - 入口

enum BKDebug {

    private static let enabledKey = "bk_debug_enabled"
    private static var versionTaps = 0
    private static var lastTapDate = Date()

    /// 面板开关（UserDefaults 运行时判断，Release 包照样能开）
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 连点几次唤出。7 次是「不像误触、又不难等」的经验值
    static let requiredTaps = 7

    /// 首页版本号那行连点时调用
    static func tapVersionTag(_ from: UIViewController? = nil) {
        let now = Date()
        // 两次点击间隔超过 2 秒就重新计数，避免「随手点了两下」凑数
        if now.timeIntervalSince(lastTapDate) > 2.0 { versionTaps = 0 }
        lastTapDate = now
        versionTaps += 1
        if versionTaps >= requiredTaps {
            versionTaps = 0
            isEnabled = true
            present(from: from)
        }
    }

    static func present(from source: UIViewController? = nil) {
        guard let src = source ?? topViewController() else { return }
        if src.presentedViewController != nil { return }
        let panel = BKDebugPanelViewController()
        let nav = UINavigationController(rootViewController: panel)
        nav.modalPresentationStyle = .fullScreen
        src.present(nav, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        guard let app = UIApplication.shared.delegate as? AppDelegate else { return nil }
        var vc = app.window?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        if let nav = vc as? UINavigationController { vc = nav.topViewController }
        return vc
    }
}

// MARK: - 日志面板

final class BKDebugPanelViewController: UIViewController {

    private var entries: [BKLogEntry] = []
    private var minLevel: BKLogLevel = .verbose
    private var keyword = ""
    private var follow = true

    private let searchBar = UISearchBar()
    private let levelSeg = UISegmentedControl(items: ["全部", "D", "I", "W", "E"])
    private let followSwitch = UISwitch()
    private let tableView = UITableView(frame: .zero, style: .plain)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        title = "运行日志"

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain,
                                                           target: self,
                                                           action: #selector(closePanel))

        searchBar.delegate = self
        searchBar.placeholder = "搜关键字"
        searchBar.searchBarStyle = .minimal
        searchBar.tintColor = BKTheme.Color.accent

        levelSeg.selectedSegmentIndex = 0
        levelSeg.addTarget(self, action: #selector(levelChanged), for: .valueChanged)

        let followLabel = UILabel()
        followLabel.text = "跟随最新"
        followLabel.font = BKTheme.Font.small
        followLabel.textColor = BKTheme.Color.text2

        followSwitch.isOn = true
        followSwitch.onTintColor = BKTheme.Color.accent
        followSwitch.addTarget(self, action: #selector(toggleFollow), for: .valueChanged)

        let spacer = UIView()
        let filterRow = UIStackView(arrangedSubviews: [levelSeg, followLabel, followSwitch, spacer])
        filterRow.axis = .horizontal
        filterRow.spacing = BKTheme.Space.sm
        filterRow.alignment = .center

        tableView.backgroundColor = BKTheme.Color.page
        tableView.separatorColor = BKTheme.Color.lineSoft
        tableView.register(BKLogCell.self, forCellReuseIdentifier: BKLogCell.reuseID)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 28

        let stack = UIStackView(arrangedSubviews: [searchBar, filterRow, tableView])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let copy = UIBarButtonItem(title: "复制", style: .plain, target: self,
                                   action: #selector(copyLog))
        let share = UIBarButtonItem(title: "分享", style: .plain, target: self,
                                    action: #selector(shareLog))
        let info = UIBarButtonItem(title: "设备信息", style: .plain, target: self,
                                   action: #selector(showInfo))
        let clear = UIBarButtonItem(title: "清空", style: .plain, target: self,
                                    action: #selector(clearLog))
        clear.tintColor = BKTheme.Color.danger
        setToolbarItems([copy,
                         UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                         share,
                         UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                         info,
                         UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                         clear], animated: false)
        navigationController?.setToolbarHidden(false, animated: false)

        reload()
        // 接管日志回调：面板开着时新日志实时滚出来
        BKLog.shared.sink = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController == nil {
            // 交还日志回调。只有本面板会占用 sink，直接置 nil 即可
            BKLog.shared.sink = nil
        }
    }

    // MARK: - 数据

    private func reload() {
        entries = BKLog.shared.snapshot(minLevel: minLevel, keyword: keyword)
        tableView.reloadData()
        if follow, !entries.isEmpty {
            tableView.scrollToRow(at: IndexPath(row: entries.count - 1, section: 0),
                                  at: .bottom, animated: false)
        }
        title = "运行日志 (\(entries.count))"
    }

    private func level(for index: Int) -> BKLogLevel {
        switch index {
        case 1:  return .debug
        case 2:  return .info
        case 3:  return .warn
        case 4:  return .error
        default: return .verbose
        }
    }

    // MARK: - 动作

    @objc private func levelChanged() {
        minLevel = level(for: levelSeg.selectedSegmentIndex)
        reload()
    }

    @objc private func toggleFollow() {
        follow = followSwitch.isOn
        if follow { reload() }
    }

    @objc private func closePanel() {
        dismiss(animated: true)
    }

    @objc private func clearLog() {
        BKLog.shared.clear()
        reload()
        hint("已清空")
    }

    @objc private func copyLog() {
        UIPasteboard.general.string = BKLog.shared.exportText(minLevel: minLevel)
        hint("已复制到剪贴板")
    }

    @objc private func shareLog() {
        BKLog.shared.flush()
        let url = BKLog.shared.logFileURL
        let act = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        act.popoverPresentationController?.sourceView = view
        present(act, animated: true)
    }

    @objc private func showInfo() {
        navigationController?.pushViewController(BKDeviceInfoViewController(), animated: true)
    }

    private func hint(_ text: String) {
        BKLog.shared.i(text)
        reload()
    }
}

// MARK: - 表格

extension BKDebugPanelViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: BKLogCell.reuseID,
                                                 for: indexPath) as! BKLogCell
        cell.configure(entries[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // 点一行 = 复制整行（含 文件:行号 函数名），排查时直接粘贴给我
        UIPasteboard.general.string = entries[indexPath.row].formatted
        hint("已复制该行")
    }
}

extension BKDebugPanelViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        keyword = searchText
        reload()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

extension BKDebugPanelViewController: BKLogSink {
    func logDidAppend() {
        // BKLog 已切主线程回调，这里再兜一层防万一
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }
}

// MARK: - 日志行

final class BKLogCell: UITableViewCell {

    static let reuseID = "BKLogCell"

    private let timeLabel = UILabel()
    private let msgLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BKTheme.Color.page
        selectionStyle = .none

        timeLabel.font = BKTheme.Font.monoSmall
        timeLabel.textColor = BKTheme.Color.text3
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        msgLabel.font = BKTheme.Font.monoSmall
        msgLabel.numberOfLines = 0

        contentView.addSubview(timeLabel)
        contentView.addSubview(msgLabel)
        for v in [timeLabel, msgLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            timeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),

            msgLabel.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 6),
            msgLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            msgLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            msgLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    func configure(_ e: BKLogEntry) {
        timeLabel.text = e.shortTime
        msgLabel.text = "[" + e.level.tag + "] " + e.message
        msgLabel.textColor = Self.color(for: e.level)
    }

    static func color(for level: BKLogLevel) -> UIColor {
        switch level {
        case .verbose: return BKTheme.Color.text3
        case .debug:   return BKTheme.Color.text2
        case .info:    return BKTheme.Color.text
        case .warn:    return BKTheme.Color.warning
        case .error:   return BKTheme.Color.danger
        }
    }
}

// MARK: - 设备信息页

final class BKDeviceInfoViewController: UITableViewController {

    private var rows: [(String, String)] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设备信息"
        tableView.backgroundColor = BKTheme.Color.page
        tableView.separatorColor = BKTheme.Color.lineSoft
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "刷新", style: .plain,
                                                            target: self, action: #selector(refresh))
        refresh()
    }

    @objc private func refresh() {
        let commit = (Bundle.main.object(forInfoDictionaryKey: "BKCommitSHA") as? String) ?? "-"
        rows = [
            ("设备", BKProbe.deviceName),
            ("系统", "iOS " + UIDevice.current.systemVersion),
            ("App 版本", "\(BKConfig.appVersion) (\(BKConfig.buildNumber))"),
            ("Commit", commit),
            ("内存占用", String(format: "%.0f MB", BKProbe.memoryUsedMB())),
            ("剩余磁盘", BKProbe.freeDiskText()),
            ("缓存", BKProbe.cachesSizeText()),
            ("电量", BKProbe.batteryText),
            ("日志文件", BKLog.shared.logFileURL.lastPathComponent)
        ]
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // 用 .value1 才有右侧详情文字；注册 class 出来的是 .default，所以这里手工建
        let cell = tableView.dequeueReusableCell(withIdentifier: "info")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "info")
        cell.backgroundColor = BKTheme.Color.panel
        cell.textLabel?.text = rows[indexPath.row].0
        cell.textLabel?.textColor = BKTheme.Color.text
        cell.detailTextLabel?.text = rows[indexPath.row].1
        cell.detailTextLabel?.textColor = BKTheme.Color.text2
        cell.detailTextLabel?.numberOfLines = 0
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        UIPasteboard.general.string = rows[indexPath.row].1
    }
}
