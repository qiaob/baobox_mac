import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// 嵌在确认卡片里的 Touch ID（TECH_DESIGN.md §5.6）：绑着这个 context，验证时提示在这里显示、不弹系统对话框。
struct TouchIDView: NSViewRepresentable {
    let authContext: LAContext

    /// 控件尺寸决定画多大（mini 16 / small 32 / regular 64 / large 128 点，实测），不跟外面给的 frame 走。
    /// large 塞进小框会溢出盖住文字（2026-11-08 用户截图）；用 small，和原来的指纹图标差不多大。
    static let side: CGFloat = 32

    func makeNSView(context: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: authContext, controlSize: .small)
    }

    func updateNSView(_ nsView: LAAuthenticationView, context: Context) {}
}

/// 休息画面中央的卡片：标题、大字倒计时、一句话、按钮（技术设计 §5）。
struct BreakInfoView: View {
    @ObservedObject var model: BreakStageModel

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: headline)
                .font(.system(size: 21, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if model.confirming {
                // 结束前确认是本人（TECH_DESIGN.md §5.6）：指纹验证就嵌在这张卡片里。
                if let auth = model.authContext {
                    TouchIDView(authContext: auth)
                        .frame(width: TouchIDView.side, height: TouchIDView.side)
                        .id(ObjectIdentifier(auth))
                        .padding(.vertical, 6)
                } else {
                    Image(systemName: "touchid")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 2)
                }
                Text(verbatim: L("focus.break.confirmHint \(model.confirmLeft)"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.finished {
                Text(verbatim: FocusText.countdown(model.remaining))
                    .font(.system(size: 52, weight: .light, design: .rounded).monospacedDigit())
                if !model.message.isEmpty {
                    Text(verbatim: model.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .frame(minWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(model.infoVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: model.infoVisible)
    }

    private var headline: String {
        if model.confirming {
            return model.confirmSkipping ? L("focus.break.confirmSkipTitle") : L("focus.break.confirmTitle")
        }
        if model.finished { return L("focus.break.done") }
        return model.nudge ?? model.title
    }

    @ViewBuilder
    private var buttons: some View {
        if model.holdToSkip {
            BreakHoldToSkip(onSkip: model.onSkip)
        } else {
            Button(L("focus.break.skip")) { model.onSkip() }
                .controlSize(.large)
        }
    }
}

/// 标准 / 严格档的逃生口：长按 3 秒才跳过，按住时进度条走满。
struct BreakHoldToSkip: View {
    let onSkip: () -> Void
    @State private var pressing = false

    var body: some View {
        Text("focus.break.holdToSkip")
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: pressing ? geo.size.width : 0)
                            .animation(pressing ? .linear(duration: 3) : .easeOut(duration: 0.2), value: pressing)
                    }
                }
            )
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: 3, maximumDistance: 40, perform: onSkip,
                                onPressingChanged: { pressing = $0 })
    }
}

/// 副屏中央的小字倒计时。
struct BreakMiniView: View {
    @ObservedObject var model: BreakStageModel

    var body: some View {
        VStack(spacing: 4) {
            Text(verbatim: model.confirming ? L("focus.break.confirmMini")
                 : (model.finished ? L("focus.break.done") : L("focus.break.mini")))
                .font(.system(size: 16, weight: .medium))
            if !model.finished, !model.confirming {
                Text(verbatim: FocusText.countdown(model.remaining))
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(model.infoVisible ? 1 : 0)
    }
}
