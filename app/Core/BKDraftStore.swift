//
//  BKDraftStore.swift
//  bk波剪 — 草稿（批）落盘
//
//  【整批 JSON 存 documents/bkwave_drafts.json】
//  一批 = 一次导入的多条视频，整批一起读写。列表（首页 / ☰）和波剪页
//  都从这里取，编辑完写回，保证「回 ☰ 列表勾选导出」时每条的刀口都还在。
//
//  【线程】UI 层都在主线程调，仍加一把 NSLock 防极端并发（导出读、编辑写）。
//

import Foundation

final class BKDraftStore {

    static let shared = BKDraftStore()

    private let fileURL: URL
    private var cache: [UUID: BKBatch] = [:]
    private let lock = NSLock()

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("bkwave_drafts.json")
        loadFromDisk()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let list = try? JSONDecoder().decode([BKBatch].self, from: data) else { return }
        for b in list { cache[b.id] = b }
    }

    private func persist() {
        let list = Array(cache.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 所有批，按最近编辑时间倒序（最新的在最前）。**不含回收站里的**
    func allBatches() -> [BKBatch] {
        lock.lock(); defer { lock.unlock() }
        return cache.values
            .filter { $0.deletedAt == nil }
            .sorted { $0.lastEditedAt > $1.lastEditedAt }
    }

    /// 回收站里的批（deletedAt 非空），最近删的在前
    func trashBatches() -> [BKBatch] {
        lock.lock(); defer { lock.unlock() }
        return cache.values
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// 移入回收站（30 天内可恢复）—— 不是真删
    func moveToTrash(_ batch: BKBatch) {
        var b = batch
        b.deletedAt = Date()
        save(b)
    }

    /// 从回收站恢复
    func restore(_ batch: BKBatch) {
        var b = batch
        b.deletedAt = nil
        save(b)
    }

    /// 清掉回收站里超过保留期的批（bk-clip 同款：30 天）
    func purgeExpiredTrash() {
        let deadline = Date().addingTimeInterval(-Double(BKConfig.Draft.trashKeepDays) * 86400)
        for b in trashBatches() where (b.deletedAt ?? .distantPast) < deadline {
            delete(b)
            BKLog.shared.i("回收站过期清理：「\(b.displayTitle)」")
        }
    }

    func batch(id: UUID) -> BKBatch? {
        lock.lock(); defer { lock.unlock() }
        return cache[id]
    }

    func save(_ batch: BKBatch) {
        lock.lock()
        var b = batch
        b.lastEditedAt = Date()
        cache[b.id] = b
        let list = Array(cache.values)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func delete(_ batch: BKBatch) {
        lock.lock()
        cache.removeValue(forKey: batch.id)
        let list = Array(cache.values)
        lock.unlock()
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 一次导入 = 建一批。批标题默认取第一条素材名（bk-clip 草稿页同款），
    /// 多条时追加「等 N 条」；后面可重命名
    func makeBatch(localIDs: [String]) -> BKBatch {
        let now = Date()
        let items = localIDs.map { id -> BKClipItem in
            BKClipItem(id: UUID(),
                       localID: id,
                       assetName: (BKVideoLibrary.assetName(localID: id) as NSString).deletingPathExtension,
                       duration: BKVideoLibrary.duration(localID: id),
                       cuts: [],
                       keepBase: nil,
                       thresholdDb: -35,
                       autoThresholdDb: nil,
                       everEdited: false,
                       redCount: nil)
        }
        var b = BKBatch(id: UUID(), title: "", items: items, createdAt: now, lastEditedAt: now, deletedAt: nil)
        if let first = items.first {
            b.title = items.count > 1 ? "\(first.assetName) 等\(items.count)条" : first.assetName
        }
        return b
    }
}
