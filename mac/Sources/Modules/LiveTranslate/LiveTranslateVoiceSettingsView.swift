import AVFoundation
import AppKit
import SwiftUI

/// 实时翻译设置页的「朗读译文」一节（docs/live-translate-voice/DESIGN.md）。
struct LiveTranslateVoiceSection: View {
    @AppStorage(LiveTranslateVoiceSettings.enabledKey) private var enabled = false
    @AppStorage(LiveTranslateVoiceSettings.meetingDeviceKey) private var meetingDevice = ""
    @AppStorage(LiveTranslateVoiceSettings.speakersKey) private var speakers = true
    @AppStorage(LiveTranslateVoiceSettings.mixOriginalKey) private var mixOriginal = false
    @AppStorage(LiveTranslateVoiceSettings.keepListeningKey) private var keepListening = false
    @AppStorage(LiveTranslateVoiceSettings.rateKey) private var rate = LiveTranslateVoiceSettings.defaultRate
    @State private var devices: [LiveTranslateAudioDevice] = []

    /// 会读到的语言（每种选一个音色）。
    private let languages: [TranslationLanguage]
    /// 改了要重开实时翻译的设置（输出设备、开关）。音色和语速每句现读，不用重开。
    private let onChange: () -> Void

    init(languages: [TranslationLanguage], onChange: @escaping () -> Void) {
        self.languages = languages
        self.onChange = onChange
    }

    var body: some View {
        Section("livetranslate.voice.section") {
            Toggle("livetranslate.voice.enabled", isOn: $enabled)
                .onChange(of: enabled) { _, _ in onChange() }
            Text("livetranslate.voice.help")
                .font(.caption)
                .foregroundStyle(.secondary)
            if enabled {
                if LiveTranslateDriver.bundledURL != nil {
                    LiveTranslateDriverRow { uid in
                        refreshDevices()
                        if let uid {
                            meetingDevice = uid
                        } else if meetingDevice == LiveTranslateDriver.deviceUID {
                            meetingDevice = ""
                        }
                        onChange()
                    }
                }
                Picker("livetranslate.voice.meeting", selection: $meetingDevice) {
                    Text("livetranslate.voice.meetingOff").tag("")
                    ForEach(devices) { device in
                        Text(verbatim: device.name).tag(device.uid)
                    }
                }
                .onChange(of: meetingDevice) { _, _ in onChange() }
                if devices.isEmpty {
                    Text("livetranslate.voice.noVirtualDevice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if let device = devices.first(where: { $0.uid == meetingDevice }) {
                    Text(L("livetranslate.voice.meetingHint \(device.name)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 不送会议时总是从音响 / 耳机播放；外放 / 原声两个开关只在送会议时才有意义。
                if devices.contains(where: { $0.uid == meetingDevice }) {
                    Toggle("livetranslate.voice.speakers", isOn: $speakers)
                        .onChange(of: speakers) { _, _ in onChange() }
                    Toggle("livetranslate.voice.mixOriginal", isOn: $mixOriginal)
                        .onChange(of: mixOriginal) { _, _ in onChange() }
                }
                // 麦克风 + 外放时读的那几秒暂停识别（防回授）；戴耳机打开它就不暂停。
                if meetingDevice.isEmpty || speakers {
                    Toggle("livetranslate.voice.keepListening", isOn: $keepListening)
                        .onChange(of: keepListening) { _, _ in onChange() }
                    Text("livetranslate.voice.keepListeningHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(languages) { language in
                    LiveTranslateVoicePicker(language: language)
                }
                HStack {
                    Text("livetranslate.voice.rate")
                    Slider(value: $rate, in: 0.35...0.7)
                }
                Button("livetranslate.voice.moreVoices") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                Text("livetranslate.voice.feedbackHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refreshDevices)
        // 装好虚拟声卡 / 下载完音色回来，窗口重新激活时刷新。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDevices()
        }
    }

    private func refreshDevices() {
        devices = LiveTranslateAudioDevice.virtualDevices()
    }
}

/// 「Baobox 同传」虚拟麦克风：安装 / 卸载（要管理员密码）。`onChange(uid)`：装好且设备出现了给它的 UID，
/// 卸载或没加载起来给 nil。
private struct LiveTranslateDriverRow: View {
    let onChange: (String?) -> Void
    @State private var installed = LiveTranslateDriver.isInstalled
    @State private var working = false
    @State private var message: String?

    init(onChange: @escaping (String?) -> Void) {
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("livetranslate.voice.driverTitle")
                    Text(installed ? "livetranslate.voice.driverInstalled" : "livetranslate.voice.driverNotInstalled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                } else if installed {
                    Button("livetranslate.voice.driverUninstall", role: .destructive) { run(install: false) }
                } else {
                    Button("livetranslate.voice.driverInstall") { run(install: true) }
                }
            }
            if let message {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run(install: Bool) {
        working = true
        message = nil
        Task {
            let error = install ? await LiveTranslateDriver.install() : await LiveTranslateDriver.uninstall()
            var uid: String?
            if error == nil, install {
                uid = await LiveTranslateDriver.waitForDevice()
                if uid == nil { message = L("livetranslate.voice.driverNotLoaded") }
            }
            if let error, !error.isEmpty {
                message = L("livetranslate.voice.driverFailed \(error)")
            }
            installed = LiveTranslateDriver.isInstalled
            working = false
            // 音频服务重启过：正在跑的实时翻译要重开才能接上新设备。
            if error == nil { onChange(uid) }
        }
    }
}

/// 某种语言的音色选择 + 试听。
private struct LiveTranslateVoicePicker: View {
    let language: TranslationLanguage
    @AppStorage private var identifier: String
    @State private var voices: [AVSpeechSynthesisVoice] = []

    init(language: TranslationLanguage) {
        self.language = language
        _identifier = AppStorage(wrappedValue: "", LiveTranslateVoiceSettings.voiceKey(language))
    }

    var body: some View {
        HStack {
            Picker(L("livetranslate.voice.voiceFor \(language.endonym)"), selection: $identifier) {
                Text("livetranslate.voice.voiceDefault").tag("")
                ForEach(voices, id: \.identifier) { voice in
                    Text(verbatim: Self.label(voice)).tag(voice.identifier)
                }
            }
            Button("livetranslate.voice.preview") {
                LiveTranslateVoicePreview.play(language: language)
            }
        }
        .onAppear {
            voices = LiveTranslateVoiceSettings.voices(for: language)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            voices = LiveTranslateVoiceSettings.voices(for: language)
        }
    }

    private static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "\(voice.name)（\(L("livetranslate.voice.qualityPremium"))）"
        case .enhanced: return "\(voice.name)（\(L("livetranslate.voice.qualityEnhanced"))）"
        default: return voice.name
        }
    }
}

/// 试听：用选定的音色和语速读一句示例（从音响播放）。
@MainActor
enum LiveTranslateVoicePreview {
    /// 必须常驻持有：中途释放会静音。
    private static let synthesizer = AVSpeechSynthesizer()

    static func play(language: TranslationLanguage) {
        synthesizer.stopSpeaking(at: .immediate)
        // 示例句是要读出来的内容，按语言写死（不是界面文案）。
        let sample: String
        if language.isChinese {
            sample = "你好，这是实时翻译朗读译文的效果。"
        } else if language.code == TranslationLanguage.english.code {
            sample = "Hello, this is how live translation sounds when it is read aloud."
        } else {
            sample = language.endonym
        }
        let utterance = AVSpeechUtterance(string: sample)
        utterance.voice = LiveTranslateVoiceSettings.voice(for: language)
        utterance.rate = Float(LiveTranslateVoiceSettings.rate)
        synthesizer.speak(utterance)
    }
}
