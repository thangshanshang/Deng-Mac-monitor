import Foundation
import Darwin
#if canImport(CIOReport)
import CIOReport
#endif

// Channel mapping researched with SiliconScope (MIT); see bundled acknowledgement.
struct ANEReading: Equatable {
    var activity: Double?
    var readGBs: Double?
    var writeGBs: Double?
    var totalGBs: Double?
    var estimated = false
}

@MainActor final class ANEHardware {
    private final class ChannelSet {
        let subscription: IOReportSubscriptionRef
        let channels: CFMutableDictionary
        private var previous: CFDictionary
        private var timestamp: TimeInterval
        init?(group: String, subgroup: String) {
            guard let desired = IOReportCopyChannelsInGroup(group as CFString, subgroup as CFString, 0, 0, 0)?.takeRetainedValue() else { return nil }
            var raw: Unmanaged<CFMutableDictionary>?
            guard let sub = IOReportCreateSubscription(nil, desired, &raw, 0, nil),
                  let channels = raw?.takeRetainedValue(),
                  let initial = IOReportCreateSamples(sub, channels, nil)?.takeRetainedValue() else { return nil }
            self.subscription = sub
            self.channels = channels
            self.previous = initial
            self.timestamp = ProcessInfo.processInfo.systemUptime
        }
        func delta() -> (CFDictionary, Double)? {
            guard let current = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - timestamp
            defer { previous = current; timestamp = now }
            // Re-prime after sleep; never present an hours-long average as a one-second reading.
            guard elapsed > 0, elapsed < 5,
                  let delta = IOReportCreateSamplesDelta(previous, current, nil)?.takeRetainedValue() else { return nil }
            return (delta, elapsed)
        }
    }
    private var activity: ChannelSet?
    private var bytes: ChannelSet?
    private var histogram: ChannelSet?
    private var attemptedHistogram = false
    private let library: UnsafeMutableRawPointer?

    init() {
        library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_GLOBAL)
        guard library != nil else { return }
        activity = ChannelSet(group: "SoC Stats", subgroup: "Cluster Power States")
        bytes = ChannelSet(group: "AMC Stats", subgroup: "Perf Counters")
    }

    static func isANE(_ name: String) -> Bool {
        name.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { token in
            token == "ANE" || (token.hasPrefix("ANE") && token.dropFirst(3).allSatisfy(\.isNumber))
        }
    }
    static func fraction(_ states: [(String, Double)]) -> Double? {
        guard states.contains(where: { $0.0 == "ACT" }), states.allSatisfy({ $0.1.isFinite && $0.1 >= 0 }) else { return nil }
        let total = states.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return states.filter { $0.0 == "ACT" }.reduce(0) { $0 + $1.1 } / total
    }
    static func gbPerSecond(_ bytes: Int64, seconds: Double) -> Double? {
        guard bytes >= 0, seconds > 0, seconds.isFinite else { return nil }
        return Double(bytes) / seconds / 1_000_000_000
    }
    static func weightedBandwidth(_ buckets: [(Double, Double)]) -> Double? {
        guard !buckets.isEmpty else { return nil }
        let total = buckets.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return buckets.reduce(0) { $0 + $1.0 * $1.1 } / total
    }
    private static func name(_ channel: CFDictionary) -> String {
        IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String? ?? ""
    }

    func sample() -> ANEReading {
        var result = ANEReading()
        if let (delta, _) = activity?.delta() {
            var fractions: [Double] = []
            IOReportIterate(delta) { channel in
                guard let channel else { return 0 }
                guard IOReportChannelGetFormat(channel) == 2, Self.isANE(Self.name(channel)) else { return 0 }
                let states = (0..<IOReportStateGetCount(channel)).map { index in
                    (IOReportStateGetNameForIndex(channel, index)?.takeUnretainedValue() as String? ?? "", Double(IOReportStateGetResidency(channel, index)))
                }
                if let active = Self.fraction(states) { fractions.append(active) }
                return 0
            }
            result.activity = fractions.max()
        }
        if let (delta, elapsed) = bytes?.delta() {
            var read: [Double] = [], write: [Double] = []
            var invalid = false
            IOReportIterate(delta) { channel in
                guard let channel else { return 0 }
                let name = Self.name(channel).uppercased()
                guard IOReportChannelGetFormat(channel) == 1, Self.isANE(name), name.contains(" DCS "), name.hasSuffix(" RD") || name.hasSuffix(" WR") else { return 0 }
                guard let rate = Self.gbPerSecond(Int64(IOReportSimpleGetIntegerValue(channel, 0)), seconds: elapsed) else { invalid = true; return 0 }
                if name.hasSuffix(" RD") { read.append(rate) } else { write.append(rate) }
                return 0
            }
            // Partial or sentinel-valued readings are unknown, never a zero or incomplete total.
            if !invalid, !read.isEmpty, !write.isEmpty {
                result.readGBs = read.reduce(0, +)
                result.writeGBs = write.reduce(0, +)
                result.totalGBs = result.readGBs! + result.writeGBs!
            }
        }
        if result.totalGBs == nil {
            if !attemptedHistogram, library != nil {
                attemptedHistogram = true
                for group in ["PMP", "PMP0", "PMP1"] {
                    if let source = ChannelSet(group: group, subgroup: "DCS BW") { histogram = source; break }
                }
            }
            if let (delta, _) = histogram?.delta() {
                var values: [Double] = []
                IOReportIterate(delta) { channel in
                guard let channel else { return 0 }
                    let name = Self.name(channel).uppercased()
                    guard IOReportChannelGetFormat(channel) == 2, Self.isANE(name), name.hasSuffix(" RD+WR") else { return 0 }
                    var buckets: [(Double, Double)] = []
                    for i in 0..<IOReportStateGetCount(channel) {
                        let label = (IOReportStateGetNameForIndex(channel, i)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                        guard label.hasSuffix("GB/S"), let value = Double(label.dropLast(4).trimmingCharacters(in: .whitespaces)), value >= 0 else { continue }
                        buckets.append((value, Double(IOReportStateGetResidency(channel, i))))
                    }
                    if let value = Self.weightedBandwidth(buckets) { values.append(value) }
                    return 0
                }
                if !values.isEmpty { result.totalGBs = values.reduce(0, +); result.estimated = true }
            }
        }
        return result
    }
}
