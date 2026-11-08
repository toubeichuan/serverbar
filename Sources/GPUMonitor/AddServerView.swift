import SwiftUI

struct AddServerView: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.dismiss) var dismiss
    @State private var tab = 0
    @State private var imported = SSHConfigResult()
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var loading = false
    @State private var kind: DeviceKind = .auto
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("添加服务器").font(.title2.bold())
                    Text("复用你的 SSH 配置，只保存所选服务器。").foregroundStyle(.secondary).font(.subheadline)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("添加方式", selection: $tab) { Text("SSH 配置").tag(0); Text("手动添加").tag(1) }.pickerStyle(.segmented)
            if tab == 0 {
                HStack {
                    Text("~/.ssh/config").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button("重新读取") { load() }.disabled(loading)
                }
                TextField("搜索 SSH 别名", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(imported.hosts.filter { query.isEmpty || $0.alias.localizedCaseInsensitiveContains(query) }) { host in
                            let added = store.servers.contains { $0.host.caseInsensitiveCompare(host.alias) == .orderedSame }
                            HStack {
                                Toggle(isOn: Binding(get: { selected.contains(host.alias) }, set: { if $0 { selected.insert(host.alias) } else { selected.remove(host.alias) } })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(host.alias).font(.system(size: 13, weight: .medium, design: .monospaced))
                                        Text(shortPath(host.source)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.toggleStyle(.checkbox).disabled(added)
                                Spacer()
                                if added { Text("已添加").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 9)
                            Divider()
                        }
                        if imported.hosts.isEmpty && !loading {
                            VStack(spacing: 10) {
                                Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                                Text("没有发现可导入的 Host 别名")
                                Text("可以切换到“手动添加”，输入主机地址或 SSH 别名。").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 42)
                        }
                    }
                }.frame(height: 230)
                ForEach(imported.warnings, id: \.self) { warning in Text(warning).font(.caption).foregroundStyle(.orange) }
                Text("支持 Include；忽略通配符和否定项。连接时由 OpenSSH 解析密钥、端口、Host / Match 与跳板机设置。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("设备类型", selection: $kind) { ForEach(DeviceKind.allCases) { Text($0.title).tag($0) } }.frame(width: 225)
                    Spacer()
                    Button("添加并监控 \(selected.count) 台") {
                        let servers = selected.sorted().map { Server(name: $0, host: $0, kind: kind) }
                        if store.add(servers) { dismiss() }
                    }.buttonStyle(.borderedProminent).disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
                }
            } else {
                ServerForm(initial: nil) { server in if store.add([server]) { dismiss() } }
            }
            if let error = store.appError { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(24).frame(width: 600).task { load() }
    }
    private func shortPath(_ path: String) -> String { path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
    private func load() {
        loading = true
        Task {
            let value = await Task.detached(priority: .userInitiated) { SSHConfigReader().read() }.value
            imported = value; selected.formIntersection(Set(value.hosts.map(\.alias))); loading = false
        }
    }
}

struct ServerEditor: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.dismiss) var dismiss
    let server: Server
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("编辑服务器").font(.title2.bold()); Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
            ServerForm(initial: server) { if store.update($0) { dismiss() } }
            if let error = store.appError { Text(error).foregroundStyle(.orange).font(.caption) }
        }.padding(24).frame(width: 590)
    }
}

struct ServerForm: View {
    let initial: Server?
    let onSave: (Server) -> Void
    @State private var name = ""
    @State private var host = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identity = ""
    @State private var kind: DeviceKind = .auto
    @State private var testing = false
    @State private var testResult: String?
    @State private var testTask: Task<Void, Never>?
    private var candidate: Server {
        Server(id: initial?.id ?? UUID(), name: name.isEmpty ? host.trimmingCharacters(in: .whitespacesAndNewlines) : name,
               host: host.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
               port: port.isEmpty ? nil : Int(port), user: user, identityFile: identity, enabled: initial?.enabled ?? true)
    }
    private var error: String? {
        if !port.isEmpty && Int(port) == nil { return "端口必须是 1–65535 之间的整数。" }
        return candidate.validationError
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Form {
                TextField("显示名称", text: $name, prompt: Text("可选，默认使用 SSH 别名"))
                TextField("SSH 别名 / 地址", text: $host, prompt: Text("例如 ascend-01 或 192.168.1.10"))
                Picker("设备类型", selection: $kind) { ForEach(DeviceKind.allCases) { Text($0.title).tag($0) } }
                Section("可选覆盖项（留空沿用 SSH 配置）") {
                    TextField("用户名", text: $user)
                    TextField("端口", text: $port)
                    TextField("私钥路径", text: $identity, prompt: Text("例如 ~/.ssh/id_ed25519"))
                }
            }.textFieldStyle(.roundedBorder).disabled(testing)
            Text("使用系统 SSH 与已有密钥 / ssh-agent。请先在终端完成首次连接和主机指纹确认。")
                .font(.caption).foregroundStyle(.secondary)
            if !host.isEmpty, let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let testResult { Text(testResult).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(testing ? "正在测试…" : "测试连接与设备") {
                    let server = candidate; testing = true; testResult = nil
                    testTask = Task {
                        defer { testing = false }
                        do {
                            let snapshot = try await SSHClient.collect(server)
                            guard !Task.isCancelled else { return }
                            testResult = "连接成功 · 检测到 \(snapshot.devices.count) 个设备" + (snapshot.warnings.isEmpty ? "" : "\n" + snapshot.warnings.joined(separator: "\n"))
                        } catch { if !Task.isCancelled { testResult = error.localizedDescription } }
                    }
                }.disabled(error != nil || testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button(initial == nil ? "添加并监控" : "保存") { onSave(candidate) }
                    .buttonStyle(.borderedProminent).disabled(error != nil || testing).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            if let initial { name = initial.name; host = initial.host; user = initial.user; port = initial.port.map(String.init) ?? ""; identity = initial.identityFile; kind = initial.kind }
        }
        .onDisappear { testTask?.cancel() }
        .onChange(of: host) { _ in testResult = nil }
        .onChange(of: kind) { _ in testResult = nil }
    }
}
