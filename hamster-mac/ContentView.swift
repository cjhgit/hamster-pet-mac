import SwiftUI

struct ContentView: View {
    var body: some View {
        HamsterCanvas()
            .frame(minWidth: 320, minHeight: 320 * 212 / 282)
            .background(Color.clear)
    }
}
