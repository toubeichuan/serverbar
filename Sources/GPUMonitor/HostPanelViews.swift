import SwiftUI

struct HostPanelSelection: Identifiable {
    let serverID: UUID
    let panel: MonitorPanel
    var id: String { "\(serverID)-\(panel.rawValue)" }
}

/// The same live data is used in server panels and overview detail sheets.
struct HostResourcePanel: View {
    let panel: MonitorPanel
    let telemetry: HostTelemetry?
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(panel.title, systemImage: panel.symbol).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(panel.tint)
                Spacer()
                if stale { Text("数据过期").font(.caption).foregroundStyle(.orange) }
            }
            if let telemetry {
                HostMetricContent(panel: panel, telemetry: telemetry)
            } else {
                Text("等待采集数据…").font(.callout).foregroundStyle(.secondary)
            }
        }.padding(18).frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
            .monitorSurface(radius: 10)
    }
}

struct HostPanelDetail: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.dismiss) var dismiss
    let selection: HostPanelSelection
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(selection.panel.title, systemImage: selection.panel.symbol).font(.title2.weight(.medium))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(store.servers.first { $0.id == selection.serverID }?.name ?? "").foregroundStyle(.secondary)
            if store.statuses[selection.serverID]?.stale(interval: store.interval) != false {
                Label("数据已过期", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ScrollView {
                if let t = store.statuses[selection.serverID]?.snapshot?.telemetry {
                    HostMetricContent(panel: selection.panel, telemetry: t)
                } else { Text("没有可用的采集数据。").foregroundStyle(.secondary) }
            }.frame(maxHeight: 500)
        }.padding(26).frame(width: 650).background(MonitorBackdrop())
    }
}

struct HostMetricContent: View {
    let panel: MonitorPanel
    let telemetry: HostTelemetry
    @State private var showCores = false
    var body: some View {
        Group {
            switch panel {
            case .cpu: cpu
            case .memory: memory
            case .network: network
            case .disk: disks
            case .gpu: EmptyView()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var cpu: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                headline(telemetry.cpuUsage.map { String(format: "%.1f%%", $0) } ?? "采样中")
                Spacer()
                Text("\(telemetry.coreCount) 逻辑核心").font(.caption).foregroundStyle(.secondary)
            }
            MetricBar(value: telemetry.cpuUsage.map { $0 / 100 }, tint: panel.tint)
            Text(telemetry.cpuModel ?? "CPU 型号不可用").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            pair("负载 1 / 5 / 15 分钟", telemetry.load.isEmpty ? "—" : telemetry.load.map { String(format: "%.2f", $0) }.joined(separator: " / "))
            DisclosureGroup("各逻辑核心使用率", isExpanded: $showCores) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 65), spacing: 6)], spacing: 6) {
                        ForEach(telemetry.cpuTicks.keys.filter { $0 != "cpu" }.sorted { (Int($0.dropFirst(3)) ?? 0) < (Int($1.dropFirst(3)) ?? 0) }, id: \.self) { name in
                            VStack(spacing: 6) {
                                Text(name).foregroundStyle(.secondary)
                                Text(telemetry.coreUsage[name].map { "\(Int($0))%" } ?? "—").monospacedDigit()
                                MetricBar(value: telemetry.coreUsage[name].map { $0 / 100 }, tint: panel.tint)
                            }.font(.system(size: 10, design: .monospaced)).padding(8).monitorSurface(radius: 5)
                        }
                    }.padding(.top, 8)
                }.frame(maxHeight: 260)
            }.font(.system(size: 12))
        }
    }
    private var memory: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline(memoryText(telemetry.memoryUsedMiB))
            MetricBar(value: memoryFraction, tint: panel.tint)
            pair("总内存", memoryText(telemetry.memoryTotalMiB))
            pair("可用（含可回收缓存）", memoryText(telemetry.memoryAvailableMiB))
            pair("Swap 总量 / 可用", "\(memoryText(telemetry.swapTotalMiB)) / \(memoryText(telemetry.swapFreeMiB))")
            Text("已用 = 总内存 − 可用内存").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var memoryFraction: Double? {
        guard let used = telemetry.memoryUsedMiB, let total = telemetry.memoryTotalMiB, total > 0 else { return nil }
        return used / total
    }
    private var network: some View {
        VStack(alignment: .leading, spacing: 12) {
            if telemetry.interfaces.isEmpty { Text("未读取到网络接口。").foregroundStyle(.secondary) }
            ForEach(telemetry.interfaces) { interface in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(interface.name).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        if interface.name == telemetry.primaryNetwork?.name { Text("总览网卡").font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack {
                        rate("接收 ↓", interface.receiveRate)
                        Spacer()
                        rate("发送 ↑", interface.sendRate)
                    }
                    Text("累计接收 \(memoryText(interface.received / 1_048_576)) · 发送 \(memoryText(interface.sent / 1_048_576))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if interface.id != telemetry.interfaces.last?.id { Divider() }
            }
        }
    }
    private var disks: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                rate("读取", telemetry.diskReadRate)
                Spacer()
                rate("写入", telemetry.diskWriteRate)
            }
            Text("\(telemetry.disks.count) 块盘 · \(telemetry.volumes.count) 个挂载卷").font(.caption).foregroundStyle(.secondary)
            if telemetry.volumes.isEmpty { Text("未读取到本地磁盘卷。").foregroundStyle(.secondary) }
            ForEach(telemetry.volumes) { volume in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(volume.mount).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                        Spacer()
                        Text(volume.source).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    MetricBar(value: volume.totalKiB > 0 ? volume.usedKiB / volume.totalKiB : nil, tint: panel.tint)
                    pair("已用 / 总量", "\(diskCapacityText(volume.usedKiB)) / \(diskCapacityText(volume.totalKiB))")
                    pair("可用", diskCapacityText(volume.availableKiB))
                }
                Divider()
            }
            ForEach(telemetry.disks) { disk in
                VStack(alignment: .leading, spacing: 6) {
                    pair(disk.name, disk.capacityBytes.map { memoryText($0 / 1_048_576) } ?? "容量未知")
                    pair("读 / 写", "\(rateText(disk.readRate)) / \(rateText(disk.writeRate))")
                }
            }
            Text("容量按挂载卷显示，读写按整盘统计；首次采样等待速率。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func headline(_ value: String) -> some View {
        Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
    }
    private func rate(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(rateText(value)).font(.system(size: 17, weight: .medium)).monospacedDigit()
        }
    }
    private func pair(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12))
    }
}
