import AceCore
import SwiftUI

/// Main screen: link field, the one big button and the current state.
struct PlaybackView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var linkFocused: Bool

    /// The field stays usable while a stream is starting or playing, so another link can be tried.
    private var editable: Bool {
        model.phase == .idle || model.phase == .starting || model.phase == .playing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ссылка на трансляцию")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                linkField
                if model.phase == .playing || model.phase == .starting {
                    Text(model.phase == .playing
                         ? "Можно вставить другую ссылку и нажать «Открыть» — текущая будет идти, пока новая не запустится."
                         : "Не запускается? Вставьте другую ссылку и нажмите «Открыть».")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PrimaryButton()

            if let error = model.error {
                ErrorCard(error: error)
                    .transition(.opacity)
            }

            switch model.phase {
            case .starting:
                StepsView(current: model.step, detail: model.stepDetail)
                    .transition(.opacity)
            case .stopping:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Выключаем трансляцию и освобождаем ресурсы…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            case .playing:
                if let detail = model.switchDetail {
                    SwitchingCard(detail: detail)
                        .transition(.opacity)
                }
                LiveCard(stats: model.stats)
                    .transition(.opacity)
            default:
                if model.error == nil {
                    IdleHints(notice: model.notice)
                        .transition(.opacity)
                }
            }
            if model.phase == .playing, model.switchDetail == nil, model.error == nil, let notice = model.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { if model.phase == .idle { linkFocused = true } }
    }

    private var linkField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("acestream://…", text: $model.link)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($linkFocused)
                .disabled(!editable)
                .onSubmit { model.submitLink() }
            if editable && !model.link.isEmpty {
                Button {
                    model.link = ""
                    model.error = nil
                    linkFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Очистить")
            }
            if editable {
                Button("Вставить") {
                    model.pasteFromClipboard()
                    model.error = nil
                }
                .controlSize(.small)
                .help("Вставить ссылку из буфера обмена")
            }
            if model.canOpenOtherLink {
                Button("Открыть") { model.submitLink() }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
                    .controlSize(.small)
                    .help(model.phase == .playing
                          ? "Открыть эту ссылку. Текущая трансляция будет идти, пока новая не запустится."
                          : "Бросить текущую попытку и открыть эту ссылку")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(editable ? 1 : 0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(linkFocused ? Brand.accent.opacity(0.7) : Color.primary.opacity(0.12),
                              lineWidth: linkFocused ? 2 : 1)
        )
    }
}

/// Shown while a new link is being prepared next to the one that is playing.
struct SwitchingCard: View {
    @EnvironmentObject private var model: AppModel
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Открываем новую трансляцию")
                    .font(.system(size: 13, weight: .semibold))
                Text(detail + " Текущая продолжает идти.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Отменить") { model.cancelSwitch() }
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(tint: Brand.accent, fillOpacity: 0.07))
    }
}


struct PrimaryButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.phase {
        case .playing:
            Button { model.stopStream() } label: { label("Выключить", symbol: "stop.fill") }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
        case .starting:
            Button { model.cancelStart() } label: { label("Отменить", symbol: "xmark") }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        case .stopping:
            Button {} label: { label("Выключаем…", symbol: nil) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(true)
        default:
            Button { model.startStream() } label: { label("Запустить трансляцию", symbol: "play.fill") }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.link.trimmed.isEmpty)
        }
    }

    private func label(_ title: String, symbol: String?) -> some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol) }
            Text(title).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
    }
}

/// Progress through the four start-up stages.
struct StepsView: View {
    let current: AppModel.StartStep
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(AppModel.StartStep.allCases) { item in
                HStack(alignment: .top, spacing: 10) {
                    icon(for: item)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: item == current ? .semibold : .regular))
                            .foregroundStyle(item.rawValue > current.rawValue ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                        if item == current && !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    @ViewBuilder
    private func icon(for item: AppModel.StartStep) -> some View {
        if item.rawValue < current.rawValue {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.green)
        } else if item == current {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 15))
                .foregroundStyle(.quaternary)
        }
    }
}

struct LiveCard: View {
    let stats: EngineStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("LIVE")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.red))
                Text("Трансляция открыта в плеере")
                    .font(.system(size: 14, weight: .semibold))
            }
            HStack(spacing: 0) {
                metric("Источники", stats.map { "\($0.peers)" } ?? "—", symbol: "person.2.fill")
                metric("Скорость", stats.map { Formatting.speed($0.speedDown) } ?? "—", symbol: "arrow.down.circle.fill")
                metric("Получено", stats.map { Formatting.bytes($0.downloaded) } ?? "—", symbol: "tray.and.arrow.down.fill")
            }
            Text("Закончили смотреть? Нажмите «Выключить» — плеер закроется сам.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    private func metric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IdleHints: View {
    let notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            }
            HintRow(symbol: "doc.on.clipboard",
                    text: "Скопируйте ссылку acestream://… и вставьте её в поле выше.")
            HintRow(symbol: "play.circle",
                    text: "Нажмите «Запустить трансляцию» — приложение само всё подготовит и откроет видео (обычно 20–60 секунд).")
            HintRow(symbol: "leaf",
                    text: "Пока трансляция выключена, ничего лишнего не работает и не тратит память и батарею.")
            HintRow(symbol: "globe",
                    text: "Ссылки acestream:// в браузере тоже открываются в этом приложении.")
        }
        .padding(.top, 4)
    }
}
