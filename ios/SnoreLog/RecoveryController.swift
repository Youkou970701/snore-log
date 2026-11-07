import Foundation
protocol RecoverySessionEngine {
    func activateAndRestart() throws
}
struct RecoveryEvent {
    var start: Date
    var duration: Double
    var method: String
}
struct RecoveryController {
    private(set) var began: Date?
    private var lastAttempt: Date?
    mutating func begin(at date: Date) {
        if began == nil { began = date; lastAttempt = date }
    }
    mutating func attempt(at now: Date, method: String, force: Bool = false, session: RecoverySessionEngine) throws -> RecoveryEvent? {
        guard let began, force || now.timeIntervalSince(lastAttempt ?? began) >= 30 else { return nil }
        lastAttempt = now
        try session.activateAndRestart()
        self.began = nil; lastAttempt = nil
        return .init(start: began, duration: max(0, now.timeIntervalSince(began)), method: method)
    }
    mutating func stop(at now: Date) -> RecoveryEvent? {
        guard let began else { return nil }
        self.began = nil; lastAttempt = nil
        return .init(start: began, duration: max(0, now.timeIntervalSince(began)), method: "stopped")
    }
}
struct ClosureRecoverySession: RecoverySessionEngine {
    let restart: () throws -> Void
    func activateAndRestart() throws { try restart() }
}
