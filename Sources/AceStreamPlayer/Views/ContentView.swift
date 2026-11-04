import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            if Layout.solidBackground {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectBackground()
            }
            VStack(alignment: .leading, spacing: 22) {
                HeaderView()
                Group {
                    switch model.phase {
                    case .launching:
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(.top, 60)
                    case .chooseLanguage:
                        LanguageView()
                    case .setup:
                        SetupView()
                    case .idle, .starting, .playing, .stopping:
                        PlaybackView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
            }
            // Views whose inputs didn't change would keep text in the old language; a new
            // identity per language makes SwiftUI rebuild all of them.
            .id(model.language)
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 22)
        }
        .frame(width: Layout.windowSize.width)
        .frame(minHeight: Layout.windowSize.height, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.error)
    }
}
