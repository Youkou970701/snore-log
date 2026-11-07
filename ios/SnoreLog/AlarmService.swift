import Foundation
import AlarmKit
import SwiftUI
import UserNotifications

private struct NightAlarmMetadata: AlarmMetadata {}

@MainActor
final class AlarmService: ObservableObject {
    @Published private(set) var authorized = AlarmManager.shared.authorizationState == .authorized
    @Published private(set) var errorMessage: String?

    /// Uses the on-device SDK interface: the post-alert countdown provides system snooze.
    func schedule(date: Date, snooze: Bool) async throws -> Bool {
        var authorization = AlarmManager.shared.authorizationState
        if authorization == .notDetermined { authorization = try await AlarmManager.shared.requestAuthorization() }
        authorized = authorization == .authorized
        guard authorized else { return false }
        cancelAll()
        let stop = AlarmButton(text: "关闭", textColor: .primary, systemImageName: "stop.fill")
        let secondary = snooze ? AlarmButton(text: "贪睡", textColor: .primary, systemImageName: "zzz") : nil
        // The iOS 26 initializer permits a named stop button; 26.1+ lets the system
        // render its standard stop control (the SDK marks stopButton deprecated).
        let alert = AlarmPresentation.Alert(title: "起床时间到了", stopButton: stop,
                                            secondaryButton: secondary,
                                            secondaryButtonBehavior: snooze ? .countdown : nil)
        let presentation = AlarmPresentation(alert: alert,
                                              countdown: snooze ? .init(title: "贪睡中") : nil)
        let attributes = AlarmAttributes(presentation: presentation,
                                         metadata: NightAlarmMetadata(), tintColor: .primary)
        let configuration = AlarmManager.AlarmConfiguration(
            countdownDuration: snooze ? .init(preAlert: nil, postAlert: 9 * 60) : nil,
            schedule: .fixed(date), attributes: attributes)
        _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: configuration)
        return true
    }
    func cancelAll() {
        do {
            for alarm in try AlarmManager.shared.alarms { try AlarmManager.shared.cancel(id: alarm.id) }
        } catch { errorMessage = error.localizedDescription }
    }
    func scheduleExpirationReminder(expiration: Date?) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["installation-expiration"])
        guard let expiration,
              let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: expiration),
              let reminder = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: previousDay),
              reminder > Date() else { return }
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
            let content = UNMutableNotificationContent()
            content.title = "呼噜记明天到期，记得连 Mac 重新安装"
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder)
            try await center.add(.init(identifier: "installation-expiration", content: content,
                                       trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        } catch { errorMessage = error.localizedDescription }
    }
}
