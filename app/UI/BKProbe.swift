//
//  BKProbe.swift
//  bk波剪 — 系统探针（设备名 / 内存 / 磁盘）
//
//  放 UI 层：deviceName 用到 UIDevice（UIKit），Core 层禁 import UIKit。
//  AppDelegate 与排障面板引用它。
//

import UIKit
// ⚠️ iOS SDK 没有可 import 的 `mach` 模块（modulemap 缺失），直接 `import mach` 会
// 「unable to resolve module dependency」。macOS 有，用 canImport 分平台。
#if canImport(mach)
import mach
#endif

enum BKProbe {

    /// 当前 App 实际占用的物理内存（MB），不是系统总量。
    /// iOS 无 mach 模块，回退到系统物理内存（仅排障日志用，量级够看）。
    static func memoryUsedMB() -> Double {
        #if canImport(mach)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024.0 / 1024.0
        #else
        return Double(ProcessInfo.processInfo.physicalMemory) / 1024.0 / 1024.0
        #endif
    }

    static func freeDiskText() -> String {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? -1
        return free < 0 ? "未知" : ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    static func cachesSizeText() -> String {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ByteCountFormatter.string(fromByteCount: Int64(folderSize(at: url)), countStyle: .file)
    }

    static func appSupportSizeText() -> String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ByteCountFormatter.string(fromByteCount: Int64(folderSize(at: url)), countStyle: .file)
    }

    static func folderSize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
            total += size
        }
        return total
    }

    static let deviceName: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let id = mirror.children.compactMap { $0.value as? Int8 }.filter { $0 != 0 }.map { String(UnicodeScalar(UInt8($0))) }.joined()
        return id.isEmpty ? UIDevice.current.model : id
    }()

    static var batteryText: String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = Int(abs(UIDevice.current.batteryLevel) * 100)
        switch UIDevice.current.batteryState {
        case .charging:  return "\(level)% · 充电中"
        case .full:      return "\(level)% · 已充满"
        case .unplugged: return "\(level)%"
        default:         return "未知"
        }
    }
}
