import SwiftUI

/// Gear button in the window header. Opens a small settings popover.
struct SettingsButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Settings", "Настройки"))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SettingsPopover(close: { isOpen = false })
                .environmentObject(model)
        }
    }
}

struct SettingsPopover: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Settings", "Настройки"))
                .font(.system(size: 13, weight: .semibold))

            HStack {
                Text(tr("Language", "Язык"))
                    .font(.system(size: 12))
                Spacer()
                // A drop-down, so more languages can be added to AppLanguage later.
                Picker("", selection: Binding(
                    get: { model.language },
                    set: { model.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            Divider()

            Button(role: .destructive) {
                close()
                model.uninstallError = nil
                model.showingUninstall = true
            } label: {
                Label(tr("Uninstall…", "Удалить…"), systemImage: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(!model.canUninstall)
        }
        .padding(16)
        .frame(width: 250)
    }
}

/// Asks what to remove. Everything is removed unless the user explicitly opts to keep something.
struct UninstallView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keepSomething = false
    @State private var options = UninstallOptions()

    private var running: Bool { model.uninstallStatus != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Uninstall", "Удаление"))
                    .font(.system(size: 15, weight: .semibold))
                Text(tr("Everything below will be removed from this Mac together with its data. After that you can install again from scratch.",
                        "Всё, что ниже, будет удалено с этого Mac вместе с данными. После этого можно установить всё заново с нуля."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                item($options.player, tr("IINA video player", "Видеоплеер IINA"),
                     tr("The app that shows the video", "Программа, которая показывает видео"))
                item($options.docker, "Docker Desktop",
                     tr("Runs the stream engine; removed with all its data", "Запускает движок трансляций; удаляется со всеми данными"))
                item($options.app, "AceStream Player",
                     tr("This app, its settings and the stream engine", "Это приложение, его настройки и движок трансляций"))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardBackground())
            .disabled(!keepSomething || running)

            Toggle(isOn: $keepSomething) {
                Text(tr("I want to keep something and accept an incomplete uninstall",
                        "Я хочу что-то оставить и согласен с неполным удалением программы"))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .disabled(running)
            .onChange(of: keepSomething) { _, keep in
                if !keep { options = UninstallOptions() }
            }

            if keepSomething {
                Label(tr("If you remove anything, the app will no longer work.",
                         "Если вы удалите что-то, то программа больше не будет работать."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            if let status = model.uninstallStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if let error = model.uninstallError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(tr("Cancel", "Отмена")) { model.showingUninstall = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button(tr("Uninstall", "Удалить"), role: .destructive) { model.uninstall(options) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(running || options.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 430)
        .interactiveDismissDisabled(running)
    }

    private func item(_ isOn: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }
}
