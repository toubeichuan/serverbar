import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var store: MonitorStore
    @State private var selectedServer: UUID?
    @State private var editing: Server?
    @State private var hostDetail: HostPanelSelection?
    @State private var query = ""
    @State private var onlyIdle = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("denseLayout") private var dense = true
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                if store.showSettings {
                    MonitorSettingsView().environmentObject(store)
                } else {
                    header
                    Divider()
                    if let error = store.appError {
                        HStack { Text(error); Spacer(); Button("关闭") { store.appError = nil } }
                            .font(.caption).padding(12).foregroundStyle(.orange)
                    }
                    // MonitorStore already publishes a polling clock. Keep the scroll
                    // container outside a TimelineView so refreshes preserve its position.
                    ScrollView {
                        VStack(alignment: .leading, spacing: dense ? 14 : 24) {
                            if store.servers.isEmpty { emptyState }
                            ForEach(filteredServers) { server in serverSection(server, at: Date()) }
                            if !store.servers.isEmpty && filteredServers.isEmpty {
                                Text("没有匹配的服务器").foregroundStyle(.secondary).padding(20)
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    footer
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MonitorTheme.background)
        .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        .tint(.accentColor)
        .frame(minWidth: 1080, minHeight: 660)
        .sheet(isPresented: $store.showAdd) { AddServerView().environmentObject(store) }
        .sheet(item: $editing) { ServerEditor(server: $0).environmentObject(store) }
        .sheet(item: $store.selectedDevice) { selection in
            if let server = store.servers.first(where: { $0.id == selection.serverID }) {
                DeviceDetail(server: server, deviceID: selection.deviceID).environmentObject(store)
            }
        }
        .sheet(item: $hostDetail) { HostPanelDetail(selection: $0).environmentObject(store) }
        .onChange(of: store.isDemo) { _ in selectedServer = nil; query = "" }
    }
    private var filteredServers: [Server] {
        store.servers.filter { server in
            (selectedServer == nil || server.id == selectedServer) &&
            (selectedServer != nil || query.isEmpty || server.name.localizedCaseInsensitiveContains(query) || server.host.localizedCaseInsensitiveContains(query))
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                Button { sidebarCollapsed.toggle() } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 14))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help(sidebarCollapsed ? "展开侧栏" : "收起侧栏")
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }.padding(.top, 8).padding(.bottom, 8)
            navigationRow("总览", symbol: "square.grid.2x2", selected: selectedServer == nil && !store.showSettings) { selectedServer = nil; store.showSettings = false }
            if !sidebarCollapsed {
                Text("服务器").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(store.servers.enumerated()), id: \.element.id) { offset, server in
                        navigationRow(sidebarCollapsed ? "\(offset + 1)" : server.name, symbol: "server.rack", selected: selectedServer == server.id && !store.showSettings, compactNumber: offset + 1) { selectedServer = server.id; store.showSettings = false }.help(server.name)
                    }
                }
            }
            VStack(spacing: 5) {
                sideAction("刷新", symbol: "arrow.clockwise", disabled: store.paused || store.isDemo) { store.refreshAll() }
                sideAction(store.paused ? "恢复监控" : "暂停监控", symbol: store.paused ? "play" : "pause", disabled: store.isDemo) { store.togglePause() }
                sideAction("添加服务器", symbol: "plus", disabled: store.isDemo) { store.showAdd = true }
                navigationRow("设置", symbol: "gearshape", selected: store.showSettings) { store.showSettings = true }
            }.padding(5).subtleGlass(radius: 10)
            if !sidebarCollapsed { Text("ServerBar  0.6").font(.system(size: 10)).foregroundStyle(.tertiary).padding(10) }
        }.padding(.horizontal, 10).padding(.bottom, 10)
            .frame(width: sidebarCollapsed ? 58 : 166).frame(maxHeight: .infinity)
            .background { SidebarGlass() }
    }
    private func navigationRow(_ title: String, symbol: String, selected: Bool, compactNumber: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if sidebarCollapsed { Spacer(minLength: 0) }
                if sidebarCollapsed, let compactNumber { Text("\(compactNumber)").font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 15) }
                else { Image(systemName: symbol).frame(width: 15) }
                if !sidebarCollapsed { Text(title).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0)
            }.font(.system(size: 12, weight: selected ? .medium : .regular)).padding(.horizontal, sidebarCollapsed ? 5 : 10).padding(.vertical, 9)
                .background(selected ? Color.primary.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title)
    }
    private func sideAction(_ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        navigationRow(title, symbol: symbol, selected: false, action: action).disabled(disabled)
    }
    private var header: some View {
        let summary = store.summary(at: Date(), serverID: selectedServer)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedServer.flatMap { id in store.servers.first { $0.id == id }?.name } ?? "总览").font(.system(size: 20, weight: .semibold))
                if store.isDemo { StateBadge(title: "演示数据", tint: .orange) }
                Spacer()
                if selectedServer == nil {
                    HStack(spacing: 6) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索服务器", text: $query).textFieldStyle(.plain) }
                        .font(.system(size: 12)).padding(7).frame(width: 180).monitorSurface(radius: 6)
                } else {
                    Button("返回总览") { selectedServer = nil }
                }
            }
            HStack(spacing: 12) {
                Text((selectedServer == nil ? "\(store.servers.count) 台服务器" : "服务器详情") + (store.panels.visible.contains(.gpu) ? " · \(summary.total) 张卡" : "")).foregroundStyle(.secondary)
                if store.panels.visible.contains(.gpu) {
                    StateBadge(title: "\(summary.idle) 空闲", tint: MonitorTheme.mint)
                    StateBadge(title: "\(summary.occupied) 占用", tint: MonitorTheme.amber)
                    if summary.unknown > 0 { StateBadge(title: "\(summary.unknown) 未知", tint: .secondary) }
                }
                Spacer()
                if store.panels.visible.contains(.gpu) && selectedServer == nil {
                    Toggle("只看空闲", isOn: $onlyIdle).toggleStyle(.checkbox)

                }
            }.font(.system(size: 11))
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(store.paused ? Color.orange : Color.green).frame(width: 5, height: 5)
            Text(store.isDemo ? "演示模式" : store.paused ? "已暂停" : "每 \(Int(store.interval)) 秒更新")
            Spacer()
            Text("点击卡片查看进程与详情")
            Text("· SSH 只读")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9).overlay(alignment: .top) { Divider() }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加第一台服务器").font(.title2)
            Text("从 SSH 配置导入，或手动添加连接。").foregroundStyle(.secondary)
            Button("添加服务器") { store.showAdd = true }
            Button("查看演示") { store.enterDemo() }
        }.padding(30)
    }
    private func serverSection(_ server: Server, at date: Date) -> some View {
        let status = store.statuses[server.id] ?? ServerStatus()
        let stale = !server.enabled || status.stale(at: date, interval: store.interval)
        let gpuStale = stale || status.snapshot?.gpuError != nil
        let devices = status.snapshot?.devices ?? []
        let shown = onlyIdle && selectedServer == nil ? devices.filter { !gpuStale && $0.state == .idle } : devices
        let idle = gpuStale ? 0 : devices.filter { $0.state == .idle }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { selectedServer = server.id; query = "" } label: {
                    HStack(spacing: 5) {
                        Text(server.name).font(.system(size: 13, weight: .semibold))
                        if selectedServer == nil { Image(systemName: "chevron.right").font(.system(size: 9)) }
                    }
                }.buttonStyle(.plain).help("打开服务器详情")
                Text(devices.first?.shortName ?? server.host).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(!server.enabled ? "停用" : status.snapshot == nil && status.error == nil ? "连接中" : stale ? "离线 / 过期" : !store.panels.visible.contains(.gpu) ? "在线" : gpuStale ? "设备状态未知" : "\(idle)/\(devices.count) 空闲")
                    .font(.system(size: 10)).foregroundStyle(stale ? Color.secondary : .primary)
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)).foregroundStyle(.secondary).opacity(status.refreshing ? 1 : 0).frame(width: 12)
                Menu {
                    Button("立即刷新") { store.refresh(server) }.disabled(store.isDemo || store.paused)
                    Button("编辑服务器…") { editing = server }.disabled(store.isDemo)
                    Button(server.enabled ? "停用监控" : "启用监控") { var s = server; s.enabled.toggle(); store.update(s) }.disabled(store.isDemo)
                    Button("移除服务器", role: .destructive) { store.remove(server); if selectedServer == server.id { selectedServer = nil } }.disabled(store.isDemo)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18)
            }
            if let error = status.error ?? status.snapshot?.gpuError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).help(error)
            }
            ForEach(status.snapshot?.warnings ?? [], id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            if store.panels.visible.contains(.gpu) {
                if devices.isEmpty { Text(stale && status.error != nil ? "无法读取设备" : "正在读取设备…").font(.caption).foregroundStyle(.secondary).frame(height: 70) }
                else if shown.isEmpty { Text("当前没有已确认空闲的卡").font(.caption).foregroundStyle(.secondary).padding(.vertical, 10) }
                else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 8), spacing: 7) {
                        ForEach(shown) { device in
                            Button { store.selectedDevice = CardSelection(serverID: server.id, deviceID: device.id) } label: { DeviceCard(device: device, stale: gpuStale) }
                                .buttonStyle(.plain).help("\(device.name) · \(device.occupancyReason) · 点击查看详情")
                        }
                    }
                }
            }
            if selectedServer != nil {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(MonitorPanel.allCases.filter { $0 != .gpu && store.panels.visible.contains($0) }) { panel in
                        HostResourcePanel(panel: panel, telemetry: status.snapshot?.telemetry, stale: stale)
                    }
                }.padding(.top, 4)
            } else {
                ViewThatFits(in: .horizontal) {
                    resourceSummary(server, status: status, stale: stale, vertical: false)
                    resourceSummary(server, status: status, stale: stale, vertical: true)
                }
            }
            Divider().padding(.top, 4)
        }
    }
    private func resourceSummary(_ server: Server, status: ServerStatus, stale: Bool, vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 14))
        return layout {
                ForEach(MonitorPanel.allCases.filter { $0 != .gpu && store.panels.visible.contains($0) }) { panel in
                    Button { hostDetail = HostPanelSelection(serverID: server.id, panel: panel) } label: {
                        HostMetricSummary(panel: panel, telemetry: status.snapshot?.telemetry, stale: stale)
                    }.buttonStyle(.plain).help("查看\(panel.title)详情")
                }
        }.fixedSize(horizontal: !vertical, vertical: false)
    }
}

struct DeviceCard: View {
    let device: Accelerator
    let stale: Bool
    @AppStorage("showTemperature") private var showTemperature = true
    @AppStorage("showOwners") private var showOwners = true
    @AppStorage("denseLayout") private var dense = true
    @State private var hovering = false
    private var tint: Color { stale ? .secondary : device.state.tint }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 2) {
                Text(device.compactLabel).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer(minLength: 1)
                Image(systemName: stale ? "questionmark.circle" : device.state == .idle ? "checkmark.circle.fill" : device.availabilityTitle == "占用" ? "circle.inset.filled" : "questionmark.circle")
                    .foregroundStyle(tint).font(.system(size: 12))
                    .help(stale ? "数据过期" : device.availabilityTitle)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(device.utilization.map { "\(Int($0))%" } ?? "—").font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                Spacer(minLength: 1)
                if showTemperature { Text(device.temperature.map { "\(Int($0))°" } ?? "—°").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary) }
            }
            Text(device.kind == .ascend ? "AI Core" : "GPU 利用率").font(.system(size: 10)).foregroundStyle(.secondary)
            MetricBar(value: device.utilization.map { $0 / 100 }, tint: tint)
            HStack(spacing: 2) {
                Text(device.kind == .ascend ? "HBM" : "显存").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(shortMemory(device.memoryUsedMiB))/\(shortMemory(device.memoryTotalMiB))G").monospacedDigit()
            }.font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
            if showOwners { Text(device.processes.isEmpty ? (device.processesKnown ? "无计算进程" : "用户未知") : device.owners).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
        }.padding(10).frame(maxWidth: .infinity).frame(height: dense ? 126 : 150)
            .background(tint.opacity(hovering ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(tint.opacity(stale ? 0.16 : 0.30), lineWidth: 0.8))
            .onHover { hovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(device.compactLabel)，\(stale ? "数据过期" : device.availabilityTitle)，\(device.metric) \(device.utilization.map { "\(Int($0))%" } ?? "未知")，\(device.owners)")
    }
    private func shortMemory(_ value: Double?) -> String { value.map { String(format: $0 >= 10240 ? "%.0f" : "%.1f", $0 / 1024) } ?? "—" }
}
