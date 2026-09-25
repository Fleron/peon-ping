import AppKit
import UserNotifications

struct PostArgs {
    let title: String
    let message: String
    let subtitle: String?
    let group: String?
    let execute: String?
}

func parseArgs(_ argv: [String]) -> PostArgs? {
    var values: [String: String] = [:]
    var i = 1
    while i < argv.count {
        let key = argv[i]
        if key.hasPrefix("-"), i + 1 < argv.count {
            values[String(key.dropFirst())] = argv[i + 1]
            i += 2
        } else {
            i += 1
        }
    }
    guard let title = values["title"] ?? values["message"] else { return nil }
    return PostArgs(
        title: title,
        message: values["message"] ?? "",
        subtitle: values["subtitle"],
        group: values["group"],
        execute: values["execute"]
    )
}

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let post: PostArgs?
    private var pendingWork = 0

    init(post: PostArgs?) {
        self.post = post
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch Services relaunches the app to deliver a click; with no click
        // (or a double-click from Finder) there is nothing to wait for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) }
        guard let post else { return }
        pendingWork += 1
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            guard granted else {
                FileHandle.standardError.write(Data("peon-notify: not authorized \(error?.localizedDescription ?? "")\n".utf8))
                DispatchQueue.main.async { self.finish() }
                return
            }
            self.send(post)
        }
    }

    private func send(_ p: PostArgs) {
        let content = UNMutableNotificationContent()
        content.title = p.title
        content.body = p.message
        if let subtitle = p.subtitle { content.subtitle = subtitle }
        if let execute = p.execute { content.userInfo = ["execute": execute] }
        content.sound = nil
        if let group = p.group { content.threadIdentifier = group }
        let request = UNNotificationRequest(identifier: p.group ?? UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                FileHandle.standardError.write(Data("peon-notify: \(error.localizedDescription)\n".utf8))
            }
            DispatchQueue.main.async { self.finish() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        pendingWork += 1
        let command = response.notification.request.content.userInfo["execute"] as? String
        DispatchQueue.global().async {
            if let command, !command.isEmpty {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", command]
                try? process.run()
                process.waitUntilExit()
            }
            DispatchQueue.main.async {
                completionHandler()
                self.finish()
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    private func finish() {
        pendingWork -= 1
        if pendingWork <= 0 { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let delegate = Delegate(post: parseArgs(CommandLine.arguments))
UNUserNotificationCenter.current().delegate = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
