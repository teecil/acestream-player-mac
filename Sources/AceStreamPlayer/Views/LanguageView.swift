import SwiftUI

/// First screen on first launch: pick English or Russian. Everything after it is as before.
struct LanguageView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a language")
                    .font(.system(size: 15, weight: .semibold))
                Text("Выберите язык")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    if language == AppLanguage.systemGuess {
                        Button { model.setLanguage(language) } label: { label(language) }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.accent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button { model.setLanguage(language) } label: { label(language) }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("You can change it any time with the EN | RU switch in the top-right corner.")
                Text("Поменять можно в любой момент переключателем EN | RU в правом верхнем углу.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func label(_ language: AppLanguage) -> some View {
        Text(language.nativeName)
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 34)
    }
}
