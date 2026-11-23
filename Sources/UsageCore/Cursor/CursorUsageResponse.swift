import Foundation

/// The body of `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`,
/// the endpoint behind Cursor's own usage display. Undocumented; decoded as forgivingly as the
/// others.
///
/// Cursor sends its cycle in milliseconds, as strings. The cycle is usually a month, but plans
/// merged with another subscription (SuperGrok, for one) can run on that plan's shorter cycle,
/// so the window's length is always taken from the response.
public struct CursorUsageResponse: Sendable, Equatable {
    public var cycleStart: Date?
    public var cycleEnd: Date?
    public var enabled: Bool?
    public var planUsage: PlanUsage?
    public var spendLimitUsage: SpendLimitUsage?

    public struct PlanUsage: Sendable, Equatable {
        /// The share of the plan's included usage used so far, across every model.
        public var totalPercentUsed: Double?
        public var autoPercentUsed: Double?
    }

    /// On-demand usage beyond the plan, in cents, when a spending limit is set.
    public struct SpendLimitUsage: Sendable, Equatable {
        public var individualLimit: Double?
        public var individualUsed: Double?
    }

    public static func decode(_ data: Data) throws -> CursorUsageResponse {
        try JSONDecoder().decode(CursorUsageResponse.self, from: data)
    }

    /// The window the plan's usage is counted over, when both ends are known and in order.
    var windowLength: TimeInterval? {
        guard let cycleStart, let cycleEnd, cycleEnd > cycleStart else { return nil }
        return cycleEnd.timeIntervalSince(cycleStart)
    }

    /// The plan's included usage, then any on-demand spending limit.
    public func rows(now: Date = .now) -> [LimitRow] {
        var rows: [LimitRow] = []
        let span = Format.windowName(seconds: windowLength.map { Int($0.rounded()) })
        if let plan = planUsage, enabled != false,
           let percent = plan.totalPercentUsed ?? plan.autoPercentUsed {
            rows.append(LimitRow(
                id: "cursor-plan",
                title: span,
                percent: percent,
                resetsAt: cycleEnd,
                severity: Severity(percent: percent),
                windowLength: windowLength
            ))
        }
        if let spend = spendLimitUsage, let limit = spend.individualLimit, limit > 0 {
            let percent = Sanitise.percent((spend.individualUsed ?? 0) / limit * 100)
            rows.append(LimitRow(
                id: "cursor-on-demand",
                title: "\(span) · On-demand",
                percent: percent,
                resetsAt: cycleEnd,
                severity: Severity(percent: percent),
                windowLength: windowLength
            ))
        }
        return rows.map { $0.rolledOver(at: now) }
    }
}

extension CursorUsageResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case billingCycleStart, billingCycleEnd, enabled, planUsage, spendLimitUsage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cycleStart = Sanitise.epoch(container.number(.billingCycleStart))
        cycleEnd = Sanitise.epoch(container.number(.billingCycleEnd))
        enabled = container.lenient(Bool.self, .enabled)
        planUsage = container.lenient(PlanUsage.self, .planUsage)
        spendLimitUsage = container.lenient(SpendLimitUsage.self, .spendLimitUsage)
    }
}

extension CursorUsageResponse.PlanUsage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case totalPercentUsed, autoPercentUsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalPercentUsed = Sanitise.percent(container.number(.totalPercentUsed))
        autoPercentUsed = Sanitise.percent(container.number(.autoPercentUsed))
    }
}

extension CursorUsageResponse.SpendLimitUsage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case individualLimit, individualUsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        individualLimit = Self.cents(container.number(.individualLimit))
        individualUsed = Self.cents(container.number(.individualUsed))
    }

    private static func cents(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 1_000_000_000)
    }
}
