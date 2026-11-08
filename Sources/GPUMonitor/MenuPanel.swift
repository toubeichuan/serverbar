import SwiftUI
import AppKit

struct MenuPanel: View {
    var availableContentHeight: CGFloat? = nil
    var openMainAction: (() -> Void)? = nil
    @EnvironmentObject private var store: MonitorStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance") private var appearance = "system"
    @State private var collapsed = Set<UUID>()
    private var contentHeight: CGFloat { availableContentHeight ?? min(620, max(280, (NSScreen.main?.visibleFrame.height ?? 800) - 160)) }
    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                VStack(spacing: 0) {
                    heading(at: context.date)
                    Divider()
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(store.servers) { server in serverSection(server, date: context.date) }
                            if store.servers.isEmpty {
                                Text("添加 SSH 服务器后，这里会显示设备和系统资源。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                                Button("添加服务器") { store.showAdd = true; showMain() }
                            }
                        }.padding(14)
                    }.frame(height: contentHeight)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button("打开总览") { store.showSettings = false; showMain() }
                Spacer()
                Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }.disabled(store.paused || store.isDemo).help("刷新")
                Button(store.paused ? "恢复" : "暂停") { store.togglePause() }.disabled(store.isDemo)
                Button { store.showSettings = true; showMain() } label: { Image(systemName: "gearshape") }.help("设置")
                Button("退出") { NSApp.terminate(nil) }
            }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 11)
        }.frame(width: 560).background(MonitorTheme.background)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
    }
    private func showMain() {
        if let openMainAction { openMainAction() }
        else { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    }
    private func heading(at date: Date) -> some View {
        let summary = store.summary(at: date)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("ServerBar").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(store.isDemo ? "演示数据" : store.paused ? "已暂停" : "每 \(Int(store.interval)) 秒更新")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("\(store.servers.count) 台服务器").font(.system(size: 11)).foregroundStyle(.secondary)
                if store.panels.visible.contains(.gpu) {
                    StateBadge(title: "\(summary.idle) 空闲", tint: .green)
                    StateBadge(title: "\(summary.occupied) 占用", tint: .orange)
                    if summary.unknown > 0 { StateBadge(title: "\(summary.unknown) 未知", tint: .secondary) }
                }
                Spacer()
                if summary.unavailable > 0 { Text("\(summary.unavailable) 台待确认").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }.padding(.horizontal, 16).padding(.vertical, 13)
    }
    private func serverSection(_ server: Server, date: Date) -> some View {
        let status = store.statuses[server.id] ?? ServerStatus()
        let stale = !server.enabled || status.stale(at: date, interval: store.interval)
        let gpuStale = stale || status.snapshot?.gpuError != nil
        let devices = status.snapshot?.devices ?? []
        let idle = gpuStale ? 0 : devices.filter { $0.state == .idle }.count
        let occupied = gpuStale ? 0 : devices.filter { $0.state == .busy || $0.state == .occupied }.count
        let model = Set(devices.map(\.shortName)).sorted().joined(separator: " / ")
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if collapsed.contains(server.id) { collapsed.remove(server.id) } else { collapsed.insert(server.id) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        Text(server.name).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(!server.enabled ? "已停用" : status.snapshot == nil && status.error == nil ? "连接中" : stale ? "离线 / 过期" : "在线")
                            .font(.system(size: 10)).foregroundStyle(stale ? Color.secondary : Color.green)
                        Image(systemName: collapsed.contains(server.id) ? "chevron.right" : "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.font(.system(size: 13))
                    HStack {
                        Text(model.isEmpty ? server.host : model).lineLimit(1)
                        Spacer(minLength: 4)
                        if store.panels.visible.contains(.gpu), !devices.isEmpty {
                            Text(gpuStale ? "设备数据待确认" : "\(devices.count) 张卡 · \(idle) 空闲 · \(occupied) 占用")
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("展开或收起 \(server.name) 的逐卡信息")
            if !collapsed.contains(server.id), store.panels.visible.contains(.gpu), !devices.isEmpty {
                VStack(spacing: 1) {
                    columnHeadings(devices)
                    ForEach(devices) { device in
                        Button {
                            store.showSettings = false
                            store.selectedDevice = CardSelection(serverID: server.id, deviceID: device.id)
                            showMain()
                        } label: { deviceRow(device, stale: gpuStale) }
                            .buttonStyle(.plain)
                            .help("\(device.name) · \(device.occupancyReason)\n\(device.processes.first.map { $0.program ?? $0.name } ?? "无计算进程")\n点击查看程序、PID 和完整指标")
                    }
                }
            }
            if let telemetry = status.snapshot?.telemetry {
                systemSummary(telemetry, stale: stale)
            }
            if let error = status.error ?? status.snapshot?.gpuError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).help(error)
            }
        }.padding(11).monitorSurface(radius: 9)
    }
    private func columnHeadings(_ devices: [Accelerator]) -> some View {
        HStack(spacing: 8) {
            Text("设备").frame(width: 68, alignment: .leading)
            Text(devices.allSatisfy { $0.kind == .ascend } ? "AI Core" : "利用率").frame(width: 67, alignment: .trailing)
            Text("显存 已用/总量").frame(width: 133, alignment: .trailing)
            Text("温度").frame(width: 48, alignment: .trailing)
            Text("使用者").frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 4)
    }
    private func deviceRow(_ device: Accelerator, stale: Bool) -> some View {
        let tint: Color = stale ? .secondary : device.state.tint
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: stale || device.state == .unknown ? "questionmark.circle" : device.state == .idle ? "checkmark.circle.fill" : "circle.inset.filled")
                    .foregroundStyle(tint).font(.system(size: 10))
                Text(device.compactLabel).fontWeight(.medium)
            }.frame(width: 68, alignment: .leading)
            HStack(spacing: 5) {
                MetricBar(value: device.utilization.map { $0 / 100 }, tint: tint).frame(width: 23)
                Text(device.utilization.map { "\(Int($0))%" } ?? "—").frame(width: 39, alignment: .trailing)
            }.frame(width: 67, alignment: .trailing)
            Text("\(memoryText(device.memoryUsedMiB).replacingOccurrences(of: " GiB", with: "")) / \(memoryText(device.memoryTotalMiB))")
                .frame(width: 133, alignment: .trailing)
            Text(device.temperature.map { "\(Int($0))°C" } ?? "—").frame(width: 48, alignment: .trailing)
            Text(device.processes.isEmpty ? (device.processesKnown ? "—" : "未知") : device.owners)
                .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1).truncationMode(.middle)
        }.font(.system(size: 11)).monospacedDigit().foregroundStyle(stale ? .secondary : .primary)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(tint.opacity(stale ? 0.025 : 0.045), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .accessibilityLabel("\(device.compactLabel)，\(stale ? "数据过期" : device.availabilityTitle)，利用率 \(device.utilization.map { "\(Int($0))%" } ?? "未知")，显存 \(memoryText(device.memoryUsedMiB)) / \(memoryText(device.memoryTotalMiB))，\(device.owners)")
    }
    private func systemSummary(_ telemetry: HostTelemetry, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 16) {
                if store.panels.visible.contains(.cpu) {
                    metric("CPU", telemetry.cpuUsage.map { "\(Int($0))%" } ?? "采样中", tint: .purple)
                }
                if store.panels.visible.contains(.memory) {
                    metric("内存", "\(memoryText(telemetry.memoryUsedMiB).replacingOccurrences(of: " GiB", with: "")) / \(memoryText(telemetry.memoryTotalMiB))", tint: .teal)
                }
                Spacer(minLength: 0)
                if stale { Text("上次数据").foregroundStyle(.secondary) }
            }
            if store.panels.visible.contains(.network) {
                metric("网络", "↓ \(rateText(telemetry.primaryNetwork?.receiveRate))   ↑ \(rateText(telemetry.primaryNetwork?.sendRate))", tint: .blue)
            }
            if store.panels.visible.contains(.disk) {
                metric("磁盘", telemetry.disks.isEmpty ? "数据不可用" : "读 \(rateText(telemetry.diskReadRate))   写 \(rateText(telemetry.diskWriteRate))", tint: .pink)
            }
        }.font(.system(size: 10)).monospacedDigit().padding(.top, 3)
    }
    private func metric(_ title: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 6) { Text(title).foregroundStyle(tint); Text(value).foregroundStyle(.secondary).lineLimit(1) }
    }
}
