//
//  AppDelegate.swift
//  bk波剪 — 应用入口
//
//  刻意不用 SceneDelegate：单一 window 用传统写法，少一处可能出错的地方。
//  没有 Xcode，出错的成本是「重新传一次云编译」。
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // 先装崩溃捕获 + 会话头（版本 / commit / 机型 / 系统），并检查上次是否异常退出
        BKLog.shared.install()

        BKLog.shared.i("=== bk波剪 \(BKConfig.appVersion) (\(BKConfig.buildNumber)) 启动 ===")
        BKLog.shared.i("设备 \(BKProbe.deviceName) · 系统 \(UIDevice.current.systemVersion)")

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = BKTheme.Color.bg
        win.rootViewController = UINavigationController(rootViewController: BKRootViewController())
        win.makeKeyAndVisible()
        window = win

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 上滑强杀不给任何回调，草稿落盘靠编辑过程中的 debounce，这里只补刀
        BKLog.shared.d("进入后台")
        BKLog.shared.flush()            // 把还没落完的日志刷下去，别等异步队列
        BKLog.shared.markCleanExit()    // 标记本次为正常挂起，下次启动不误报「异常退出」
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        BKLog.shared.w("系统内存告警，当前占用 \(String(format: "%.0f", BKProbe.memoryUsedMB())) MB")
    }
}
