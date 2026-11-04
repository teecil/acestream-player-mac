import SwiftUI

/// First-run screen: installs IINA, Docker Desktop and the engine with one button.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Первоначальная настройка")
                    .font(.system(size: 15, weight: .semibold))
                Text("Нужны три бесплатных компонента. Они устанавливаются один раз — потом трансляции будут запускаться сразу.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(model.setupItems) { item in
                    SetupRow(item: item)
                    if item.kind != SetupItem.Kind.allCases.last {
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(CardBackground())

            if model.needsAdminForSetup && !model.setupRunning && model.error == nil {
                HintRow(symbol: "lock.shield",
                        text: "macOS попросит пароль от этого Mac — он нужен, чтобы установить Docker Desktop. Загрузка — около 1 ГБ.")
            }

            Button {
                model.runSetup()
            } label: {
                HStack(spacing: 8) {
                    if model.setupRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text(buttonTitle).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
            .controlSize(.large)
            .disabled(model.setupRunning)
            .keyboardShortcut(.defaultAction)

            if let error = model.error {
                ErrorCard(error: error, showsActions: false)
            }
        }
    }

    private var buttonTitle: String {
        if model.setupRunning { return "Настраиваем…" }
        if model.error != nil { return "Повторить" }
        return model.setupItems.allSatisfy { $0.status == .installed } ? "Продолжить" : "Установить и настроить"
    }
}

struct SetupRow: View {
    let item: SetupItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 16))
                .foregroundStyle(Brand.accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.accent.opacity(0.10)))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.kind.title)
                    .font(.system(size: 13, weight: .semibold))
                switch item.status {
                case .working(let text, let fraction):
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let fraction {
                        ProgressView(value: min(max(fraction, 0), 1))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(Brand.accent)
                    }
                case .failed(let text):
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                case .pending, .installed:
                    Text(item.kind.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case .installed:
            Label("Готово", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 17))
                .foregroundStyle(.green)
                .help("Установлено")
        case .working(_, let fraction):
            if fraction == nil {
                ProgressView().controlSize(.small)
            } else {
                Text("\(Int((fraction ?? 0) * 100))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.red)
        case .pending:
            Text("Нужно установить")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
