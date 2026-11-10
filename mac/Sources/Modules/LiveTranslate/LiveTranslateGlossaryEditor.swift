import SwiftUI

/// 专有名词编辑表：每行左边原文、右边译名（可留空 = 翻译时保持原样）。回车从原文跳到译名，
/// 再回车到下一行（没有就新起一行）。存储仍是 `livetranslate.vocabulary` 一个字符串（格式见
/// `TranslationGlossary`），旧版逗号分隔的内容照常读进来。
///
/// 整张表放在一个 Form 行里：onAppear / onChange 只挂一次，不会被拆到每一行上重复执行。
struct LiveTranslateGlossaryEditor: View {
    @AppStorage(SpeechSettings.vocabularyKey) private var stored = ""
    @State private var entries: [GlossaryEntry] = []
    @State private var loaded = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case source(UUID)
        case target(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("livetranslate.glossary.sourceHeader")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 14, height: 1)
                Text("livetranslate.glossary.targetHeader")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 20, height: 1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach($entries) { $entry in
                HStack(spacing: 8) {
                    TextField("livetranslate.glossary.sourceHeader", text: $entry.source,
                              prompt: Text("livetranslate.glossary.sourcePlaceholder"))
                        .focused($focus, equals: .source(entry.id))
                        .onSubmit { focus = .target(entry.id) }
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    TextField("livetranslate.glossary.targetHeader", text: $entry.target,
                              prompt: Text("livetranslate.glossary.targetPlaceholder"))
                        .focused($focus, equals: .target(entry.id))
                        .onSubmit { advance(from: entry.id) }
                    Button {
                        remove(entry.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 20)
                    .help(L("livetranslate.glossary.remove"))
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button {
                    append()
                } label: {
                    Label("livetranslate.glossary.add", systemImage: "plus")
                }
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            entries = TranslationGlossary.parse(stored)
            if entries.isEmpty { entries = [GlossaryEntry(source: "")] }
        }
        .onChange(of: entries) { _, newValue in
            stored = TranslationGlossary.serialize(newValue)
        }
    }

    private var summary: String {
        let valid = entries.filter { !$0.source.trimmingCharacters(in: .whitespaces).isEmpty }
        let withTarget = valid.filter { !$0.target.trimmingCharacters(in: .whitespaces).isEmpty }.count
        var text = L("livetranslate.glossary.summary \(valid.count) \(withTarget)")
        if valid.count > TranslationGlossary.maxEntries {
            text += " · " + L("livetranslate.glossary.overLimit \(TranslationGlossary.maxEntries)")
        }
        return text
    }

    /// 译名格里回车：到下一行的原文格；已是最后一行就新起一行。
    private func advance(from id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if index + 1 < entries.count {
            focus = .source(entries[index + 1].id)
        } else {
            append()
        }
    }

    private func append() {
        let entry = GlossaryEntry(source: "")
        entries.append(entry)
        // 新行要先渲染出来才能聚焦。
        DispatchQueue.main.async { focus = .source(entry.id) }
    }

    private func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if entries.isEmpty { entries = [GlossaryEntry(source: "")] }
    }
}
