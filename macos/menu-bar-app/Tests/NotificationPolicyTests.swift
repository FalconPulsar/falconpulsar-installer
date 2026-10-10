// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

import UserNotifications
import XCTest
@testable import FalconPulsarMenuBar

final class NotificationPolicyTests: XCTestCase {
    func testAllowedNoticesArePosted() {
        XCTAssertEqual(NotificationPolicy.delivery(of: .statusChange, when: .allowed), .post)
        XCTAssertEqual(NotificationPolicy.delivery(of: .actionFailure, when: .allowed), .post)
    }

    func testARefusedFailureBecomesAnAlert() {
        // A Start that failed must reach the person even after they said no
        // to notifications.
        XCTAssertEqual(NotificationPolicy.delivery(of: .actionFailure, when: .refused), .alert)
        XCTAssertEqual(NotificationPolicy.delivery(of: .actionFailure, when: .notAsked), .alert)
    }

    func testARefusedStatusChangeIsDroppedNotAlerted() {
        // An alert here would be a dialog every time the stack starts or stops.
        XCTAssertEqual(NotificationPolicy.delivery(of: .statusChange, when: .refused), .drop)
        XCTAssertEqual(NotificationPolicy.delivery(of: .statusChange, when: .notAsked), .drop)
    }

    func testOnlyAnUnansweredPermissionIsAskedFor() {
        XCTAssertTrue(NotificationPolicy.shouldAsk(.notAsked))
        XCTAssertFalse(NotificationPolicy.shouldAsk(.allowed))
        XCTAssertFalse(NotificationPolicy.shouldAsk(.refused))
    }

    func testTheMenuOffersTurnOnOnlyAfterARefusal() {
        XCTAssertTrue(NotificationPolicy.offersTurnOn(.refused))
        XCTAssertFalse(NotificationPolicy.offersTurnOn(.allowed))
        XCTAssertFalse(NotificationPolicy.offersTurnOn(.notAsked))
    }

    func testSystemStatusesMapToWhatThePersonSaid() {
        XCTAssertEqual(NoticePermission(.authorized), .allowed)
        XCTAssertEqual(NoticePermission(.provisional), .allowed)
        XCTAssertEqual(NoticePermission(.notDetermined), .notAsked)
        XCTAssertEqual(NoticePermission(.denied), .refused)
    }

    func testOnlyTheInstalledAppTouchesTheNotificationCenter() {
        let app = URL(fileURLWithPath: "/Applications/FalconPulsar Menu Bar.app")
        XCTAssertTrue(NotificationPolicy.canUseNotificationCenter(bundleURL: app,
                                                                  bundleIdentifier: "com.falconpulsar.menubar"))
        // `swift build` / the CI swiftc compile: a bare binary in a folder.
        let bare = URL(fileURLWithPath: "/tmp/menu-bar-app/.build/debug")
        XCTAssertFalse(NotificationPolicy.canUseNotificationCenter(bundleURL: bare, bundleIdentifier: nil))
        XCTAssertFalse(NotificationPolicy.canUseNotificationCenter(bundleURL: app, bundleIdentifier: nil))
        XCTAssertFalse(NotificationPolicy.canUseNotificationCenter(bundleURL: app, bundleIdentifier: ""))
    }
}

/// A notification center that answers at once, on the calling thread, and
/// records what it was asked to do.
private final class FakeCenter: NoticeCenter {
    var permission: NoticePermission
    /// What the person answers when the prompt is shown.
    var answer: NoticePermission?
    var acceptsPosts = true
    private(set) var prompts = 0
    private(set) var posted: [String] = []

    init(_ permission: NoticePermission, answer: NoticePermission? = nil) {
        self.permission = permission
        self.answer = answer
    }

    func readPermission(_ done: @escaping (NoticePermission) -> Void) { done(permission) }

    func requestPermission(_ done: @escaping () -> Void) {
        prompts += 1
        if let answer = answer { permission = answer }
        done()
    }

    func post(title: String, body: String, _ done: @escaping (Bool) -> Void) {
        if acceptsPosts { posted.append(body) }
        done(acceptsPosts)
    }
}

final class NoticesFlowTests: XCTestCase {
    private var alerts: [String] = []
    private var reported: [NoticePermission] = []

    private func notices(_ center: NoticeCenter?) -> Notices {
        Notices(center: center,
                onMain: { $0() },
                alert: { [unowned self] _, body in alerts.append(body) },
                permissionChanged: { [unowned self] in reported.append($0) })
    }

    func testLaunchAsksAnUnansweredPersonAndReportsARefusal() {
        let center = FakeCenter(.notAsked, answer: .refused)
        notices(center).start()
        XCTAssertEqual(center.prompts, 1)
        // The refusal is read back from the system, so the menu can offer
        // the way back.
        XCTAssertEqual(reported.last, .refused)
    }

    func testLaunchReportsAnAllowAfterThePrompt() {
        let center = FakeCenter(.notAsked, answer: .allowed)
        notices(center).start()
        XCTAssertEqual(center.prompts, 1)
        XCTAssertEqual(reported.last, .allowed)
    }

    func testAPromptThatErrorsIsNotTakenForARefusal() {
        // requestAuthorization gives `granted == false` on an error too; the
        // status stays undecided and no "Turn On" row may appear.
        let center = FakeCenter(.notAsked, answer: nil)
        notices(center).start()
        XCTAssertEqual(center.prompts, 1)
        XCTAssertEqual(reported.last, .notAsked)
    }

    func testLaunchDoesNotAskAgainAfterARefusalOrAnAllow() {
        for answered in [NoticePermission.refused, .allowed] {
            reported = []
            let center = FakeCenter(answered)
            notices(center).start()
            XCTAssertEqual(center.prompts, 0, "\(answered)")
            XCTAssertEqual(reported, [answered])
        }
    }

    func testAStatusChangeIsPostedWhenAllowedAndDroppedWhenRefused() {
        let allowed = FakeCenter(.allowed)
        notices(allowed).deliver(.statusChange, title: "FalconPulsar", body: "All containers have stopped.")
        XCTAssertEqual(allowed.posted, ["All containers have stopped."])

        let refused = FakeCenter(.refused)
        notices(refused).deliver(.statusChange, title: "FalconPulsar", body: "All containers have stopped.")
        XCTAssertEqual(refused.posted, [])
        XCTAssertEqual(alerts, [], "a status change never raises a dialog")
    }

    func testAFailureAfterARefusalIsAnAlert() {
        let center = FakeCenter(.refused)
        notices(center).deliver(.actionFailure, title: "Start Stack failed", body: "port is already allocated")
        XCTAssertEqual(center.posted, [])
        XCTAssertEqual(alerts, ["port is already allocated"])
    }

    func testAFailureTheSystemWouldNotTakeIsAnAlert() {
        let center = FakeCenter(.allowed)
        center.acceptsPosts = false
        notices(center).deliver(.actionFailure, title: "Start Stack failed", body: "port is already allocated")
        XCTAssertEqual(alerts, ["port is already allocated"])
    }

    func testRefreshFollowsATurnOnInSystemSettings() {
        let center = FakeCenter(.refused)
        let n = notices(center)
        n.start()
        center.permission = .allowed
        n.refresh()
        XCTAssertEqual(reported, [.refused, .allowed])
    }

    func testWithoutACenterNothingIsAskedAndAFailureStillAlerts() {
        let n = notices(nil)
        n.start()
        n.deliver(.statusChange, title: "FalconPulsar", body: "All containers are running.")
        n.deliver(.actionFailure, title: "Stop Stack failed", body: "no such container")
        XCTAssertEqual(reported, [])
        XCTAssertEqual(alerts, ["no such container"])
    }
}
