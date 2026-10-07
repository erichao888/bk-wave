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

    /// 所有批，按最近编辑时间倒序（最新的在最前）
    func allBatches() -> [BKBatch] {
        lock.lock(); defer { lock.unlock() }
        return cache.values.sorted { $0.lastEditedAt > $1.lastEditedAt }
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

    /// 一次导入 = 建一批，每条先记下 localID + 名字，刀口为空（进编辑页才检测）
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
                       everEdited: false)
        }
        var b = BKBatch(id: UUID(), title: "", items: items, createdAt: now, lastEditedAt: now)
        b.title = b.displayTitle
        return b
    }
}
