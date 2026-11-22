import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）。

/// Android 的隐藏全局代理：`adb shell settings get global http_proxy` 读出来的值算不算「设了」。
/// 这个代理在 Wi-Fi 设置里看不到、换网络也带着走，所以 Baobox 不再替真手机设它（2026-11-22 用户：
/// 「不应该设置无法再 app 中看到的选项」），只在发现它还开着时提示并给一个清除按钮。
/// 没设时读到 `null` 或空；`settings put global http_proxy :0` 清除后读到 `:0`。
enum ADBGlobalProxy {
    /// 设了就返回 `host:port`，没设返回 nil。
    static func parse(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "null" { return nil }
        // `:0` 和 `host:0` 都是「关掉」的写法。
        if value.hasSuffix(":0") { return nil }
        return value
    }
}
