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

            UpdatesSection()

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
        .frame(width: 270)
    }
}

/// Auto-check switch (off by default) and, when it's off, a manual "Check for updates" button.
struct UpdatesSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.autoUpdateCheck) {
                Text(tr("Check for updates automatically", "Проверять обновления автоматически"))
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if !model.autoUpdateCheck {
                Button(tr("Check for updates", "Проверить обновления")) { model.checkForUpdates() }
                    .controlSize(.small)
                    .disabled(model.updateCheckState == .checking)
            }

            status

            Text(tr("Version \(UpdateChecker.currentVersion)", "Версия \(UpdateChecker.currentVersion)"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let update = model.availableUpdate {
            HStack(spacing: 8) {
                Text(tr("Version \(update.version) is available", "Доступна версия \(update.version)"))
                    .font(.system(size: 11, weight: .medium))
                Button(tr("Download", "Скачать")) { model.openUpdatePage() }
                    .controlSize(.small)
            }
        } else {
            switch model.updateCheckState {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(tr("Checking…", "Проверяем…")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .upToDate:
                Text(tr("You have the latest version.", "У вас последняя версия."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .failed:
                Text(tr("Couldn't check. Try again later.", "Не удалось проверить. Попробуйте позже."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        }
    }
}

/// Shown under the header when a newer version exists. Can be closed; never asks anything.
struct UpdateBanner: View {
    @EnvironmentObject private var model: AppModel
    let release: UpdateRelease

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Brand.accent)
            Text(tr("Version \(release.version) is available", "Доступна версия \(release.version)"))
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Button(tr("Download", "Скачать")) { model.openUpdatePage() }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .controlSize(.small)
            Button {
                model.updateBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(tr("Hide", "Скрыть"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CardBackground(tint: Brand.accent, fillOpacity: 0.07))
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
