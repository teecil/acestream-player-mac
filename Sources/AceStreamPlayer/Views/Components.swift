import AppKit
import SwiftUI

enum Brand {
    static let accent = Color(red: 0.91, green: 0.26, blue: 0.22)
    static let gradientTop = Color(red: 1.00, green: 0.50, blue: 0.25)
    static let gradientBottom = Color(red: 0.84, green: 0.14, blue: 0.29)
}

/// Translucent window background, like native macOS utility windows.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Rounded "card" background used for grouped content.
struct CardBackground: View {
    var tint: Color = .primary
    var fillOpacity: Double = 0.045

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.opacity(fillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(fillOpacity * 2), lineWidth: 1)
            )
    }
}

/// The app glyph drawn in SwiftUI (matches the generated app icon).
struct AppGlyph: View {
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
            .fill(LinearGradient(colors: [Brand.gradientTop, Brand.gradientBottom],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.40, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.03)
            )
            .frame(width: size, height: size)
            .shadow(color: Brand.gradientBottom.opacity(0.30), radius: 6, y: 3)
    }
}

extension StatusIndicator {
    var text: String {
        switch self {
        case .checking: return tr("Checking…", "Проверяем…")
        case .needsSetup: return tr("First-time setup needed", "Нужна первоначальная настройка")
        case .configuring: return tr("Setting up", "Идёт настройка")
        case .ready: return tr("Ready", "Готово к запуску")
        case .preparing: return tr("Preparing the stream", "Подготавливаем трансляцию")
        case .live: return tr("Live", "Идёт трансляция")
        case .stopping: return tr("Stopping…", "Выключаем…")
        case .problem: return tr("Needs attention", "Требуется внимание")
        }
    }

    var color: Color {
        switch self {
        case .checking, .stopping: return .gray
        case .needsSetup, .configuring, .preparing: return .orange
        case .ready: return .green
        case .live: return .red
        case .problem: return .red
        }
    }

    var pulses: Bool {
        switch self {
        case .checking, .configuring, .preparing, .live: return true
        default: return false
        }
    }
}

struct StatusPill: View {
    let indicator: StatusIndicator

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(indicator.color)
                .symbolEffect(.pulse, options: .repeating, isActive: indicator.pulses)
            Text(indicator.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(indicator.color.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}

struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AppGlyph(size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text("AceStream Player")
                    .font(.system(size: 22, weight: .semibold))
                if model.phase != .chooseLanguage {
                    StatusPill(indicator: model.statusIndicator)
                }
            }
            Spacer(minLength: 0)
            if model.phase != .chooseLanguage {
                LanguageSwitch()
                    .padding(.top, 4)
            }
        }
    }
}

/// Small EN | RU switch in the top-right corner of the window.
struct LanguageSwitch: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Picker(tr("Language", "Язык"), selection: Binding(
            get: { L10n.current },
            set: { model.setLanguage($0) }
        )) {
            ForEach(AppLanguage.allCases, id: \.self) { language in
                Text(language.shortCode).tag(language)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help(tr("Interface language", "Язык интерфейса"))
    }
}

struct ErrorCard: View {
    @EnvironmentObject private var model: AppModel
    let error: AppError
    var showsActions = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(error.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(error.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsActions && error.recovery != .dismissOnly {
                    HStack(spacing: 10) {
                        switch error.recovery {
                        case .retry:
                            Button(tr("Retry", "Повторить")) { model.retry() }
                        case .setup:
                            Button(tr("Install components", "Установить компоненты")) { model.goToSetup() }
                        case .dismissOnly:
                            EmptyView()
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.error = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(tr("Hide", "Скрыть"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(tint: .orange, fillOpacity: 0.09))
    }
}

struct HintRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum Formatting {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// The engine reports speed in KB/s.
    static func speed(_ kilobytesPerSecond: Int) -> String {
        bytes(Int64(kilobytesPerSecond) * 1024) + tr("/s", "/с")
    }
}

enum Layout {
    /// Fits comfortably on a 13" MacBook Air without scrolling.
    static let windowSize = CGSize(width: 480, height: 600)
    /// Screenshot mode: the translucent window material can't be captured offscreen.
    static var solidBackground = false
}

/// Shown while things install or start: Docker, IINA and macOS dialogs pop up on their own,
/// and people tend to close them.
struct DontTouchNote: View {
    var extra: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Some windows may pop up on their own. That's normal, don't touch anything.",
                        "Что-то может открываться, это нормально, ничего не трогайте."))
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let extra {
                    Text(extra)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(tint: .orange, fillOpacity: 0.08))
    }
}
