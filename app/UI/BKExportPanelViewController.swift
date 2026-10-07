//
//  BKExportPanelViewController.swift
//  bk波剪 — 导出面板（分辨率 / 帧率 + 导出 + 存相册）
//
//  【本面板只管两件事】选分辨率、选帧率，然后按当前 cuts 导出并存进相册。
//  编码参数（MP4/H.264/yuv420p/AAC-LC 192k/faststart）焊死，不在面板里开放 ——
//  那套是剪映实测能导入的组合，动一根指头都可能导不进去。
//
//  【保真原则】导出 = 滤出所有保留段（源时间）拼一条，零换算、音画由
//  AVMutableComposition 系统保证对齐。keeps 由 cuts 直接派生，单一真源。
//
//  【存相册】用 PHAssetCreationRequest 并指定 originalFilename = 导出文件名
//  （BK_<草稿名>.mp4，带 _k 序号），让相册里看到的名字和工程一致。
//

import UIKit
import AVFoundation
import Photos

final class BKExportPanelViewController: UIViewController {

    // MARK: - 数据

    private let asset: AVAsset
    /// 最终保留段（源时间，绝对坐标）。编辑器在折叠态直接传 keepBase，
    /// 未折叠态传 cuts 派生出的保留段。面板不再自己算。
    private let keeps: [(Double, Double)]
    private let baseTitle: String

    private var resolution: BKConfig.Resolution = .same
    private var frameRate: BKConfig.FrameRate = .same

    // MARK: - 视图

    private let scroll = UIScrollView()
    private let card = UIView()
    private let titleLabel = UILabel()
    private let resSeg = UISegmentedControl(items: BKConfig.Resolution.allCases.map { $0.rawValue })
    private let fpsSeg = UISegmentedControl(items: BKConfig.FrameRate.allCases.map { $0.rawValue })
    private let summaryLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()
    private let exportButton = UIButton(type: .system)
    private let closeButton = UIBarButtonItem()
    private let activity = UIActivityIndicatorView(style: .medium)

    private var exporting = false

    // MARK: - 初始化

    init(asset: AVAsset, keeps: [(Double, Double)], title: String) {
        self.asset = asset
        self.keeps = keeps
        self.baseTitle = title.isEmpty ? "clip" : title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("bk波剪不走 storyboard") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BKTheme.Color.page
        title = "导出"
        setupUI()
        updateSummary()
    }

    // MARK: - UI

    private func setupUI() {
        closeButton.title = "取消"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        navigationItem.leftBarButtonItem = closeButton

        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        card.backgroundColor = BKTheme.Color.panel
        card.layer.cornerRadius = BKTheme.Radius.card
        card.layer.borderWidth = 1
        card.layer.borderColor = BKTheme.Color.line.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(card)

        titleLabel.text = "导出设置"
        titleLabel.font = BKTheme.Font.title
        titleLabel.textColor = BKTheme.Color.text
        card.addSubview(titleLabel)

        let resTitle = sectionTitle("分辨率")
        let fpsTitle = sectionTitle("帧率")
        card.addSubview(resTitle)
        card.addSubview(fpsTitle)

        resSeg.selectedSegmentIndex = 0
        resSeg.backgroundColor = BKTheme.Color.panel2
        resSeg.setTitleTextAttributes([.foregroundColor: BKTheme.Color.text], for: .normal)
        resSeg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        resSeg.addTarget(self, action: #selector(resChanged), for: .valueChanged)
        card.addSubview(resSeg)

        fpsSeg.selectedSegmentIndex = 0
        fpsSeg.backgroundColor = BKTheme.Color.panel2
        fpsSeg.setTitleTextAttributes([.foregroundColor: BKTheme.Color.text], for: .normal)
        fpsSeg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        fpsSeg.addTarget(self, action: #selector(fpsChanged), for: .valueChanged)
        card.addSubview(fpsSeg)

        summaryLabel.font = BKTheme.Font.caption
        summaryLabel.textColor = BKTheme.Color.text3
        summaryLabel.numberOfLines = 0
        card.addSubview(summaryLabel)

        progressBar.progressTintColor = BKTheme.Color.accent
        progressBar.trackTintColor = BKTheme.Color.line
        progressBar.isHidden = true
        card.addSubview(progressBar)

        progressLabel.font = BKTheme.Font.mono
        progressLabel.textColor = BKTheme.Color.text2
        progressLabel.text = ""
        progressLabel.isHidden = true
        card.addSubview(progressLabel)

        exportButton.setTitle("开始导出", for: .normal)
        exportButton.titleLabel?.font = BKTheme.Font.button
        exportButton.tintColor = .white
        exportButton.backgroundColor = BKTheme.Color.accent
        exportButton.layer.cornerRadius = BKTheme.Button.radius
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)
        card.addSubview(exportButton)

        activity.color = BKTheme.Color.text
        activity.hidesWhenStopped = true
        card.addSubview(activity)

        for v in [card, titleLabel, resTitle, fpsTitle, resSeg, fpsSeg,
                  summaryLabel, progressBar, progressLabel, exportButton, activity] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            card.topAnchor.constraint(equalTo: scroll.topAnchor, constant: BKTheme.Space.lg),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BKTheme.Space.lg),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BKTheme.Space.lg),
            card.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -BKTheme.Space.lg * 2),
            card.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -BKTheme.Space.lg),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: BKTheme.Space.lg),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),

            resTitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: BKTheme.Space.lg),
            resTitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),
            resTitle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BKTheme.Space.lg),

            resSeg.topAnchor.constraint(equalTo: resTitle.bottomAnchor, constant: BKTheme.Space.sm),
            resSeg.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),
            resSeg.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BKTheme.Space.lg),

            fpsTitle.topAnchor.constraint(equalTo: resSeg.bottomAnchor, constant: BKTheme.Space.lg),
            fpsTitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),
            fpsTitle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BKTheme.Space.lg),

            fpsSeg.topAnchor.constraint(equalTo: fpsTitle.bottomAnchor, constant: BKTheme.Space.sm),
            fpsSeg.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),
            fpsSeg.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BKTheme.Space.lg),

            summaryLabel.topAnchor.constraint(equalTo: fpsSeg.bottomAnchor, constant: BKTheme.Space.lg),
            summaryLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),
            summaryLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BKTheme.Space.lg),

            progressBar.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: BKTheme.Space.lg),
            progressBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),
            progressBar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BKTheme.Space.lg),

            progressLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: BKTheme.Space.xs),
            progressLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),
            progressLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BKTheme.Space.lg),

            exportButton.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: BKTheme.Space.lg),
            exportButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: BKTheme.Space.lg),
            exportButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -BKTheme.Space.lg),
            exportButton.heightAnchor.constraint(equalToConstant: 48),

            activity.centerYAnchor.constraint(equalTo: exportButton.centerYAnchor),
            activity.trailingAnchor.constraint(equalTo: exportButton.trailingAnchor, constant: -BKTheme.Space.lg)
        ])
    }

    private func sectionTitle(_ t: String) -> UILabel {
        let l = UILabel()
        l.text = t
        l.font = BKTheme.Font.caption
        l.textColor = BKTheme.Color.text2
        return l
    }

    // MARK: - 选项

    @objc private func resChanged() {
        resolution = BKConfig.Resolution.allCases[resSeg.selectedSegmentIndex]
        updateSummary()
    }

    @objc private func fpsChanged() {
        frameRate = BKConfig.FrameRate.allCases[fpsSeg.selectedSegmentIndex]
        updateSummary()
    }

    private func updateSummary() {
        let keepTotal = keeps.reduce(0.0) { $0 + max(0, $1.1 - $1.0) }
        if keeps.isEmpty {
            summaryLabel.text = "没有可保留的片段，先少删一点再导出"
            return
        }
        summaryLabel.text = String(format:
            "保留 %d 段 · 成品约 %.1fs\n规格：%@",
            keeps.count, keepTotal,
            BKConfig.ExportSpec(resolution: resolution, frameRate: frameRate).summary)
    }

    // MARK: - 导出

    @objc private func exportTapped() {
        guard !exporting else { return }
        guard !keeps.isEmpty else {
            summaryLabel.text = "没有可保留的片段，先少删一点再导出"
            return
        }
        let part = BKCompositionBuilder.Part(asset: asset, name: baseTitle, keeps: keeps, speed: 1.0)
        let spec = BKConfig.ExportSpec(resolution: resolution, frameRate: frameRate)

        exporting = true
        exportButton.isEnabled = false
        closeButton.isEnabled = false
        progressBar.isHidden = false
        progressLabel.isHidden = false
        progressBar.progress = 0
        progressLabel.text = "导出中 0%"
        activity.startAnimating()

        BKExporter.export(title: baseTitle, sources: [part], spec: spec,
                          progress: { [weak self] _, _, frac in
                              DispatchQueue.main.async {
                                  self?.progressBar.progress = Float(frac)
                                  self?.progressLabel.text = String(format: "导出中 %.0f%%", frac * 100)
                              }
                          },
                          completion: { [weak self] result in
                              DispatchQueue.main.async {
                                  self?.activity.stopAnimating()
                                  switch result {
                                  case .success(let url):
                                      self?.saveToLibrary(url: url)
                                  case .failure(let err):
                                      self?.finish(with: "导出失败：\(err.localizedDescription)", ok: false)
                                  }
                              }
                          })
    }

    /// 存进相册，文件名沿用导出文件（BK_…mp4）
    private func saveToLibrary(url: URL) {
        let fileName = url.lastPathComponent
        // 用 forAsset + addResource 才能带上 originalFilename（creationRequest 那版没 options 入参）

        // 先确认相册写入权限
        func proceed() {
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opt = PHAssetResourceCreationOptions()
                opt.originalFilename = fileName
                req.addResource(with: .video, fileURL: url, options: opt)
            }, completionHandler: { ok, err in
                DispatchQueue.main.async {
                    if ok {
                        self.finish(with: "已导出并存入相册：\(fileName)", ok: true)
                    } else {
                        self.finish(with: "导出完成，但存入相册失败：\(err?.localizedDescription ?? "未知")", ok: false)
                    }
                }
            })
        }

        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .authorized || status == .limited {
                proceed()
            } else {
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
                    if st == .authorized || st == .limited { proceed() }
                    else {
                        DispatchQueue.main.async {
                            self.finish(with: "相册无写入权限，文件在 App 的 Exports 目录：\(fileName)", ok: false)
                        }
                    }
                }
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            if status == .authorized {
                proceed()
            } else {
                PHPhotoLibrary.requestAuthorization { st in
                    if st == .authorized { proceed() }
                    else {
                        DispatchQueue.main.async {
                            self.finish(with: "相册无写入权限，文件在 App 的 Exports 目录：\(fileName)", ok: false)
                        }
                    }
                }
            }
        }
    }

    private func finish(with message: String, ok: Bool) {
        exporting = false
        exportButton.isEnabled = true
        closeButton.isEnabled = true
        progressLabel.text = message
        progressLabel.textColor = ok ? BKTheme.Color.success : BKTheme.Color.danger
        if ok {
            exportButton.setTitle("完成", for: .normal)
            // 完成后点「完成」即关闭
            exportButton.removeTarget(nil, action: nil, for: .allEvents)
            exportButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        } else {
            // 失败也要给个弹窗，不然「没反应」容易被当成卡死
            let alert = UIAlertController(title: "导出未完成", message: message,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
            present(alert, animated: true)
        }
    }

    @objc private func closeTapped() {
        if exporting { return }
        dismiss(animated: true)
    }
}
