import UserNotifications
import XCTest
@testable import QuickTerm

/// **The notification centre a test hands `SystemNotificationSink`** (contract §10.10).
///
/// Every question the sink's cases ask - did it post, with what content, did it withdraw the old
/// banner, did it ask for authorization - is answered from these three arrays. Without it the
/// cases would put real banners on whatever machine runs the suite and "did it withdraw" would be
/// something you verify by looking at the screen.
final class RecordingNotificationCenter: UserNotificationCentering {
    var delegate: UNUserNotificationCenterDelegate?

    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedDelivered: [String] = []
    private(set) var removedPending: [String] = []
    private(set) var authorizationRequests = 0

    /// What `requestAuthorization` answers.
    var grantAuthorization = true

    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        authorizationRequests += 1
        completionHandler(grantAuthorization, nil)
    }

    func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void) {}

    func add(_ request: UNNotificationRequest,
             withCompletionHandler: (@Sendable ((any Error)?) -> Void)?) {
        added.append(request)
        withCompletionHandler?(nil)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(contentsOf: identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(contentsOf: identifiers)
    }

    func reset() {
        added.removeAll()
        removedDelivered.removeAll()
        removedPending.removeAll()
        authorizationRequests = 0
    }

    var lastContent: UNNotificationContent? { added.last?.content }
}
