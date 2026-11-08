import Foundation

enum MonitorPanel: String, CaseIterable, Identifiable, Codable {
    case gpu, cpu, memory, network, disk
    var id: String { rawValue }
    var title: String {
        switch self { case .gpu: return "GPU / NPU"; case .cpu: return "CPU"; case .memory: return "内存"; case .network: return "网络"; case .disk: return "磁盘" }
    }
    var symbol: String {
        switch self { case .gpu: return "square.stack.3d.up"; case .cpu: return "cpu"; case .memory: return "memorychip"; case .network: return "network"; case .disk: return "internaldrive" }
    }
}

struct PanelPreferences: Codable, Equatable {
    var visible: Set<MonitorPanel> = [.gpu, .cpu, .memory, .network]
}

struct CPUTicks: Equatable {
    var total: Double
    var idle: Double
    func utilization(since old: CPUTicks?) -> Double? {
        guard let old, total > old.total, idle >= old.idle else { return nil }
        let delta = total - old.total
        guard idle - old.idle <= delta else { return nil }
        return 100 * (1 - (idle - old.idle) / delta)
    }
}

struct NetworkInterface: Identifiable, Equatable {
    var name: String
    var received: Double
    var sent: Double
    var receiveRate: Double? = nil
    var sendRate: Double? = nil
    var id: String { name }
}

struct HostTelemetry: Equatable {
    var uptime: Double?
    var cpuModel: String?
    var cpuTicks: [String: CPUTicks] = [:]
    var cpuUsage: Double? = nil
    var coreUsage: [String: Double] = [:]
    var memoryTotalMiB: Double?
    var memoryAvailableMiB: Double?
    var swapTotalMiB: Double?
    var swapFreeMiB: Double?
    var load: [Double] = []
    var interfaces: [NetworkInterface] = []
    var primaryInterface: String?
    var volumes: [DiskVolume] = []
    var disks: [DiskIO] = []
    var diskTotalKiB: Double?
    var diskUsedKiB: Double?
    var diskMount: String?
    var memoryUsedMiB: Double? {
        guard let total = memoryTotalMiB, let available = memoryAvailableMiB else { return nil }
        return max(0, total - available)
    }
    var coreCount: Int { max(0, cpuTicks.count - 1) }
    var primaryNetwork: NetworkInterface? {
        interfaces.first { $0.name == primaryInterface } ?? interfaces.first
    }

    mutating func calculateRates(previous: HostTelemetry?) {
        guard let previous, let uptime, let oldUptime = previous.uptime, uptime > oldUptime else { return }
        cpuUsage = cpuTicks["cpu"]?.utilization(since: previous.cpuTicks["cpu"])
        for (key, ticks) in cpuTicks where key != "cpu" {
            coreUsage[key] = ticks.utilization(since: previous.cpuTicks[key])
        }
        let elapsed = uptime - oldUptime
        calculateDiskRates(previous: previous, elapsed: elapsed)
        for i in interfaces.indices {
            guard let old = previous.interfaces.first(where: { $0.name == interfaces[i].name }),
                  interfaces[i].received >= old.received, interfaces[i].sent >= old.sent else { continue }
            interfaces[i].receiveRate = (interfaces[i].received - old.received) / elapsed
            interfaces[i].sendRate = (interfaces[i].sent - old.sent) / elapsed
        }
    }

    static func parse(_ sections: [String: [String]]) -> HostTelemetry? {
        guard let uptimeLine = sections["__GM_UPTIME__"]?.first,
              let uptime = Double(uptimeLine.split(separator: " ").first ?? "") else { return nil }
        var value = HostTelemetry(uptime: uptime)
        value.cpuModel = sections["__GM_CPU_MODEL__"]?.first
        for line in sections["__GM_CPU__", default: []] {
            let cells = line.split(whereSeparator: \.isWhitespace)
            guard let key = cells.first, key.hasPrefix("cpu") else { continue }
            // guest / guest_nice are already included in user / nice.
            let ticks = cells.dropFirst().prefix(8).compactMap { Double($0) }
            guard ticks.count >= 4 else { continue }
            value.cpuTicks[String(key)] = CPUTicks(total: ticks.reduce(0, +), idle: ticks[3] + (ticks.count > 4 ? ticks[4] : 0))
        }
        var memory: [String: Double] = [:]
        for line in sections["__GM_MEMORY__", default: []] {
            let cells = line.split(whereSeparator: \.isWhitespace)
            if cells.count >= 2, let number = Double(cells[1]) { memory[String(cells[0])] = number / 1024 }
        }
        value.memoryTotalMiB = memory["MemTotal:"]
        value.memoryAvailableMiB = memory["MemAvailable:"]
        value.swapTotalMiB = memory["SwapTotal:"]; value.swapFreeMiB = memory["SwapFree:"]
        value.load = sections["__GM_LOAD__"]?.first?.split(separator: " ").prefix(3).compactMap { Double($0) } ?? []
        for line in sections["__GM_NETWORK__", default: []] {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let cells = parts[1].split(whereSeparator: \.isWhitespace)
            guard name != "lo", cells.count >= 9, let received = Double(cells[0]), let sent = Double(cells[8]) else { continue }
            value.interfaces.append(NetworkInterface(name: name, received: received, sent: sent))
        }
        value.interfaces.sort { $0.name < $1.name }
        value.primaryInterface = sections["__GM_ROUTE__"]?.first?.trimmingCharacters(in: .whitespaces)
        if value.primaryInterface == nil || !value.interfaces.contains(where: { $0.name == value.primaryInterface }) {
            value.primaryInterface = value.interfaces.max(by: { $0.received + $0.sent < $1.received + $1.sent })?.name
        }
        value.parseDisks(sections)
        return value
    }
}

func rateText(_ bytes: Double?) -> String {
    guard let bytes else { return "采样中" }
    if bytes >= 1_048_576 { return String(format: "%.1f MiB/s", bytes / 1_048_576) }
    if bytes >= 1024 { return String(format: "%.1f KiB/s", bytes / 1024) }
    return String(format: "%.0f B/s", bytes)
}
