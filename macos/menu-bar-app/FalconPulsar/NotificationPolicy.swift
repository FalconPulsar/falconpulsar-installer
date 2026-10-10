// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

import Foundation
import UserNotifications

/// What the person has said about QuickDock's notifications.
///
/// macOS delivers nothing until the app has asked and the person allowed it.
/// QuickDock never asked, so its "All containers are running" / "have stopped"
/// notices were handed to a center that dropped every one of them.
enum NoticePermission: Equatable {
    /// The system has not asked yet, or the person has not answered.
    case notAsked
    case allowed
    case refused

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional:
            self = .allowed
        case .notDetermined:
            self = .notAsked
        case .denied:
            self = .refused
        @unknown default:
            // A status this build does not know is not a promise of delivery,
            // and a failed action must not vanish into it.
            self = .refused
        }
    }
}

/// The two kinds of notice the menu-bar app gives.
enum Notice {
    /// The stack went from running to stopped, or back. The icon and the menu
    /// show it too; the notice is for someone not looking at the menu bar.
    case statusChange
    /// Start, Stop or Restart failed. The person asked for something and it
    /// did not happen, so this one must reach them.
    case actionFailure
}

enum NoticeDelivery: Equatable {
    case post
    case alert
    case drop
}

/// The rules, kept apart from AppDelegate so they can be tested without a
/// running app or a notification center.
enum NotificationPolicy {
    static func delivery(of notice: Notice, when permission: NoticePermission) -> NoticeDelivery {
        switch (notice, permission) {
        case (_, .allowed):
            return .post
        case (.actionFailure, _):
            // Not allowed, or not answered yet: an alert, so a failed Start is
            // never silent.
            return .alert
        case (.statusChange, _):
            // Not an alert: that would be a dialog every time the stack starts
            // or stops. The icon's dot already changed colour.
            return .drop
        }
    }

    /// The system shows its prompt only while the answer is unknown. After a
    /// refusal, asking again shows nothing and changes nothing; the way back
    /// is System Settings, which the menu offers instead.
    static func shouldAsk(_ permission: NoticePermission) -> Bool {
        permission == .notAsked
    }

    /// The menu offers "Turn On Notifications…" only after a refusal: before
    /// the person answers, the system's own prompt is the place to answer.
    static func offersTurnOn(_ permission: NoticePermission) -> Bool {
        permission == .refused
    }

    /// UNUserNotificationCenter raises an exception, rather than returning
    /// nil, in a process that is not an app bundle: the bare binary from
    /// `swift build` or the swiftc compile CI runs. Only the installed
    /// FalconPulsar Menu Bar.app may touch it.
    static func canUseNotificationCenter(bundleURL: URL, bundleIdentifier: String?) -> Bool {
        bundleURL.pathExtension == "app" && !(bundleIdentifier ?? "").isEmpty
    }
}

/// The part of UNUserNotificationCenter QuickDock uses, so the flow in
/// `Notices` runs in a test against a stand-in. Completions may arrive on
/// any thread.
protocol NoticeCenter: AnyObject {
    func readPermission(_ done: @escaping (NoticePermission) -> Void)
    /// Shows the system's prompt when the person has not answered yet.
    func requestPermission(_ done: @escaping () -> Void)
    /// `done(false)` when the system would not take the notification.
    func post(title: String, body: String, _ done: @escaping (Bool) -> Void)
}

extension UNUserNotificationCenter: NoticeCenter {
    func readPermission(_ done: @escaping (NoticePermission) -> Void) {
        getNotificationSettings { done(NoticePermission($0.authorizationStatus)) }
    }

    func requestPermission(_ done: @escaping () -> Void) {
        requestAuthorization(options: [.alert]) { _, _ in done() }
    }

    func post(title: String, body: String, _ done: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            done(error == nil)
        }
    }
}

/// Asks for permission, keeps up with what the person said, and delivers each
/// notice by NotificationPolicy. Every callback it makes runs through `onMain`.
final class Notices {
    private let center: NoticeCenter?
    private let onMain: (@escaping () -> Void) -> Void
    private let alert: (_ title: String, _ body: String) -> Void
    private let permissionChanged: (NoticePermission) -> Void

    /// `center` is nil outside the installed app (see
    /// NotificationPolicy.canUseNotificationCenter): nothing is asked or
    /// posted then, and a failure still gets its alert.
    init(center: NoticeCenter?,
         onMain: @escaping (@escaping () -> Void) -> Void,
         alert: @escaping (_ title: String, _ body: String) -> Void,
         permissionChanged: @escaping (NoticePermission) -> Void) {
        self.center = center
        self.onMain = onMain
        self.alert = alert
        self.permissionChanged = permissionChanged
    }

    /// At launch. Nothing ever asked before, so macOS dropped every
    /// running/stopped notice the app posted.
    func start() {
        guard let center = center else { return }
        center.readPermission { [self] permission in
            guard NotificationPolicy.shouldAsk(permission) else {
                report(permission)
                return
            }
            // Read back what the system now holds instead of trusting the
            // prompt's `granted`: an error (an unsigned build, a managed Mac)
            // also gives false, and the person has refused nothing then.
            center.requestPermission { self.refresh() }
        }
    }

    /// Turning notifications on in System Settings sends the app no event,
    /// so this is called on every poll.
    func refresh() {
        center?.readPermission { [self] permission in report(permission) }
    }

    /// Judged on what the system says now, not at launch: the person may
    /// have changed it since.
    func deliver(_ notice: Notice, title: String, body: String) {
        guard let center = center else {
            if NotificationPolicy.delivery(of: notice, when: .refused) == .alert {
                onMain { self.alert(title, body) }
            }
            return
        }
        center.readPermission { [self] permission in
            report(permission)
            switch NotificationPolicy.delivery(of: notice, when: permission) {
            case .post:
                center.post(title: title, body: body) { accepted in
                    // Turned off between the read and the post: a failure
                    // still has to reach the person.
                    guard !accepted, notice == .actionFailure else { return }
                    self.onMain { self.alert(title, body) }
                }
            case .alert:
                onMain { self.alert(title, body) }
            case .drop:
                break
            }
        }
    }

    private func report(_ permission: NoticePermission) {
        onMain { self.permissionChanged(permission) }
    }
}
