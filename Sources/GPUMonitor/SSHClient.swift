import Foundation
import Darwin

struct CommandOutput { var stdout: String; var stderr: String; var status: Int32 }

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = max(0, 2_000_000 - data.count)
        data.append(bytes.prefix(room))
        if bytes.count > room { overflow = true }
    }
    var exceeded: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        self.process = process
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum CommandRunner {
    static func run(executable: String, arguments: [String], timeout: Double = 25) async throws -> CommandOutput {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out; process.standardError = err
                let output = OutputBuffer(), errors = OutputBuffer()
                try control.start(process)
                let readers = DispatchGroup()
                for (pipe, buffer) in [(out, output), (err, errors)] {
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { readers.leave() }
                        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty { buffer.append(chunk) }
                    }
                }
                let deadline = Date().addingTimeInterval(timeout)
                var timedOut = false
                while process.isRunning {
                    if Date() >= deadline || control.isCancelled || output.exceeded || errors.exceeded {
                        timedOut = Date() >= deadline
                        control.stop()
                        usleep(200_000)
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        break
                    }
                    usleep(25_000)
                }
                process.waitUntilExit()
                let readStatus = waitForReaders(readers)
                if timedOut { throw MonitorError.message("采集超时（\(Int(timeout)) 秒）。请检查网络、跳板机或远端命令。") }
                if output.exceeded || errors.exceeded { throw MonitorError.message("服务器返回数据过大，已停止本次采集。") }
                if control.isCancelled { throw CancellationError() }
                if readStatus == .timedOut { throw MonitorError.message("SSH 已退出，但输出流未正常关闭。请检查 ProxyCommand 配置。") }
                return CommandOutput(stdout: output.string, stderr: errors.string, status: process.terminationStatus)
            }.value
        }, onCancel: { control.stop() })
    }

    private static func waitForReaders(_ group: DispatchGroup) -> DispatchTimeoutResult {
        group.wait(timeout: .now() + 1)
    }
}

enum SSHClient {
    static func arguments(for server: Server, command: String) -> [String] {
        var args = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
                    "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                    "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
                    "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none", "-o", "RequestTTY=no",
                    "-o", "ControlMaster=no", "-o", "ControlPersist=no"]
        if let port = server.port { args += ["-p", String(port)] }
        if !server.user.isEmpty { args += ["-l", server.user] }
        if !server.identityFile.isEmpty { args += ["-i", (server.identityFile as NSString).expandingTildeInPath] }
        return args + ["--", server.host, command]
    }

    static func collect(_ server: Server, panels: Set<MonitorPanel> = Set(MonitorPanel.allCases)) async throws -> Snapshot {
        if let error = server.validationError { throw MonitorError.message(error) }
        let result = try await CommandRunner.run(executable: "/usr/bin/ssh", arguments: arguments(for: server, command: probe(kind: server.kind, panels: panels)))
        guard result.status == 0 else { throw MonitorError.message(explain(result)) }
        return try SnapshotParser.parse(result.stdout)
    }

    static func explain(_ result: CommandOutput) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("Host key verification failed") || text.contains("REMOTE HOST IDENTIFICATION") {
            return "主机身份尚未信任或已经变化。请先在终端使用相同 SSH 别名连接并核实主机指纹。"
        }
        if text.contains("Permission denied") { return "SSH 身份验证失败。请先在终端确认密钥 / ssh-agent 可用；后台监控不弹出密码输入框。" }
        if result.stdout.contains("__GM_NO_TOOL__") { return "未找到可用的 nvidia-smi 或 npu-smi。请检查驱动、命令路径，或在服务器设置中指定设备类型。" }
        if text.contains("Could not resolve") { return "无法解析服务器地址。请检查 SSH 别名、HostName 或当前网络。" }
        return text.isEmpty ? "远端采集命令失败（退出码 \(result.status)）。" : String(text.prefix(1000))
    }

    static func probe(kind: DeviceKind, panels: Set<MonitorPanel> = [.gpu]) -> String {
        let select: String
        switch kind {
        case .auto: select = "if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then GM_KIND=gpu; elif command -v npu-smi >/dev/null 2>&1; then GM_KIND=npu; else echo __GM_NO_TOOL__; exit 3; fi"
        case .nvidia: select = "GM_KIND=gpu; command -v nvidia-smi >/dev/null 2>&1 || { echo __GM_NO_TOOL__; exit 3; }"
        case .ascend: select = "GM_KIND=npu; command -v npu-smi >/dev/null 2>&1 || { echo __GM_NO_TOOL__; exit 3; }"
        }
        let acceleratorProbe = "LC_ALL=C; export LC_ALL; PATH=$PATH:/usr/local/Ascend/driver/tools:/usr/local/sbin:/usr/sbin; export PATH; " + select + "; " + #"""
        if [ "$GM_KIND" = gpu ]; then
          echo __GM_GPU__
          nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits || exit 4
          echo __GM_APPS__
          GM_APPS=$(nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits)
          GM_APP_STATUS=$?
          printf '%s\n' "$GM_APPS"
          if [ "$GM_APP_STATUS" -eq 0 ]; then echo __GM_APPS_OK__; fi
          GM_PIDS=$(printf '%s\n' "$GM_APPS" | awk -F, '{gsub(/ /,"",$2); if ($2 ~ /^[0-9]+$/) print $2}')
          echo __GM_GRAPHICS__
          if nvidia-smi pmon -c 1 -s m 2>/dev/null; then echo __GM_GRAPHICS_OK__; fi
        else
          echo __GM_NPU__
          GM_NPU=$(npu-smi info) || exit 4
          printf '%s\n' "$GM_NPU"
          GM_IDS=$(printf '%s\n' "$GM_NPU" | awk -F'|' '{gsub(/^[ \t]+/, "", $2); split($2,a,/[ \t]+/); if (a[1] ~ /^[0-9]+$/ && a[2] != "" && a[2] !~ /^[0-9]+$/) print a[1]}' | sort -nu)
          GM_PIDS=$(printf '%s\n' "$GM_NPU" | awk -F'|' '$3 ~ /^[ \t]*[0-9]+[ \t]*$/ {gsub(/[ \t]/,"",$3); print $3}')
          if ! printf '%s\n' "$GM_NPU" | grep -qi 'Process.*id'; then
          for GM_ID in $GM_IDS; do
            case "$GM_ID" in ''|*[!0-9]*) continue ;; esac
            echo "__GM_NPU_PROC__ $GM_ID"
            if npu-smi info -t proc-mem -i "$GM_ID"; then echo "__GM_NPU_PROC_OK__ $GM_ID"; fi
          done
          fi
        fi
        echo __GM_PS__
        if ps -eo pid=,user:64=,comm=; then echo __GM_PS_OK__; fi
        echo __GM_PROGRAMS__
        if command -v python3 >/dev/null 2>&1; then
          python3 - "$GM_PIDS" <<'GMPY'
        import sys, os, json
        for pid in sys.argv[1].split()[:256]:
            if not pid.isdigit(): continue
            try:
                with open('/proc/' + pid + '/cmdline', 'rb') as f:
                    args = [x.decode('utf-8', 'replace') for x in f.read(65536).split(b'\0') if x]
                if not args: continue
                label = os.path.basename(args[0])
                if '-m' in args and args.index('-m') + 1 < len(args):
                    label += ' -m ' + args[args.index('-m') + 1]
                else:
                    script = next((x for x in args[1:] if x.endswith(('.py', '.sh')) and not x.startswith('-')), None)
                    if script: label += ' ' + os.path.basename(script)
                print(json.dumps([pid, label[:200]]))
            except (OSError, ValueError): pass
        GMPY
        fi
        """#
        var commands: [String] = []
        if panels.contains(.gpu) {
            commands.append("( " + acceleratorProbe + "\n) || { echo __GM_GPU_ERROR__; echo '加速卡采集失败，请检查驱动或设备类型。'; }")
        }
        if !panels.subtracting([.gpu]).isEmpty {
            commands.append("echo __GM_UPTIME__; cat /proc/uptime 2>/dev/null")
        }
        if panels.contains(.cpu) {
            commands.append("echo __GM_CPU__; head -n 1025 /proc/stat 2>/dev/null; echo __GM_CPU_MODEL__; awk -F: '/model name|Hardware|CPU part/ {gsub(/^[ \t]+/, \"\", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null; echo __GM_LOAD__; cat /proc/loadavg 2>/dev/null")
        }
        if panels.contains(.memory) { commands.append("echo __GM_MEMORY__; cat /proc/meminfo 2>/dev/null") }
        if panels.contains(.network) {
            commands.append("echo __GM_NETWORK__; cat /proc/net/dev 2>/dev/null; echo __GM_ROUTE__; awk '$2 == \"00000000\" {print $1; exit}' /proc/net/route 2>/dev/null")
        }
        if panels.contains(.disk) { commands.append(Self.diskProbe) }
        return commands.joined(separator: "\n") + "\nexit 0"
    }
}

extension SSHClient {
    static let diskProbe = #"""
    echo __GM_DISK__
    LC_ALL=C df -Pkl 2>/dev/null
    echo __GM_DISK_IO__
    for GM_DISK_PATH in /sys/block/*; do
      GM_DISK_NAME=${GM_DISK_PATH##*/}
      case "$GM_DISK_NAME" in loop*|ram*|zram*|sr*) continue ;; esac
      [ -r "$GM_DISK_PATH/stat" ] || continue
      set -- "$GM_DISK_PATH"/slaves/*
      [ -e "$1" ] && continue
      printf '%s ' "$GM_DISK_NAME"
      cat "$GM_DISK_PATH/stat" 2>/dev/null
    done
    echo __GM_DISK_SIZE__
    for GM_DISK_PATH in /sys/block/*; do
      GM_DISK_NAME=${GM_DISK_PATH##*/}
      case "$GM_DISK_NAME" in loop*|ram*|zram*|sr*) continue ;; esac
      [ -r "$GM_DISK_PATH/size" ] || continue
      set -- "$GM_DISK_PATH"/slaves/*
      [ -e "$1" ] && continue
      printf '%s ' "$GM_DISK_NAME"
      cat "$GM_DISK_PATH/size" 2>/dev/null
    done
    """#
}
