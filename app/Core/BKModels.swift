//
//  BKModels.swift
//  bk波剪 — 数据模型（单素材，v1.x 时间线模型）
//
//  bk波剪是纯波形剪辑：一条视频 → 一段波形 → 切气口 → 导出。
//  所以直接沿用 bk剪辑 v1.x 的**单素材源时间模型**（BKMark + 完整覆盖区间序列），
//  不引入 v2 的多片段主轨 / BKTrackModel / 折叠那一套复杂度。
//
//  核心不变量：marks 是一条完整覆盖 [0, duration] 的区间序列，
//  相邻严丝合缝、首段从 0 起、末段到 duration 止。
//  拖动分界线 = 同时改相邻两条边界，一步到位，不存在不同步。
//  导出 = 滤出所有 .keep 段。撤销 = 直接换整个 marks 数组。
//
//  全部 Codable：自动保存直接 JSON 落盘（bk波剪的编辑态落盘用）。
//

import Foundation
import CoreGraphics

// MARK: - 区间标记

/// 时间线上的一段。kind 决定它最终是被保留还是被剪掉。
struct BKMark: Codable, Equatable {

    enum Kind: String, Codable {
        case keep
        case cut
    }

    var id: UUID
    var start: Double
    var end: Double
    var kind: Kind

    init(start: Double, end: Double, kind: Kind, id: UUID = UUID()) {
        self.start = start
        self.end = end
        self.kind = kind
        self.id = id
    }

    var duration: Double { end - start }

    /// 是否短到不值得单独存在。UI 用它决定要不要给这条标记画可点区域
    var isTooNarrow: Bool { duration < 0.05 }
}

// MARK: - 音频包络

/// 提取出来的响度曲线。frames 是每一帧的 dB 值，相邻两帧间隔 hopSec 秒。
/// 刻意不存 AVAsset —— 包络随编辑态落盘，AVAsset 不可序列化。
struct BKEnvelope: Codable {

    /// 每帧 dB 值
    var frames: [Float]
    /// 相邻帧的时间间隔（秒）
    var hopSec: Double
    /// 素材采样率
    var sampleRate: Double
    /// 素材总时长（秒）
    var duration: Double

    /// 某一时刻对应的 dB 值。越界返回最值而不是崩溃
    func db(at time: Double) -> Float {
        guard !frames.isEmpty, hopSec > 0 else { return -60 }
        let idx = Int(time / hopSec)
        let clamped = min(max(idx, 0), frames.count - 1)
        return frames[clamped]
    }

    /// 区间内的最大 dB。用来判断这一段到底有多响
    func peak(from start: Double, to end: Double) -> Float {
        guard !frames.isEmpty, hopSec > 0, end > start else { return -60 }
        let a = min(max(Int(start / hopSec), 0), frames.count - 1)
        let b = min(max(Int(end / hopSec), 0), frames.count - 1)
        guard b >= a else { return frames[a] }
        return frames[a...b].max() ?? -60
    }
}

// MARK: - 检测结果

/// 一次自动检测的产出。除了结果，还要把「过程」带出来 —— 埋点要记，UI 要给提示。
struct BKDetectResult {

    /// Otsu 算出的原始阈值（未被夹逼）
    let rawThresholdDb: Double
    /// 实际使用的阈值（夹逼之后）
    let thresholdDb: Double
    /// 是否被夹逼过。为 true 才值得提醒用户
    var wasClamped: Bool { abs(rawThresholdDb - thresholdDb) > 0.01 }
    /// 素材是否适用本算法。否的话下面的 reason 是给用户看的原因
    let applicable: Bool
    let reason: String?
    /// 剔除 minCut 之前一共找出多少刀
    let candidateCount: Int
    /// 最终采纳的刀数
    let adoptedCount: Int
}

// MARK: - 拖拽把手的哪一端

/// 放 Core 层：BKTrackView（第一阶段拖红区边缘）与 BKTimeline 都要用它，
/// Core 不该反向依赖 UI。
enum BKHandleEnd {
    case head
    case tail
}

// MARK: - 时间线操作
//
// 所有改动统一走这里，保证「相邻严丝合缝」这个不变量不被破坏。

enum BKTimeline {

    /// 把一串切点和总时长合成完整的区间序列。这是从检测到可编辑状态的唯一入口。
    static func build(duration: Double, cuts: [(Double, Double)]) -> [BKMark] {
        var marks: [BKMark] = []
        var cursor: Double = 0
        let sorted = merge(cuts, duration: duration)
        for (s, e) in sorted {
            if s > cursor {
                marks.append(BKMark(start: cursor, end: s, kind: .keep))
            }
            marks.append(BKMark(start: s, end: e, kind: .cut))
            cursor = e
        }
        if cursor < duration {
            marks.append(BKMark(start: cursor, end: duration, kind: .keep))
        }
        return normalize(marks, duration: duration)
    }

    /// 洗净 + 合并区间：夹回 [0, duration]、丢掉零宽的、排序、**合并重叠与相接的**。
    static func merge(_ cuts: [(Double, Double)], duration: Double) -> [(Double, Double)] {
        let clean = cuts
            .map { (max($0.0, 0), min($0.1, duration)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var out: [(Double, Double)] = []
        for iv in clean {
            if let last = out.last, iv.0 <= last.1 {
                out[out.count - 1].1 = max(last.1, iv.1)
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// 把「删除区间」合成**显示用**的片段序列（含切口切开的 keep 段）。
    /// 只用于显示与点选，不参与导出 —— 导出只认 keep 段（不含 splits）。
    static func pieces(duration: Double,
                       cuts: [(Double, Double)],
                       splits: [Double]) -> [BKMark] {
        let clean = merge(cuts, duration: duration)
        let cutList = clean.filter { $0.1 > $0.0 }
        let edges = Set(splits.map { min(max($0, 0), duration) })
            .filter { t in t > 0 && t < duration && !cutList.contains { t >= $0.0 && t <= $0.1 } }
            .sorted()

        var out: [BKMark] = []
        var cursor: Double = 0

        func splitKeep(_ a: Double, _ b: Double) {
            guard b > a else { return }
            var from = a
            for t in edges where t > a && t < b {
                if t > from { out.append(BKMark(start: from, end: t, kind: .keep)) }
                from = t
            }
            if b > from { out.append(BKMark(start: from, end: b, kind: .keep)) }
        }

        for iv in clean {
            splitKeep(cursor, iv.0)
            if iv.1 > iv.0 { out.append(BKMark(start: iv.0, end: iv.1, kind: .cut)) }
            cursor = iv.1
        }
        splitKeep(cursor, duration)
        return out
    }

    /// 按「最近的边界」拖动，不按 index。
    /// 原因：index 会随显示粒度变；时间坐标才是稳的。
    static func moveBoundary(in marks: [BKMark],
                             near time: Double,
                             to newTime: Double) -> [BKMark]? {
        var bestIdx: Int?
        var bestDist = Double.greatestFiniteMagnitude
        for i in 0 ..< max(0, marks.count - 1) {
            let d = abs(marks[i].end - time)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        guard let idx = bestIdx else { return nil }
        return moveBoundary(in: marks, afterIndex: idx, to: newTime)
    }

    /// 拖动一条分界线。同时改左右两条标记的边界。返回 nil 表示拖到了非法位置。
    static func moveBoundary(in marks: [BKMark],
                             afterIndex index: Int,
                             to time: Double) -> [BKMark]? {
        guard index >= 0, index < marks.count - 1 else { return nil }
        let left = marks[index]
        let right = marks[index + 1]
        let minLen = 0.05
        guard time > left.start + minLen, time < right.end - minLen else { return nil }

        var next = marks
        next[index].end = time
        next[index + 1].start = time
        return next
    }

    /// 切换某条标记的状态。切完之后左右两边状态相同，就合并成一条。
    static func toggle(marks: [BKMark], at index: Int) -> [BKMark] {
        guard index >= 0, index < marks.count else { return marks }
        var next = marks
        next[index].kind = (next[index].kind == .cut) ? .keep : .cut
        return mergeSameKind(next)
    }

    /// 合并相邻的同状态区间
    static func mergeSameKind(_ marks: [BKMark]) -> [BKMark] {
        var out: [BKMark] = []
        for m in marks {
            if let last = out.last, last.kind == m.kind {
                out[out.count - 1].end = m.end
            } else {
                out.append(m)
            }
        }
        return out
    }

    /// 兜底修正：清掉零宽区间、重排顺序、补齐首尾。任何从磁盘读回来的数据都应先过一遍。
    static func normalize(_ marks: [BKMark], duration: Double) -> [BKMark] {
        let cleaned = marks
            .map { BKMark(start: min(max($0.start, 0), duration),
                          end: min(max($0.end, 0), duration),
                          kind: $0.kind, id: $0.id) }
            .filter { $0.end - $0.start > 0.001 }
            .sorted { $0.start < $1.start }

        var out: [BKMark] = []
        for m in cleaned {
            if let lastEnd = out.last?.end {
                if m.start < lastEnd {
                    out[out.count - 1].end = m.start
                }
                if let newEnd = out.last?.end, newEnd < m.start {
                    out.append(BKMark(start: newEnd, end: m.start, kind: .keep))
                }
            }
            out.append(m)
        }

        let widowed = out.filter { $0.end - $0.start > 0.001 }
        guard !widowed.isEmpty else {
            return [BKMark(start: 0, end: duration, kind: .keep)]
        }

        var result = mergeSameKind(widowed)
        if let first = result.first, first.start > 0 {
            result.insert(BKMark(start: 0, end: first.start, kind: .keep), at: 0)
        }
        if let last = result.last, last.end < duration {
            result.append(BKMark(start: last.end, end: duration, kind: .keep))
        }
        return result
    }

    /// 拖动红区边缘调气口大小（第一阶段）：三重夹取。
    /// `near` 是起手时那条边缘的原片时间，`newTime` 是要挪到的新位置。
    /// 约束：① 不越素材首尾 [0, duration] ② 红区不短于 minSeg。
    /// - Returns: 新的 cuts；非法位置返回 nil（界面保持原样）
    static func moveRedEdge(cuts: [(Double, Double)],
                            near: Double,
                            to newTime: Double,
                            duration: Double,
                            minSeg: Double = 0.05) -> [(Double, Double)]? {
        guard !cuts.isEmpty else { return nil }
        var hitIndex = -1
        var whichEnd = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, iv) in cuts.enumerated() {
            if near >= iv.0 - 0.02 && near <= iv.1 + 0.02 {
                let dHead = abs(iv.0 - near)
                let dTail = abs(iv.1 - near)
                if min(dHead, dTail) < bestDist {
                    bestDist = min(dHead, dTail)
                    hitIndex = i
                    whichEnd = dHead <= dTail ? 0 : 1
                }
            }
        }
        guard hitIndex >= 0 else { return nil }

        var out = cuts
        let cur = out[hitIndex]
        if whichEnd == 0 {
            let ns = min(max(newTime, 0), cur.1 - minSeg)
            guard ns >= 0, cur.1 - ns >= minSeg else { return nil }
            out[hitIndex].0 = ns
        } else {
            let ne = max(min(newTime, duration), cur.0 + minSeg)
            guard ne <= duration, ne - cur.0 >= minSeg else { return nil }
            out[hitIndex].1 = ne
        }
        return out
    }

    /// 一段素材的状态（编辑态拖把手用）：两端夹取，不越 [0, duration]、不短于 minSeg。
    static func clampRegion(_ start: Double,
                            _ end: Double,
                            duration: Double,
                            minSeg: Double) -> (start: Double, end: Double) {
        let lo: Double = 0
        let hi: Double = max(duration, 0)
        var s = min(max(start, lo), hi)
        var e = min(max(end, lo), hi)
        if e - s < minSeg {
            if hi - lo < minSeg { return (lo, hi) }
            let mid = (s + e) / 2
            s = mid - minSeg / 2
            e = mid + minSeg / 2
            if s < lo { s = lo; e = lo + minSeg }
            if e > hi { s = hi - minSeg; e = hi }
        }
        return (s, e)
    }
}
