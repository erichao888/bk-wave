//
//  BKBatch.swift
//  bk波剪 — 批（一次导入的多条视频）与单条素材编辑态
//
//  【为什么单独一套模型】
//  bk波剪是「一次导入一批 → 逐条进波剪页手调 → ☰ 列表勾选批量导出」。
//  一格 = 一批，批里每条独立存编辑态。这和 bk剪辑 v1.2.7 的
//  BKDraftBatch → BKProject[] 两层模型一致，但字段精简到 bk波剪用得上的。
//
//  【全部 Codable：整批 JSON 落盘】
//  元组 [(Double, Double)] 不可序列化，所以源时间区间用 BKRange 结构体承载；
//  编辑态读写在元组与 BKRange 之间转换（见下方 extension）。
//

import Foundation

/// 源时间区间（可 Codable —— 元组不可序列化，落盘专用）
struct BKRange: Codable, Equatable {
    var start: Double
    var end: Double

    var tuple: (Double, Double) { (start, end) }
    init(start: Double, end: Double) { self.start = start; self.end = end }
    init(_ t: (Double, Double)) { self.start = t.0; self.end = t.1 }
}

extension Array where Element == BKRange {
    /// [BKRange] → [(Double, Double)]，喂给编辑器/BKDetector
    var tuples: [(Double, Double)] { map { $0.tuple } }
}

extension Array where Element == (Double, Double) {
    /// [(Double, Double)] → [BKRange]，落盘前转换
    var ranges: [BKRange] { map { BKRange($0) } }
}

/// 批里的一条素材及其编辑态。
struct BKClipItem: Codable, Identifiable {
    var id: UUID
    /// 相册 localID（加载 AVAsset 用）
    var localID: String
    /// 素材名（去扩展名），列表展示用，落盘免得每次查相册
    var assetName: String
    /// 原片时长（秒）。★ **必须可选**：v1.1.2 之前存的草稿 JSON 里没有这个键，
    /// 写成非可选会让 synthesized Codable 直接解码失败、老草稿全丢（2B-2 踩过的同款坑）。
    /// 缺失时列表现场用 BKVideoLibrary.duration(localID:) 补
    var duration: Double?
    /// 源时间删除区间（与 BKEditorViewController.cuts 同一口径）
    var cuts: [BKRange]
    /// 折叠后的保留段；nil = 未折叠（红区还在，cuts 是删除区间）
    var keepBase: [BKRange]?
    var thresholdDb: Double
    var autoThresholdDb: Double?
    /// 用户是否动过刀（决定 ☰ 列表里文件名是否标红）
    var everEdited: Bool
    /// 折叠红区时的删除区间数（「N 刀」徽标用）。
    /// ★ 可选：老草稿 JSON 没这键，非可选会解码失败（同 duration 的坑）。
    /// 折叠后 cuts 被清空，刀数只能靠它记；未折叠时直接数 cuts
    var redCount: Int?

    /// 「删过红区」：用户动过刀，或已经折叠红区
    var hasDeletedRed: Bool { everEdited || keepBase != nil }

    /// 这条的刀数（删除区间数）：未折叠数 cuts，折叠后 cuts 已清空、靠 redCount 记
    var cutCount: Int {
        if keepBase != nil { return redCount ?? 0 }
        return cuts.count
    }

    /// 删红后时长（秒）。**没删过红返回 nil** —— 调用方据此显示「无删红」
    var trimmedDuration: Double? {
        guard hasDeletedRed else { return nil }
        if let kb = keepBase {
            return kb.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        }
        let cut = cuts.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        return max(0, (duration ?? 0) - cut)
    }
}

/// 一次导入的多条视频 = 一批。
struct BKBatch: Codable, Identifiable {
    var id: UUID
    var title: String
    var items: [BKClipItem]
    var createdAt: Date
    var lastEditedAt: Date
    /// 移入回收站的时间；nil = 正常显示。★ 可选：老草稿没这键
    var deletedAt: Date?

    /// 标题缺省时按条数生成，保证列表有字
    var displayTitle: String {
        title.isEmpty ? String(format: "未命名 %d 条", items.count) : title
    }

    /// 批内总刀数（各条删除区间数之和）—— 草稿格左上角「N 刀」徽标用
    var totalCuts: Int {
        items.reduce(0) { $0 + $1.cutCount }
    }
}
