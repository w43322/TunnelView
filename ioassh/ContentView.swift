import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var browser = BrowserState()

    var body: some View {
        TabView(selection: $model.selectedTab) {
            BrowserPage(
                url: model.browserURL,
                sessionID: model.browserSessionID,
                browser: browser
            )
            .tabItem { Label("浏览器", systemImage: "globe") }
            .tag(AppModel.Tab.browser)

            ConfigurationPage(model: model)
                .tabItem { Label("配置", systemImage: "gearshape") }
                .tag(AppModel.Tab.configuration)
        }
#if os(macOS)
        .frame(minWidth: 680, minHeight: 520)
#endif
    }
}

#Preview {
    ContentView()
}
