import Foundation

enum SnapshotParser {
    static func parse(_ raw: String) throws -> Snapshot {
        var sections: [String: [String]] = [:], current = ""
        var procOK = Set<Int>(), appsOK = false, psOK = false
        let systemMarkers = ["__GM_UPTIME__", "__GM_CPU__", "__GM_CPU_MODEL__", "__GM_MEMORY__", "__GM_LOAD__", "__GM_NETWORK__", "__GM_ROUTE__", "__GM_DISK__", "__GM_DISK_IO__", "__GM_DISK_SIZE__", "__GM_PROGRAMS__", "__GM_GPU_ERROR__"]
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "__GM_APPS_OK__" { appsOK = true; current = "" }
            else if trimmed == "__GM_PS_OK__" { psOK = true; current = "" }
            else if trimmed.hasPrefix("__GM_NPU_PROC_OK__ ") {
                if let id = Int(trimmed.split(separator: " ").last ?? "") { procOK.insert(id) }; current = ""
            } else if trimmed.hasPrefix("__GM_NPU_PROC__ ") {
                current = "PROC-" + String(trimmed.split(separator: " ").last ?? "")
            } else if (["__GM_GPU__", "__GM_NPU__", "__GM_APPS__", "__GM_PS__"] + systemMarkers).contains(trimmed) { current = trimmed }
            else if !current.isEmpty { sections[current, default: []].append(line) }
        }
        var owners: [Int: (String, String)] = [:]
        for line in sections["__GM_PS__", default: []] {
            let cells = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            if cells.count >= 2, let pid = Int(cells[0]) { owners[pid] = (String(cells[1]), cells.count > 2 ? String(cells[2]) : "") }
        }
        var devices: [Accelerator] = [], warnings: [String] = []
        let telemetry = HostTelemetry.parse(sections)
        var gpuError = sections["__GM_GPU_ERROR__"]?.filter { !$0.isEmpty }.joined(separator: " ")
        if let lines = sections["__GM_GPU__"] {
            for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let c = csv(line)
                guard c.count == 7, let index = Int(c[0]), !c[1].isEmpty else {
                    if telemetry != nil { gpuError = "无法完整解析 NVIDIA 设备列表。"; devices = []; break }
                    throw MonitorError.message("无法完整解析 NVIDIA 设备列表，请检查驱动输出。")
                }
                devices.append(Accelerator(id: c[1], index: index, kind: .nvidia, name: c[2], utilization: percent(c[3]), memoryUsedMiB: number(c[4]), memoryTotalMiB: number(c[5]), temperature: number(c[6]), processesKnown: appsOK && psOK))
            }
            var malformed = false
            for line in sections["__GM_APPS__", default: []] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let c = csv(line)
                guard c.count == 4, let pid = Int(c[1]) else { malformed = true; continue }
                guard let i = devices.firstIndex(where: { $0.id == c[0] }) else { malformed = true; continue }
                devices[i].processes.append(ComputeProcess(pid: pid, user: owners[pid]?.0, name: c[2], memoryMiB: number(c[3])))
            }
            if malformed { for i in devices.indices { devices[i].processesKnown = false } }
        } else if let lines = sections["__GM_NPU__"] {
            do { devices = try ascendDevices(lines) }
            catch { if telemetry != nil { gpuError = error.localizedDescription } else { throw error } }
            for index in devices.indices {
                let inline = ascendInlineProcesses(lines, index: devices[index].index, chip: devices[index].chip, owners: owners)
                let fallback = ascendProcesses(sections["PROC-\(devices[index].index)", default: []], chip: devices[index].chip, owners: owners)
                let parsed = inline.recognized ? inline : fallback
                devices[index].processes = parsed.processes
                devices[index].processesKnown = psOK && parsed.recognized && (inline.recognized || procOK.contains(devices[index].index))
            }
        } else if telemetry == nil { throw MonitorError.message("未收到可识别的设备数据。请检查 SSH RemoteCommand 或远端命令输出。") }
        guard !devices.isEmpty || telemetry != nil else { throw MonitorError.message("服务器未返回可识别的 GPU / NPU。") }
        let programs = sections["__GM_PROGRAMS__", default: []].reduce(into: [Int: String]()) { result, line in
            guard let data = line.data(using: .utf8), let pair = try? JSONDecoder().decode([String].self, from: data),
                  pair.count == 2, let pid = Int(pair[0]) else { return }
            result[pid] = pair[1]
        }
        for i in devices.indices {
            for j in devices[i].processes.indices { devices[i].processes[j].program = programs[devices[i].processes[j].pid] }
        }
        if devices.contains(where: { !$0.processesKnown }) { warnings.append("部分进程信息不可用；不会将这些设备判断为空闲。") }
        if devices.contains(where: { $0.processes.contains { $0.user == nil } }) { warnings.append("部分 PID 无法映射到用户名，可能受权限或容器隔离影响。") }
        if devices.count > 8 { warnings.append("检测到 \(devices.count) 个设备 / 芯片，本版仅展示前 8 个。") }
        return Snapshot(devices: Array(devices.sorted { ($0.index, $0.chip ?? 0) < ($1.index, $1.chip ?? 0) }.prefix(8)), warnings: warnings, telemetry: telemetry, gpuError: gpuError)
    }

    static func ascendDevices(_ lines: [String]) throws -> [Accelerator] {
        let rows = lines.map(table).filter { !$0.isEmpty }
        var result: [Accelerator] = []
        var pending: (index: Int, name: String, health: String, temperature: Double?, power: Double?)?
        var hasMetrics = false
        for row in rows {
            if row.contains(where: { $0.lowercased().contains("process id") }) { break }
            let first = row[0].split(whereSeparator: { $0.isWhitespace })
            guard let token = first.first, let id = Int(token) else { continue }
            if first.count >= 2 && Int(first[1]) == nil {
                if pending != nil && !hasMetrics { throw MonitorError.message("昇腾输出存在无法解析的设备指标行。") }
                let values = row.count > 2 ? row[2].split(whereSeparator: { $0.isWhitespace }) : []
                pending = (id, first.dropFirst().joined(separator: " "), row.count > 1 ? row[1] : "UNKNOWN", values.count > 1 ? number(String(values[1])) : nil, values.first.flatMap { number(String($0)) })
                hasMetrics = false
            } else if let device = pending, row.count >= 3 {
                let metrics = row.dropFirst(2).joined(separator: " ")
                let matches = capture(#"(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)"#, in: metrics)
                guard let memory = matches.last, memory.count == 2 else { throw MonitorError.message("无法解析昇腾内存指标；当前驱动输出格式暂不兼容。") }
                let utilToken = metrics.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                let chip = Int(first[0]) ?? 0
                result.append(Accelerator(id: "npu-\(device.index)-\(chip)", index: device.index, chip: chip, kind: .ascend,
                                          name: device.name, utilization: percent(utilToken), memoryUsedMiB: number(memory[0]), memoryTotalMiB: number(memory[1]), temperature: device.temperature, health: device.health, powerWatts: device.power))
                hasMetrics = true
            }
        }
        if pending != nil && !hasMetrics { throw MonitorError.message("昇腾设备指标不完整。") }
        guard Set(result.map(\.id)).count == result.count else { throw MonitorError.message("昇腾设备编号重复，暂不支持此输出格式。") }
        return result
    }

    static func ascendInlineProcesses(_ lines: [String], index: Int, chip: Int?, owners: [Int: (String, String)]) -> (processes: [ComputeProcess], recognized: Bool) {
        var header = false, malformed = false, result: [ComputeProcess] = []
        for line in lines {
            let row = table(line)
            if row.contains(where: { $0.lowercased().contains("process id") }) { header = true; continue }
            guard header else { continue }
            if line.lowercased().contains("no running process") { continue }
            guard !row.isEmpty else { continue }
            let ids = row[0].split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard ids.count >= 2, row.count >= 4, let pid = Int(row[1]) else { malformed = true; continue }
            guard ids[0] == index, chip == nil || ids[1] == chip else { continue }
            result.append(ComputeProcess(pid: pid, user: owners[pid]?.0, name: row[2], memoryMiB: number(row[3])))
        }
        return (result, header && !malformed)
    }

    static func ascendProcesses(_ lines: [String], chip: Int?, owners: [Int: (String, String)]) -> (processes: [ComputeProcess], recognized: Bool) {
        var header: [String] = [], result: [ComputeProcess] = [], valid = false, malformed = false
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("no running process") || lower.contains("no process") { valid = true; continue }
            let row = table(line)
            if row.contains(where: { $0.lowercased().contains("process id") || $0.lowercased() == "pid" }) { header = row.map { $0.lowercased() }; valid = true; continue }
            guard !row.isEmpty, !header.isEmpty else { continue }
            guard let pidColumn = header.firstIndex(where: { $0.contains("process id") || $0 == "pid" }), pidColumn < row.count,
                  let pid = Int(row[pidColumn]) else { if row.contains(where: { Int($0) != nil }) { malformed = true }; continue }
            if let chipColumn = header.firstIndex(where: { $0.contains("chip") }), chipColumn < row.count,
               let actual = Int(row[chipColumn]), let chip, actual != chip { continue }
            let memoryColumn = header.firstIndex { $0.contains("memory") }
            let memory = memoryColumn.flatMap { $0 < row.count ? number(row[$0]) : nil }
            result.append(ComputeProcess(pid: pid, user: owners[pid]?.0, name: owners[pid]?.1 ?? "未知进程", memoryMiB: memory))
        }
        return (result, valid && !malformed)
    }

    static func table(_ line: String) -> [String] {
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return [] }
        return line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    static func number(_ value: String) -> Double? {
        guard let result = Double(value.trimmingCharacters(in: .whitespaces)), result.isFinite, result >= 0 else { return nil }
        return result
    }
    static func percent(_ value: String) -> Double? { number(value).flatMap { $0 <= 100 ? $0 : nil } }
    static func capture(_ pattern: String, in value: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: value).map { String(value[$0]) } }
        }
    }
    static func csv(_ line: String) -> [String] {
        var result: [String] = [], value = "", quoted = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i], next = line.index(after: i)
            if c == "\"" {
                if quoted, next < line.endIndex, line[next] == "\"" { value.append("\""); i = line.index(after: next); continue }
                quoted.toggle()
            } else if c == ",", !quoted { result.append(value.trimmingCharacters(in: .whitespaces)); value = "" }
            else { value.append(c) }
            i = next
        }
        result.append(value.trimmingCharacters(in: .whitespaces))
        return result
    }
}
