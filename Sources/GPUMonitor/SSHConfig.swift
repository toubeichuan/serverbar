import Foundation
import Darwin

struct SSHHost: Identifiable, Hashable {
    var alias: String
    var source: String
    var id: String { alias }
}

struct SSHConfigResult {
    var hosts: [SSHHost] = []
    var warnings: [String] = []
}

/// Discovers aliases only. OpenSSH itself resolves Host/Match/Include precedence at connection time.
struct SSHConfigReader {
    var home = FileManager.default.homeDirectoryForCurrentUser.path
    var environment = ProcessInfo.processInfo.environment

    func read(path: String? = nil) -> SSHConfigResult {
        var result = SSHConfigResult()
        var seen = Set<String>()
        scan(path ?? home + "/.ssh/config", stack: [], seen: &seen, result: &result)
        return result
    }

    private func scan(_ path: String, stack: Set<String>, seen: inout Set<String>, result: inout SSHConfigResult) {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard stack.count < 16, !stack.contains(canonical) else {
            result.warnings.append("已跳过循环或过深的 Include：\(URL(fileURLWithPath: path).lastPathComponent)")
            return
        }
        guard let data = FileManager.default.contents(atPath: path), data.count <= 2_000_000,
              let text = String(data: data, encoding: .utf8) else {
            result.warnings.append("无法读取 \(path)。请检查文件是否存在以及读取权限。")
            return
        }
        var next = stack; next.insert(canonical)
        for line in text.components(separatedBy: .newlines) {
            let parts = Self.tokens(line)
            guard let keyword = parts.first?.lowercased() else { continue }
            if keyword == "host" {
                for alias in parts.dropFirst() where !alias.contains(where: { "*?!".contains($0) }) && Server.validHost(alias) {
                    if seen.insert(alias.lowercased()).inserted { result.hosts.append(SSHHost(alias: alias, source: path)) }
                }
            } else if keyword == "include" {
                for raw in parts.dropFirst() {
                    guard let expanded = expand(raw) else { result.warnings.append("Include 中存在无法展开的变量：\(raw)"); continue }
                    var buffer = glob_t()
                    let status = glob(expanded, 0, nil, &buffer)
                    defer { globfree(&buffer) }
                    if status == 0, let paths = buffer.gl_pathv {
                        for i in 0..<Int(buffer.gl_pathc) {
                            if let item = paths[i] { scan(String(cString: item), stack: next, seen: &seen, result: &result) }
                        }
                    }
                }
            }
        }
    }

    private func expand(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "%d", with: home).replacingOccurrences(of: "%u", with: NSUserName())
        let regex = try! NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let nameRange = Range(match.range(at: 1), in: value), let range = Range(match.range, in: value),
                  let replacement = environment[String(value[nameRange])] else { return nil }
            value.replaceSubrange(range, with: replacement)
        }
        if value == "~" { value = home }
        else if value.hasPrefix("~/") { value = home + String(value.dropFirst()) }
        else if value.hasPrefix("~") { value = (value as NSString).expandingTildeInPath }
        if !value.hasPrefix("/") { value = home + "/.ssh/" + value }
        return value
    }

    static func tokens(_ line: String) -> [String] {
        var tokens: [String] = [], current = ""
        var quote: Character? = nil
        var escape = false
        var hasKeyword = false
        for character in line {
            if escape { current.append(character); escape = false; continue }
            if character == "\\" { escape = true; continue }
            if let q = quote { if character == q { quote = nil } else { current.append(character) }; continue }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "#" { break }
            if character.isWhitespace || (character == "=" && !hasKeyword) {
                if !current.isEmpty { tokens.append(current); current = ""; hasKeyword = true }
            } else if character == "=" && tokens.count == 1 && current.isEmpty {
                continue
            } else { current.append(character) }
        }
        if escape { current.append("\\") }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
