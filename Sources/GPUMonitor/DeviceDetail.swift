import SwiftUI

struct DeviceDetail: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.dismiss) var dismiss
    let server: Server
    let deviceID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备详情").font(.system(size: 10, design: .monospaced)).tracking(2).foregroundStyle(MonitorTheme.cyan)
                    Text(server.name).font(.title2.weight(.medium))
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let device = store.statuses[server.id]?.snapshot?.devices.first(where: { $0.id == deviceID }) {
                HStack {
                    Text("\(device.label) · \(device.name)").font(.system(size: 14, weight: .medium))
                    Spacer()
                    StateBadge(title: device.availabilityTitle, tint: device.state.tint)
                }
                if store.statuses[server.id]?.stale(interval: store.interval) != false || store.statuses[server.id]?.snapshot?.gpuError != nil {
                    Label("此数据已过期。", systemImage: "exclamationmark.triangle").foregroundStyle(MonitorTheme.amber)
                }
                Text(device.occupancyReason).font(.caption).foregroundStyle(.secondary)
                if device.usesAscendMemoryTolerance {
                    Text("HBM 保留驱动报告的总占用；空闲判定容差 \(memoryText(device.idleMemoryLimitMiB))，不是精确测得的系统预留量。有计算进程时始终视为占用。").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    detailMetric(device.metric, device.utilization.map { "\(Int($0))%" } ?? "—")
                    detailMetric("设备内存", memoryText(device.memoryUsedMiB))
                    detailMetric("温度", device.temperature.map { "\(Int($0)) °C" } ?? "—")
                    detailMetric("功耗", device.powerWatts.map { String(format: "%.0f W", $0) } ?? "—")
                    detailMetric("健康", device.health ?? "—")
                }.padding(16).monitorSurface(radius: 16)
                HStack { Text("运行中的程序").font(.headline); Spacer(); Text("\(device.processes.count) 个进程").font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if device.processes.isEmpty {
                            Text(device.processesKnown ? "没有计算进程正在占用这张卡。" : "进程列表不可用，无法确认占用者。").foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                        ForEach(device.processes) { process in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "terminal").foregroundStyle(MonitorTheme.cyan)
                                    Text(process.program ?? process.name).font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
                                    Spacer()
                                    Text(memoryText(process.memoryMiB)).font(.system(size: 12, design: .monospaced))
                                }
                                HStack {
                                    Label(process.user ?? "用户未知", systemImage: "person")
                                    Text("PID \(process.pid)").monospaced()
                                    Spacer()
                                    if process.program == nil { Text("脚本名不可用") }
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).monitorSurface(radius: 14)
                        }
                    }
                }.frame(maxHeight: 260)
                Text("设备标识  \(device.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            } else { Text("设备已不在最新结果中。") }
        }.padding(26).frame(width: 720).background(MonitorBackdrop())
    }
    private func detailMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .medium, design: .monospaced))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
