import SwiftUI

struct MonitorSettingsView: View {
    @EnvironmentObject var store: MonitorStore
    @AppStorage("statusBarOnly") private var statusBarOnly = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("denseLayout") private var dense = true
    @AppStorage("showTemperature") private var showTemperature = true
    @AppStorage("showOwners") private var showOwners = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("设置").font(.system(size: 20, weight: .semibold)); Spacer(); Button("返回总览") { store.showSettings = false } }.padding(20)
            Divider()
            Form {
                Section("运行方式") {
                    Toggle("仅状态栏运行", isOn: $statusBarOnly)
                    Text("不显示 Dock 图标，启动时不打开主窗口。顶部图标旁的数字是空闲卡数 / 总卡数；点击可查看详情或退出。关闭总览后继续监控。").font(.caption).foregroundStyle(.secondary)
                }
                Section("外观与布局") {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    Toggle("紧凑布局", isOn: $dense)
                    Text("每行 8 张卡，所有设备使用相同尺寸。").font(.caption).foregroundStyle(.secondary)
                    Toggle("卡片显示温度", isOn: $showTemperature)
                    Toggle("卡片显示使用者", isOn: $showOwners)
                }
                Section("监控资源") {
                    ForEach(MonitorPanel.allCases) { panel in
                        Toggle(panel.title, isOn: Binding(get: { store.panels.visible.contains(panel) }, set: { store.setPanel(panel, visible: $0) }))
                            .disabled(store.panels.visible.count == 1 && store.panels.visible.contains(panel))
                    }
                    Text("总览显示资源摘要；选择具体服务器后，已启用的资源展开为独立面板。关闭的资源不再采集。").font(.caption).foregroundStyle(.secondary)
                }
                Section("刷新") {
                    Picker("自动刷新间隔", selection: Binding(get: { store.interval }, set: { store.setInterval($0) })) {
                        ForEach([10.0, 20, 30, 60], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                    }
                    HStack { Text(store.paused ? "监控已暂停" : "正在自动监控"); Spacer(); Button(store.paused ? "恢复监控" : "暂停监控") { store.togglePause() }.disabled(store.isDemo) }
                }
                Section("状态说明") {
                    Label("空闲：没有计算进程，计算负载及设备内存占用低。", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Label("占用：正在计算，或进程 / 设备内存仍有占用。", systemImage: "circle.inset.filled").foregroundStyle(.orange)
                    Label("未知 / 过期：信息不足或连接异常，不计入空闲。", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                    Text("NVIDIA 空闲判定排除已识别的纯图形桌面进程（Xorg、Xwayland、GNOME / KDE）的实测显存，界面仍显示总显存。计算进程、其他程序及无法识别的显存不会被忽略；桌面进程采集失败时不扣除。").font(.caption).foregroundStyle(.secondary)
                    Text("910B 的约 3.3 GiB 常驻 HBM 不直接算作任务占用：无进程、AI Core <5%、健康正常且 HBM ≤ min(4 GiB, 总量的 6%) 才显示空闲。该容差为启发式，HBM 数值仍显示实测总占用。").font(.caption).foregroundStyle(.secondary)
                    Text("空闲是监测结果，不代表已经预留。昇腾 Chip 表示设备内部芯片编号，仅在详情中显示。").font(.caption).foregroundStyle(.secondary)
                }
                Section("服务器") {
                    Button("从 SSH 配置导入 / 手动添加…") { store.showAdd = true }.disabled(store.isDemo)
                    Button(store.isDemo ? "退出演示数据" : "查看演示数据") {
                        store.selectedDevice = nil
                        if store.isDemo { store.leaveDemo() } else { store.enterDemo() }
                    }
                }
            }.formStyle(.grouped)
        }
    }
}

struct HostMetricSummary: View {
    let panel: MonitorPanel
    let telemetry: HostTelemetry?
    let stale: Bool
    private var value: String {
        guard let t = telemetry else { return "—" }
        switch panel {
        case .cpu: return t.cpuUsage.map { "\(Int($0))%" } ?? "采样中"
        case .memory: return "\(memoryText(t.memoryUsedMiB).replacingOccurrences(of: " GiB", with: ""))/\(memoryText(t.memoryTotalMiB))"
        case .network: return "↓ \(rateText(t.primaryNetwork?.receiveRate))  ↑ \(rateText(t.primaryNetwork?.sendRate))"
        case .disk: return t.disks.isEmpty ? "无可用读写数据" : "读 \(rateText(t.diskReadRate))  写 \(rateText(t.diskWriteRate))"
        case .gpu: return ""
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(panel.tint).frame(width: 5, height: 5)
            Text(panel.title).foregroundStyle(panel.tint)
            Text(value).monospacedDigit().foregroundStyle(stale ? .secondary : .primary)
            if stale && telemetry != nil { Text("过期").foregroundStyle(.secondary) }
        }.font(.system(size: 11)).lineLimit(1)
    }
}
