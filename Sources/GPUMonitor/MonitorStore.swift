import SwiftUI
import AppKit

struct SavedConfiguration: Codable {
    var version = 1
    var servers: [Server] = []
    var interval: Double = 20
    var panels: PanelPreferences? = nil
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var servers: [Server] = []
    @Published var statuses: [UUID: ServerStatus] = [:]
    @Published var interval: Double = 20
    @Published var appError: String?
    @Published var isDemo = false
    @Published var paused = false
    @Published var showAdd = false
    @Published var showSettings = false
    @Published var panels = PanelPreferences()
    @Published var selectedDevice: CardSelection?
    @Published private var clock = Date()
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]
    private var pending: [UUID] = []
    private var poller: Task<Void, Never>?
    private var beforeDemo: [Server] = []
    private let configURL: URL

    init(configURL: URL? = nil, startPolling: Bool = true, demo: Bool = false) {
        self.configURL = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPUMonitor/servers.json")
        if FileManager.default.fileExists(atPath: self.configURL.path) {
            do {
                let config = try JSONDecoder().decode(SavedConfiguration.self, from: Data(contentsOf: self.configURL))
                guard config.version == 1, config.servers.allSatisfy({ $0.validationError == nil }),
                      Set(config.servers.map(\.id)).count == config.servers.count else { throw MonitorError.message("保存的服务器配置格式无效。") }
                servers = config.servers
                panels = config.panels ?? PanelPreferences()
                interval = [10.0, 20, 30, 60].contains(config.interval) ? config.interval : 20
            } catch { appError = "读取本地配置失败：\(error.localizedDescription)" }
        }
        if demo { enterDemo() }
        if startPolling {
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.clock = Date()
                    self.refreshAll()
                    try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                }
            }
        }
    }

    var menuTitle: String {
        let summary = summary(at: clock)
        return "\(summary.idle)/\(summary.total)"
    }

    func persist(_ servers: [Server], interval: Double? = nil) throws {
        let parent = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SavedConfiguration(servers: servers, interval: interval ?? self.interval, panels: panels)).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    @discardableResult
    func add(_ additions: [Server]) -> Bool {
        guard !isDemo else { appError = "请先退出演示，再添加真实服务器。"; return false }
        let existing = Set(servers.map { "\($0.host.lowercased())|\($0.port ?? 0)|\($0.user)" })
        let valid = additions.filter { !existing.contains("\($0.host.lowercased())|\($0.port ?? 0)|\($0.user)") }
        if let error = valid.compactMap(\.validationError).first { appError = error; return false }
        do {
            try persist(servers + valid)
            servers += valid
            for server in valid { refresh(server) }
            return true
        } catch { appError = "保存服务器失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult
    func update(_ server: Server) -> Bool {
        guard let index = servers.firstIndex(where: { $0.id == server.id }), server.validationError == nil, !isDemo else { return false }
        var updated = servers; updated[index] = server
        do {
            try persist(updated)
            cancel(server.id)
            servers = updated; statuses[server.id] = ServerStatus()
            refresh(server)
            return true
        } catch { appError = error.localizedDescription; return false }
    }

    func remove(_ server: Server) {
        guard !isDemo else { return }
        let updated = servers.filter { $0.id != server.id }
        do {
            try persist(updated)
            cancel(server.id)
            servers = updated; statuses.removeValue(forKey: server.id)
            drain()
        } catch { appError = error.localizedDescription }
    }

    func setInterval(_ value: Double) {
        guard [10.0, 20, 30, 60].contains(value) else { return }
        do { if !isDemo { try persist(servers, interval: value) }; interval = value }
        catch { appError = error.localizedDescription }
    }

    func setPanel(_ panel: MonitorPanel, visible: Bool) {
        var next = panels
        if visible { next.visible.insert(panel) } else { next.visible.remove(panel) }
        guard !next.visible.isEmpty else { return }
        let previous = panels
        panels = next
        do { if !isDemo { try persist(servers) } }
        catch { panels = previous; appError = error.localizedDescription; return }
        if !isDemo {
            for id in Array(jobs.keys) + pending { cancel(id) }
            refreshAll()
        }
    }

    func cancel(_ id: UUID) {
        tokens.removeValue(forKey: id)
        jobs.removeValue(forKey: id)?.cancel()
        pending.removeAll { $0 == id }
        statuses[id]?.refreshing = false
    }

    func togglePause() {
        paused.toggle()
        if paused { for id in Array(jobs.keys) + pending { cancel(id) } }
        else { refreshAll() }
    }

    func refreshAll() {
        if isDemo {
            for id in statuses.keys { statuses[id]?.snapshot?.date = Date() }
            return
        }
        guard !paused else { return }
        for server in servers where server.enabled { refresh(server) }
    }

    func refresh(_ server: Server) {
        guard !paused, !isDemo, server.enabled, jobs[server.id] == nil, !pending.contains(server.id) else { return }
        pending.append(server.id)
        statuses[server.id, default: ServerStatus()].refreshing = true
        drain()
    }

    private func drain() {
        while jobs.count < 3, !pending.isEmpty, !isDemo, !paused {
            let id = pending.removeFirst()
            guard let server = servers.first(where: { $0.id == id && $0.enabled }) else { continue }
            let token = UUID(); tokens[id] = token
            let visiblePanels = panels.visible
            jobs[id] = Task { [weak self] in
                do {
                    var snapshot = try await SSHClient.collect(server, panels: visiblePanels)
                    guard !Task.isCancelled, let self, self.tokens[id] == token else { return }
                    let previous = self.statuses[id]?.snapshot
                    snapshot.telemetry?.calculateRates(previous: self.statuses[id]?.error == nil ? previous?.telemetry : nil)
                    if snapshot.gpuError != nil { snapshot.devices = previous?.devices ?? [] }
                    self.statuses[id] = ServerStatus(snapshot: snapshot)
                } catch {
                    guard !Task.isCancelled, let self, self.tokens[id] == token else { return }
                    self.statuses[id, default: ServerStatus()].error = error.localizedDescription
                    self.statuses[id]?.refreshing = false
                }
                guard let self, self.tokens[id] == token else { return }
                self.jobs.removeValue(forKey: id); self.tokens.removeValue(forKey: id)
                self.drain()
            }
        }
    }

    func summary(at date: Date = Date(), serverID: UUID? = nil) -> (idle: Int, occupied: Int, unknown: Int, total: Int, unavailable: Int) {
        var idle = 0, occupied = 0, unknown = 0, total = 0, unavailable = 0
        for server in servers where serverID == nil || server.id == serverID {
            let status = statuses[server.id] ?? ServerStatus()
            total += status.snapshot?.devices.count ?? 0
            if !server.enabled || status.stale(at: date, interval: interval) || status.snapshot?.gpuError != nil { unavailable += 1; unknown += status.snapshot?.devices.count ?? 0; continue }
            for device in status.snapshot?.devices ?? [] {
                switch device.state {
                case .idle: idle += 1
                case .busy, .occupied: occupied += 1
                default: unknown += 1
                }
            }
        }
        return (idle, occupied, unknown, total, unavailable)
    }

    func enterDemo() {
        guard !isDemo else { return }
        for id in Array(jobs.keys) + pending { cancel(id) }
        beforeDemo = servers
        isDemo = true; paused = false
        let first = Server(name: "昇腾 · 01", host: "ascend-01", kind: .ascend)
        let second = Server(name: "昇腾 · 02", host: "ascend-02", kind: .ascend)
        let nv = Server(name: "NVIDIA · 01", host: "nvidia-01", kind: .nvidia)
        servers = [first, second, nv]; statuses = [:]
        for (position, server) in servers.enumerated() {
            let cards = (0..<(position == 2 ? 1 : 8)).map { index -> Accelerator in
                let idle = position == 2 || (position == 0 && index > 3)
                let held = position < 2 && index == (position == 0 ? 3 : 7)
                let memory = idle ? 200.0 : held ? 32768.0 : 50176.0 + Double(index * 100)
                return Accelerator(id: "demo-\(position)-\(index)", index: index, kind: position == 2 ? .nvidia : .ascend,
                                   name: position == 2 ? "NVIDIA GeForce RTX 4090" : "Ascend 910B",
                                   utilization: idle ? 0 : held ? 1 : Double(96 - index),
                                   memoryUsedMiB: memory, memoryTotalMiB: position == 2 ? 24576 : 65536, temperature: idle ? 36 : 58, health: "OK",
                                   processes: idle ? [] : [ComputeProcess(pid: 28140 + position * 10 + index, user: held ? "wang" : position == 0 ? "zhang" : "chen", name: "python", memoryMiB: memory - 100)],
                                   processesKnown: true)
            }
            var telemetry = HostTelemetry(uptime: 320000, cpuModel: "Server CPU · 32 cores",
                                          cpuUsage: position == 2 ? 12 : 62,
                                          memoryTotalMiB: 262144, memoryAvailableMiB: 118784, load: [8.2, 7.1, 6.9],
                                          interfaces: [NetworkInterface(name: "eth0", received: 42000000000, sent: 9200000000, receiveRate: 5242880, sendRate: 1572864)],
                                          primaryInterface: "eth0", diskTotalKiB: 1048576000, diskUsedKiB: 450887680, diskMount: "/")
            telemetry.volumes = [DiskVolume(source: "/dev/nvme0n1p1", mount: "/", totalKiB: 1048576000, usedKiB: 450887680, availableKiB: 597688320),
                                 DiskVolume(source: "/dev/nvme1n1p1", mount: "/data", totalKiB: 2097152000, usedKiB: 536870912, availableKiB: 1560281088)]
            telemetry.disks = [DiskIO(name: "nvme0n1", readBytes: 1000000000, writtenBytes: 2000000000, capacityBytes: 1099511627776, readRate: 1048576, writeRate: 524288),
                               DiskIO(name: "nvme1n1", readBytes: 2000000000, writtenBytes: 1000000000, capacityBytes: 2199023255552, readRate: 524288, writeRate: 262144)]
            for n in 0..<32 { telemetry.cpuTicks["cpu\(n)"] = CPUTicks(total: 100, idle: 30); telemetry.coreUsage["cpu\(n)"] = Double(30 + n) }
            telemetry.cpuTicks["cpu"] = CPUTicks(total: 3200, idle: 960)
            statuses[server.id] = ServerStatus(snapshot: Snapshot(devices: cards, telemetry: telemetry))
        }
    }

    func leaveDemo() {
        guard isDemo else { return }
        servers = beforeDemo; statuses = [:]; beforeDemo = []; isDemo = false
        refreshAll()
    }
}
