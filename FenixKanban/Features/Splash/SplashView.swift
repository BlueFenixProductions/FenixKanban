import SwiftUI

struct SplashView: View {
    let phase: SplashState.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color("SplashBackground")
                .ignoresSafeArea()
            Image("SplashLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .scaleEffect(scale)
                .animation(.easeInOut(duration: 0.45), value: phase)
        }
        // .done is a safety net: RootView removes this view at .done, but
        // if removal is briefly delayed the splash stays invisible.
        .opacity(phase == .fading || phase == .done ? 0 : 1)
        .animation(.easeOut(duration: 0.65), value: phase)
    }

    private var scale: CGFloat {
        // Suppress the pulse under Reduce Motion; the opacity fade still plays.
        if reduceMotion { return 1.0 }
        switch phase {
        case .pulsing: return 1.05
        case .fading, .done: return 1.0
        }
    }
}

#Preview("Pulsing") { SplashView(phase: .pulsing) }
#Preview("Fading")  { SplashView(phase: .fading)  }
