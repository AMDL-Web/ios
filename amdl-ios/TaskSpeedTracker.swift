//
//  TaskSpeedTracker.swift
//  amdl-ios
//

import Foundation

/// 从逐条 `item_progress` 推送里估算整个任务的实时聚合速度，下载与解密分别统计。
///
/// 后端把每首曲目的阶段进度压进单个 `progress`(0...1)：下载阶段线性映射到
/// 0.05...0.55，解密阶段映射到 0.55...0.90（见后端 downloader 的 `set` 闭包）。
/// 每条推送的载荷是完整 `JobItem`，其 `updated_at` 由后端在发事件前刚好刷成当前
/// 服务器时间，可直接当作采样时刻——服务器单调时钟，不受设备到服务器的网络抖动
/// 影响。
///
/// 单曲加密总字节用「平均码率 × 时长」估算（无损编码有逐曲码率，可用；AAC-LC 等
/// 有损编码没有逐曲码率，估算为 0，因而不计入速度）。相邻两次推送的字节差 ÷ 时间
/// 差即该曲瞬时速率，按曲目做指数平滑后，把当前处于对应阶段的所有曲目速率求和，
/// 得到任务级总速度。调用方在每条推送落地后调用 `update(with:)`，刷新频率即跟随
/// 推送频率。
struct TaskSpeedTracker {
    /// 当前任务级总下载速度（字节/秒）。
    private(set) var downloadBytesPerSecond: Double = 0
    /// 当前任务级总解密速度（字节/秒）。
    private(set) var decryptBytesPerSecond: Double = 0

    /// 是否有任一维度在产出速度，供 UI 决定要不要显示速度行。
    var hasActiveSpeed: Bool {
        downloadBytesPerSecond > 0 || decryptBytesPerSecond > 0
    }

    private struct Sample {
        var bytes: Double
        var time: Date
    }

    /// 下载阶段在全局进度里的区间：0.05...0.55。
    private static let downloadRange: ClosedRange<Double> = 0.05...0.55
    /// 解密阶段在全局进度里的区间：0.55...0.90。
    private static let decryptRange: ClosedRange<Double> = 0.55...0.90
    /// 瞬时速率的指数平滑系数：越大越跟手，越小越平滑。
    private static let smoothing = 0.5
    /// 采样时刻早于最新推送超过该秒数的曲目视为已停滞，不再计入总速度。
    private static let staleWindow: TimeInterval = 12

    private var downloadSamples: [String: Sample] = [:]
    private var decryptSamples: [String: Sample] = [:]
    private var downloadSpeeds: [String: Double] = [:]
    private var decryptSpeeds: [String: Double] = [:]

    /// 用最新的完整 items 列表刷新一次估算。应在每条推送落地后（以及每次快照刷新
    /// 后）调用；只有实际推进过进度的曲目才会更新其速率，其余保持上一次结果。
    mutating func update(with items: [JobItem]) {
        // 服务器时钟下的「现在」：取所有曲目里最新的更新时刻，用来判定停滞。
        let referenceTime = items.map(\.updatedAt).max() ?? Date()

        var downloadingIDs: Set<String> = []
        var decryptingIDs: Set<String> = []

        for item in items {
            let totalBytes = estimatedEncryptedBytes(for: item)
            switch item.status {
            case .downloading:
                downloadingIDs.insert(item.id)
                ingest(
                    id: item.id,
                    bytes: phaseBytes(progress: item.progress, range: Self.downloadRange, totalBytes: totalBytes),
                    time: item.updatedAt,
                    samples: &downloadSamples,
                    speeds: &downloadSpeeds
                )
            case .decrypting:
                decryptingIDs.insert(item.id)
                ingest(
                    id: item.id,
                    bytes: phaseBytes(progress: item.progress, range: Self.decryptRange, totalBytes: totalBytes),
                    time: item.updatedAt,
                    samples: &decryptSamples,
                    speeds: &decryptSpeeds
                )
            default:
                break
            }
        }

        // 离开对应阶段（完成/失败/进入下一阶段）的曲目不再贡献该阶段速度。
        downloadSamples = downloadSamples.filter { downloadingIDs.contains($0.key) }
        downloadSpeeds = downloadSpeeds.filter { downloadingIDs.contains($0.key) }
        decryptSamples = decryptSamples.filter { decryptingIDs.contains($0.key) }
        decryptSpeeds = decryptSpeeds.filter { decryptingIDs.contains($0.key) }

        downloadBytesPerSecond = total(of: downloadSpeeds, samples: downloadSamples, reference: referenceTime)
        decryptBytesPerSecond = total(of: decryptSpeeds, samples: decryptSamples, reference: referenceTime)
    }

    /// 清空全部采样与速率，切换任务时调用。
    mutating func reset() {
        downloadSamples.removeAll()
        decryptSamples.removeAll()
        downloadSpeeds.removeAll()
        decryptSpeeds.removeAll()
        downloadBytesPerSecond = 0
        decryptBytesPerSecond = 0
    }

    /// 用平均码率与时长估算单曲加密媒体的总字节数。无损编码可用；缺码率或时长
    /// （如 AAC-LC）返回 0，表示无法估速。
    private func estimatedEncryptedBytes(for item: JobItem) -> Double {
        guard let bitrate = item.bitrate, bitrate > 0,
              let durationMs = item.durationMs, durationMs > 0 else {
            return 0
        }
        // 码率单位是 bps：字节数 = 码率 / 8 × 秒数。
        return Double(bitrate) / 8 * Double(durationMs) / 1000
    }

    /// 把全局 `progress` 折算成某阶段内已传输/已消费的字节数。
    private func phaseBytes(progress: Double, range: ClosedRange<Double>, totalBytes: Double) -> Double {
        guard totalBytes > 0 else { return 0 }
        let span = range.upperBound - range.lowerBound
        let fraction = min(max((progress - range.lowerBound) / span, 0), 1)
        return fraction * totalBytes
    }

    private func ingest(
        id: String,
        bytes: Double,
        time: Date,
        samples: inout [String: Sample],
        speeds: inout [String: Double]
    ) {
        defer { samples[id] = Sample(bytes: bytes, time: time) }
        guard let previous = samples[id] else { return }  // 首个采样只建基线。
        let elapsed = time.timeIntervalSince(previous.time)
        guard elapsed > 0 else { return }  // 本曲没有新进度（其他曲目的推送），保持原速率。
        let delta = bytes - previous.bytes
        guard delta >= 0 else { return }   // 阶段回退（如重试重置）等异常，忽略这次采样差。
        let instantaneous = delta / elapsed
        let smoothed = speeds[id].map { $0 + Self.smoothing * (instantaneous - $0) } ?? instantaneous
        speeds[id] = smoothed
    }

    private func total(of speeds: [String: Double], samples: [String: Sample], reference: Date) -> Double {
        speeds.reduce(0) { partial, entry in
            guard let sample = samples[entry.key],
                  reference.timeIntervalSince(sample.time) <= Self.staleWindow else {
                return partial
            }
            return partial + entry.value
        }
    }
}

/// 传输速率的展示格式：沿用系统字节计数样式并加「/s」后缀。
enum TransferSpeedFormat {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func string(bytesPerSecond: Double) -> String {
        let value = formatter.string(fromByteCount: Int64(max(bytesPerSecond, 0)))
        return "\(value)/s"
    }
}
