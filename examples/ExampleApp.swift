import SwiftUI
import Watchtower

@main
struct ExampleApp: App {
    init() {
        var c = Config(key: "<publishable-key>", service: "example-ios")
        c.endpoint = "https://<your-edge>"
        Watchtower.start(c)
    }

    var body: some Scene { WindowGroup { Text("Hello") } }
}
