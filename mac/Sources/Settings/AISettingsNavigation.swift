import SwiftUI

/// 「AI」页的三栏（docs/ai-service/DESIGN.md §6.1）：功能（默认）/ 本机模型 / 云端模型。
enum AISettingsPane: String, CaseIterable, Identifiable {
    case features
    case local
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .features: return L("ai.pane.features")
        case .local: return L("ai.pane.local")
        case .cloud: return L("ai.pane.cloud")
        }
    }
}

/// 「AI」页现在在哪一栏，以及「去下载」「去填写」要定位到哪个模型 / 服务商。
/// 功能行（「AI」页里的和各工具设置页里的）都通过它跳转：切到「AI」页、切栏、选中或展开对应的那一项。
@MainActor
final class AISettingsNavigation: ObservableObject {
    static let shared = AISettingsNavigation()

    @Published var pane: AISettingsPane = .features
    /// 本机模型那栏：把这个模型选进「添加模型」，滚动过去。
    @Published var focusLocalModel: String?
    /// 云端模型那栏：把这个服务商展开。
    @Published var focusAccount: String?

    private init() {}

    func showFeatures() {
        pane = .features
        SettingsTabSelection.shared.selectedTab = AISettingsView.tabID
    }

    func showLocal(model id: String?) {
        focusLocalModel = id
        pane = .local
        SettingsTabSelection.shared.selectedTab = AISettingsView.tabID
    }

    func showCloud(account id: String?) {
        focusAccount = id
        pane = .cloud
        SettingsTabSelection.shared.selectedTab = AISettingsView.tabID
    }
}
