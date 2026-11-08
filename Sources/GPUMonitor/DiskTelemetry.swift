import Foundation

struct DiskVolume: Identifiable, Equatable {
    var source: String
    var mount: String
    var totalKiB: Double
    var usedKiB: Double
    var availableKiB: Double
    var id: String { source + "|" + mount }
}

struct DiskIO: Identifiable, Equatable {
    var name: String
    var readBytes: Double
    var writtenBytes: Double
    var capacityBytes: Double? = nil
    var readRate: Double? = nil
    var writeRate: Double? = nil
    var id: String { name }
}

extension HostTelemetry {
    var diskReadRate: Double? {
        guard !disks.isEmpty, disks.allSatisfy({ $0.readRate != nil }) else { return nil }
        return disks.reduce(0) { $0 + ($1.readRate ?? 0) }
    }
    var diskWriteRate: Double? {
        guard !disks.isEmpty, disks.allSatisfy({ $0.writeRate != nil }) else { return nil }
        return disks.reduce(0) { $0 + ($1.writeRate ?? 0) }
    }
    mutating func parseDisks(_ sections: [String: [String]]) {
        var seen = Set<String>()
        for line in sections["__GM_DISK__", default: []] {
            let cells = line.split(maxSplits: 5, whereSeparator: \.isWhitespace)
            guard cells.count == 6, cells[0].hasPrefix("/dev/"),
                  !cells[0].hasPrefix("/dev/loop"), let total = Double(cells[1]), total > 0,
                  let used = Double(cells[2]), used >= 0, let available = Double(cells[3]), available >= 0 else { continue }
            let volume = DiskVolume(source: String(cells[0]), mount: String(cells[5]), totalKiB: total, usedKiB: used, availableKiB: available)
            if seen.insert(volume.id).inserted { volumes.append(volume) }
        }
        volumes.sort { $0.mount < $1.mount }
        // Keep root fields for older callers; never overwrite root with the last volume.
        if let root = volumes.first(where: { $0.mount == "/" }) {
            diskTotalKiB = root.totalKiB; diskUsedKiB = root.usedKiB; diskMount = root.mount
        }
        var sizes: [String: Double] = [:]
        for line in sections["__GM_DISK_SIZE__", default: []] {
            let cells = line.split(whereSeparator: \.isWhitespace)
            if cells.count == 2, let sectors = Double(cells[1]), sectors >= 0 { sizes[String(cells[0])] = sectors * 512 }
        }
        for line in sections["__GM_DISK_IO__", default: []] {
            let cells = line.split(whereSeparator: \.isWhitespace)
            guard cells.count >= 12, let read = Double(cells[3]), let written = Double(cells[7]), read >= 0, written >= 0 else { continue }
            let name = String(cells[0])
            guard !disks.contains(where: { $0.name == name }) else { continue }
            // Kernel block statistics always count 512-byte sectors, including 4K drives.
            disks.append(DiskIO(name: name, readBytes: read * 512, writtenBytes: written * 512, capacityBytes: sizes[name]))
        }
        disks.sort { $0.name < $1.name }
    }
    mutating func calculateDiskRates(previous: HostTelemetry, elapsed: Double) {
        for i in disks.indices {
            guard let old = previous.disks.first(where: { $0.name == disks[i].name }),
                  disks[i].capacityBytes == old.capacityBytes,
                  disks[i].readBytes >= old.readBytes, disks[i].writtenBytes >= old.writtenBytes else { continue }
            disks[i].readRate = (disks[i].readBytes - old.readBytes) / elapsed
            disks[i].writeRate = (disks[i].writtenBytes - old.writtenBytes) / elapsed
        }
    }
}

func diskCapacityText(_ kib: Double) -> String {
    kib < 1_048_576 ? String(format: "%.1f MiB", kib / 1024) : memoryText(kib / 1024)
}
