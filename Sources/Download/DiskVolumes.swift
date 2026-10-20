import DiskArbitration
import Foundation

/// Остаток очереди загрузок на одном томе.
struct VolumeQueueUsage: Sendable, Equatable {
    var remainingBytes: Int64 = 0
    var downloadingCount = 0
}

/// Диск в разделе «Диски» боковой панели.
struct DiskVolume: Sendable, Identifiable, Equatable {
    /// Путь точки монтирования; совпадает с `PathResolver.volumeKey` («/» или `/Volumes/<Name>`).
    let id: String
    let url: URL
    let name: String
    let isInternal: Bool
    let totalBytes: Int64
    /// Реально пустое место без очищаемого (`volumeAvailableCapacity`, как «Свободно» в Дисковой утилите).
    let freeBytes: Int64
    /// Очищаемое место: macOS может освободить его по требованию (кэши, локальные снимки Time Machine).
    let purgeableBytes: Int64
    /// Файловая система: APFS, ExFAT, HFS+ …
    let fileSystem: String?
    var usage = VolumeQueueUsage()

    /// Заполненность по реально пустому месту.
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(totalBytes - freeBytes) / Double(totalBytes)))
    }

    var usedPercent: Int { Int((usedFraction * 100).rounded()) }
    var isDownloadingHere: Bool { usage.downloadingCount > 0 }
    /// Оставшейся очереди на этот диск не хватает реально пустого места с запасом 2 ГБ.
    var lacksSpace: Bool { usage.remainingBytes > 0 && usage.remainingBytes + DownloadScheduler.spaceMargin > freeBytes }
    /// Очищаемое показывается, если его больше 1 ГБ.
    var showsPurgeable: Bool { purgeableBytes > 1_000_000_000 }

    /// Строка 1: «Свободно 49,8 ГБ из 4 ТБ»
    var freeLine: String { String(localized: "\(Format.diskBytes(freeBytes)) free of \(Format.diskBytes(totalBytes))") }

    /// Строка 2: «Занято 99% · +16,8 ГБ можно освободить»
    var usageLine: String {
        let used = (Double(usedPercent) / 100).formatted(.percent.precision(.fractionLength(0)))
        var text = String(localized: "\(used) used")
        if showsPurgeable { text += " · " + String(localized: "+\(Format.diskBytes(purgeableBytes)) purgeable") }
        return text
    }

    /// Полные данные для подсказки по наведению.
    var details: String {
        [
            name,
            String(localized: "Capacity: \(Format.diskBytes(totalBytes))"),
            String(localized: "Used: \(Format.diskBytes(max(0, totalBytes - freeBytes))) (\((Double(usedPercent) / 100).formatted(.percent)))"),
            String(localized: "Free: \(Format.diskBytes(freeBytes))"),
            String(localized: "Purgeable: \(Format.diskBytes(purgeableBytes))"),
            String(localized: "File system: \(fileSystem ?? String(localized: "unknown"))"),
            String(localized: "Mount point: \(url.path)"),
        ].joined(separator: "\n")
    }
}

enum DiskVolumes {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeTypeNameKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    /// Системный диск и подключённые физические внешние диски: сначала системный, затем по алфавиту.
    /// Служебные тома (Preboot, Recovery, VM, Update), сетевые тома и образы .dmg не показываются.
    /// Вызывать не на главном потоке: опрос томов может занимать заметное время.
    static func load(usage: [String: VolumeQueueUsage]) -> [DiskVolume] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        var volumes: [DiskVolume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let path = url.standardizedFileURL.path
            let isSystem = values.volumeIsRootFileSystem == true || path == "/"
            if !isSystem {
                guard !path.hasPrefix("/System/Volumes"), values.volumeIsBrowsable != false,
                      values.volumeIsLocal == true, values.volumeIsInternal != true,
                      !isDiskImage(url, session: session) else { continue }
            }
            let free = values.volumeAvailableCapacity.map(Int64.init) ?? 0
            let important = values.volumeAvailableCapacityForImportantUsage ?? 0
            volumes.append(DiskVolume(
                id: isSystem ? "/" : path, url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isInternal: isSystem,
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                freeBytes: free,
                purgeableBytes: max(0, important - free),
                fileSystem: Self.fileSystemName(values)))
        }
        volumes.sort { a, b in
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        attach(usage, to: &volumes)
        return volumes
    }

    /// Ключи очереди — «/» или `/Volumes/<Name>`. Путь через символьную ссылку
    /// (`/Volumes/Macintosh HD/…`) относится к системному диску.
    private static func attach(_ usage: [String: VolumeQueueUsage], to volumes: inout [DiskVolume]) {
        for (key, value) in usage {
            var index = volumes.firstIndex { $0.id == key }
            if index == nil, URL(fileURLWithPath: key).resolvingSymlinksInPath().path == "/" {
                index = volumes.firstIndex { $0.id == "/" }
            }
            guard let index else { continue }
            volumes[index].usage.remainingBytes += value.remainingBytes
            volumes[index].usage.downloadingCount += value.downloadingCount
        }
    }

    /// «APFS», «ExFAT», «Mac OS Extended (журналируемый)» — как в Finder; иначе тип ФС в верхнем регистре.
    private static func fileSystemName(_ values: URLResourceValues) -> String? {
        if let description = values.volumeLocalizedFormatDescription, !description.isEmpty { return description }
        return values.volumeTypeName?.uppercased()
    }

    /// Смонтированный образ диска (.dmg и т. п.) — по описанию устройства из DiskArbitration.
    private static func isDiskImage(_ url: URL, session: DASession?) -> Bool {
        guard let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
        let proto = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        return model == "Disk Image" || proto == "Disk Image" || proto == "Virtual Interface"
    }
}
