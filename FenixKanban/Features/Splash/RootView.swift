import SwiftUI

struct RootView: View {
    @Bindable var navigator: NavigationModel

    #if os(iOS)
    @State private var splashState = SplashState()
    #endif

    var body: some View {
        #if os(iOS)
        ZStack {
            ContentView(navigator: navigator)
                .opacity(splashState.phase == .done ? 1 : 0)
                .animation(.easeIn(duration: 0.65), value: splashState.phase)

            if splashState.phase != .done {
                SplashView(phase: splashState.phase)
                    .task { await splashState.start() }
            }
        }
        #else
        ContentView(navigator: navigator)
        #endif
    }
}
