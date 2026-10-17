import SwiftUI

struct ContentView: View {
    var body: some View {
        HamsterCanvas()
            .frame(minWidth: 320, minHeight: 320 * 550 / 742)
            .background(Color(red: 40 / 255, green: 40 / 255, blue: 40 / 255))
    }
}
