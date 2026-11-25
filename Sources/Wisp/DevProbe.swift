import AppKit
import WebKit

/// Development: `--url <address>` opens a page; `--probe <file.js> --probe-at 6,12` runs a script on the
/// page at those seconds and prints what it returns; `--command-at "15:next,20:seek=30"` sends commands
/// the way media keys and Monobrow do; `--quit-after <sec>`.
enum DevProbe {
    static func run(_ app: AppDelegate) {
        let after: (Double, @escaping () -> Void) -> Void = { t, f in DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        if let s = Args.value("--quit-after"), let t = Double(s) { after(t) { NSApp.terminate(nil) } }
        if let u = Args.value("--url"), let url = URL(string: u) {
            after(Double(Args.value("--url-at") ?? "3") ?? 3) { app.player.webView.load(URLRequest(url: url)) }
        }
        if let list = Args.value("--command-at") {
            for entry in list.split(separator: ",") {
                let parts = entry.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let t = Double(parts[0]) else { continue }
                let cmd = parts[1].split(separator: "=")
                after(t) {
                    Log.debug("command \(cmd[0])")
                    app.player.command(String(cmd[0]), cmd.count > 1 ? Double(cmd[1]) : nil)
                }
            }
        }
        if let out = Args.value("--snapshot") {
            // A picture of the page as WebKit draws it, without showing the window.
            let times = (Args.value("--snapshot-at") ?? "15").split(separator: ",").compactMap { Double($0) }
            for (i, t) in times.enumerated() {
                after(t) {
                    app.player.webView.takeSnapshot(with: nil) { image, error in
                        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:]) else { Log.debug("snapshot failed: \(String(describing: error))"); return }
                        let path = times.count > 1 ? out.replacingOccurrences(of: ".png", with: "-\(i + 1).png") : out
                        try? png.write(to: URL(fileURLWithPath: path))
                        Log.debug("snapshot \(path) \(Int(image.size.width))x\(Int(image.size.height))")
                    }
                }
            }
        }
        if let list = Args.value("--now-playing-at") {
            // What WebKit hands to the system's Now Playing (private WebKit call, development only).
            typealias Reply = @convention(block) (Bool, Bool, NSString?, Double, Double, Int) -> Void
            typealias Request = @convention(c) (AnyObject, Selector, Reply) -> Void
            let selector = NSSelectorFromString("_requestActiveNowPlayingSessionInfo:")
            for t in list.split(separator: ",").compactMap({ Double($0) }) {
                after(t) {
                    let view = app.player.webView
                    guard view.responds(to: selector) else { Log.debug("now playing: not available"); return }
                    let request = unsafeBitCast(view.method(for: selector), to: Request.self)
                    let reply: Reply = { active, registered, title, duration, elapsed, _ in
                        Log.debug("now playing@\(t): active \(active), registered \(registered), \"\(title ?? "")\" \(Int(elapsed))/\(Int(duration)) s")
                    }
                    request(view, selector, reply)
                    typealias Names = @convention(block) (NSString?, NSString?) -> Void
                    typealias AskNames = @convention(c) (AnyObject, Selector, Names) -> Void
                    let namesSelector = NSSelectorFromString("_nowPlayingMediaTitleAndArtist:")
                    if view.responds(to: namesSelector) {
                        let ask = unsafeBitCast(view.method(for: namesSelector), to: AskNames.self)
                        let names: Names = { title, artist in Log.debug("now playing names@\(t): \"\(title ?? "")\" by \"\(artist ?? "")\"") }
                        ask(view, namesSelector, names)
                    }
                }
            }
        }
        guard let path = Args.value("--probe"), let source = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let times = (Args.value("--probe-at") ?? "8").split(separator: ",").compactMap { Double($0) }
        for t in times {
            after(t) {
                app.player.webView.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let value): Log.debug("probe@\(t): \(value)")
                    case .failure(let error): Log.debug("probe@\(t) failed: \(error)")
                    }
                }
            }
        }
    }
}
