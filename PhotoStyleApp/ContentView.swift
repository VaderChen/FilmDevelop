import SwiftUI

struct ContentView: View {
    @ObservedObject var coordinator: PhotoStyleWebCoordinator

    var body: some View {
        PhotoStyleWebView(coordinator: coordinator)
            .frame(minWidth: 1024, minHeight: 640)
    }
}
