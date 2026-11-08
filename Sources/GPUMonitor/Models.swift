import Foundation

enum DeviceKind: String, Codable, CaseIterable, Identifiable {
    case auto, nvidia, ascend
    var id: String { rawValue }
    var title: String {
        switch self { case .auto: return "自动识别"; case .nvidia: return "NVIDIA GPU"; case .ascend: return "昇腾 NPU" }
    }
}

struct Server: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var kind: DeviceKind = .auto
    var port: Int? = nil
    var user: String = ""
    var identityFile: String = ""
    var enabled = true

    var validationError: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "请输入服务器名称。" }
        guard Self.validHost(host) else { return "请输入有效的 SSH 别名或主机地址，不要填写 ssh 命令。" }
        if let port, !(1...65535).contains(port) { return "端口必须在 1–65535 之间。" }
        if !user.isEmpty && !user.allSatisfy({ $0.isLetter || $0.isNumber || "_.-".contains($0) }) { return "SSH 用户名包含不支持的字符。" }
        return nil
    }
    static func validHost(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.utf8.count <= 255 &&
        value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-@:%[]".contains($0)) }
    }
}

struct ComputeProcess: Identifiable, Equatable {
    var pid: Int
    var user: String?
    var name: String
    var memoryMiB: Double?
    var program: String? = nil
    var id: Int { pid }
}

enum CardState: String {
    case busy = "计算中", occupied = "已占用", checking = "检测中", idle = "空闲", unknown = "状态未知"
}

struct Accelerator: Identifiable, Equatable {
    var id: String
    var index: Int
    var chip: Int? = nil
    var kind: DeviceKind
    var name: String
    var utilization: Double?
    var memoryUsedMiB: Double?
    var memoryTotalMiB: Double?
    var temperature: Double? = nil
    var health: String? = nil
    var powerWatts: Double? = nil
    var processes: [ComputeProcess] = []
    var processesKnown = false
    var label: String { "\(kind == .ascend ? "NPU" : "GPU") \(index)" + (chip.map { " · Chip \($0)" } ?? "") }
    var compactLabel: String { "\(kind == .ascend ? "NPU" : "GPU") \(index)" + ((chip ?? 0) > 0 ? ".\(chip!)" : "") }
    var shortName: String { name.replacingOccurrences(of: "NVIDIA GeForce ", with: "").replacingOccurrences(of: "NVIDIA ", with: "") }
    var availabilityTitle: String {
        switch state { case .idle: return "空闲"; case .busy, .occupied: return "占用"; default: return "未知" }
    }
    var occupancyReason: String {
        if state == .busy { return "正在计算" }
        if !processes.isEmpty { return "进程仍在占用，当前计算负载低" }
        if state == .occupied { return "设备内存仍有占用" }
        if state == .idle {
            return usesAscendMemoryTolerance ? "未发现计算进程，AI Core 低于 5%；HBM 在 910B 常驻内存容差内" : "未发现计算进程，负载与内存占用低"
        }
        return "数据不足或设备健康异常，无法确认空闲"
    }
    var metric: String { kind == .ascend ? "AI Core" : "GPU 利用率" }
    var owners: String {
        if processes.isEmpty { return processesKnown ? "未发现计算进程" : "进程信息不可用" }
        return Set(processes.map { $0.user ?? "用户未知" }).sorted().joined(separator: ", ")
    }
    // A bounded model-specific heuristic, not a measurement of driver-reserved memory.
    // Observed 64 GiB 910B3 devices retain about 3.3 GiB without compute processes.
    // Keep the raw HBM value and never apply this tolerance to other device families.
    var usesAscendMemoryTolerance: Bool {
        kind == .ascend && name.uppercased().contains("910B")
    }
    var idleMemoryLimitMiB: Double {
        guard let total = memoryTotalMiB, total > 0 else { return 0 }
        return usesAscendMemoryTolerance ? min(4096, total * 0.06) : max(512, total * 0.02)
    }
    var idleCandidate: Bool {
        guard processesKnown, processes.isEmpty, let utilization, utilization < 5,
              let used = memoryUsedMiB, let total = memoryTotalMiB, total > 0,
              (kind == .ascend ? health?.uppercased() == "OK" : health == nil || health?.uppercased() == "OK") else { return false }
        return used <= idleMemoryLimitMiB
    }
    var state: CardState {
        if let health, health.uppercased() != "OK" { return .unknown }
        if let utilization, utilization >= 5 { return .busy }
        if !processes.isEmpty { return .occupied }
        if let used = memoryUsedMiB, let total = memoryTotalMiB, total > 0, used > idleMemoryLimitMiB { return .occupied }
        if idleCandidate { return .idle }
        return .unknown
    }
}

struct Snapshot {
    var devices: [Accelerator]
    var date = Date()
    var warnings: [String] = []
    var telemetry: HostTelemetry? = nil
    var gpuError: String? = nil

}

struct ServerStatus {
    var snapshot: Snapshot? = nil
    var error: String? = nil
    var refreshing = false
    func stale(at date: Date = Date(), interval: Double = 20) -> Bool {
        error != nil || snapshot.map { date.timeIntervalSince($0.date) > max(60, interval * 3) } ?? true
    }
}

enum MonitorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

func memoryText(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.1f GiB", value / 1024)
}
