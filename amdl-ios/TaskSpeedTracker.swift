//
//  TaskSpeedTracker.swift
//  amdl-ios
//

import Foundation

/// 折线图的一次任务级速度采样。下载与解密保留为两条独立序列；横轴按事件顺序
/// 等距展示，事件的服务器时间仍用于算速度，避免设备与服务器时钟偏差污染分母。
struct TaskSpeedPoint: Identifiable, Equatable {
    let id: Int
    let downloadBytesPerSecond: Double
    let decryptBytesPerSecond: Double
}

/// 详情页需要的只读速度快照。
struct TaskSpeedPresentation: Equatable {
    let downloadBytesPerSecond: Double
    let decryptBytesPerSecond: Double
    let history: [TaskSpeedPoint]
}

/// 从逐条 `item_progress` 推送估算整个任务的实时聚合速度。
///
/// 每首曲目都有独立的下载、解密 0...1 进度和 `updated_at`。用与详情页总大小相同的
/// 单曲大小估算乘以阶段进度，得到该阶段累计处理字节；相邻两次事件的字节差除以服务
/// 器时间差，就是该曲瞬时速度。每曲先做指数平滑，再把所有正在下载／解密的曲目分别
/// 求和，形成彼此独立的下载速度和解密速度序列。
struct TaskSpeedTracker {
    private(set) var downloadBytesPerSecond: Double = 0
    private(set) var decryptBytesPerSecond: Double = 0
    private(set) var history: [TaskSpeedPoint] = []

    var presentation: TaskSpeedPresentation {
        TaskSpeedPresentation(
            downloadBytesPerSecond: downloadBytesPerSecond,
            decryptBytesPerSecond: decryptBytesPerSecond,
            history: history
        )
    }

    private struct Sample {
        let bytes: Double
        let time: Date
    }

    /// 后端按「跨过整数百分比」而不是每个下载 chunk 发事件。连续几个百分比可能因
    /// socket/SQLite 调度在几十毫秒内成批到达；相邻两点直接相除会制造几百 MB/s 的
    /// 假尖峰。至少积累一秒再出速度，并用最近约四秒的数据消化这种量化抖动。
    private static let minimumSampleWindow: TimeInterval = 1
    private static let rollingWindow: TimeInterval = 4
    /// 滚动窗口已经承担主要平滑，只保留较轻的指数平滑来稳定数字读数。
    private static let smoothing = 0.25
    /// 某曲超过这个窗口没有新事件，就不再把旧速度算进对应阶段的任务速度。
    private static let staleWindow: TimeInterval = 12
    /// 概览只画一条 sparkline；36 个点足够看趋势，也不会让详情状态无限增长。
    private static let historyLimit = 36
    /// 每个点至少间隔这么久的服务器时间。
    ///
    /// 后端按跨整数百分比发事件，也就是每首曲目每阶段约一百次；峰值下一秒能来
    /// 几十个事件。若一个事件记一个点，36 个点只覆盖一秒左右 —— 那不是趋势，
    /// 是把瞬时抖动放大成折线。按时间节流之后横轴才有可比的刻度，36 个点覆盖
    /// 半分多钟。
    private static let historyInterval: TimeInterval = 1

    private var downloadSamples: [String: [Sample]] = [:]
    private var decryptSamples: [String: [Sample]] = [:]
    private var downloadSpeeds: [String: Double] = [:]
    private var decryptSpeeds: [String: Double] = [:]
    private var nextHistoryID = 0
    private var lastHistoryTime: Date?

    mutating func update(with items: [JobItem]) {
        guard let referenceTime = items.map(\.updatedAt).max() else { return }
        let fallbackBitrate = TrackSizeEstimator.representativeBitrate(for: items)
        var downloadingIDs: Set<String> = []
        var decryptingIDs: Set<String> = []

        for item in items {
            guard let totalBytes = TrackSizeEstimator.estimatedBytes(
                for: item,
                fallbackBitrate: fallbackBitrate
            ) else {
                continue
            }

            switch item.status {
            case .downloading:
                downloadingIDs.insert(item.id)
                Self.ingest(
                    id: item.id,
                    bytes: Self.clamped(item.progress.download) * totalBytes,
                    time: item.updatedAt,
                    samples: &downloadSamples,
                    speeds: &downloadSpeeds
                )
            case .decrypting:
                decryptingIDs.insert(item.id)
                Self.ingest(
                    id: item.id,
                    bytes: Self.clamped(item.progress.decrypt) * totalBytes,
                    time: item.updatedAt,
                    samples: &decryptSamples,
                    speeds: &decryptSpeeds
                )
            default:
                break
            }
        }

        // 离开阶段的曲目立即停止贡献速度；否则下载完成后旧速度会一直挂到过期窗口。
        downloadSamples = downloadSamples.filter { downloadingIDs.contains($0.key) }
        downloadSpeeds = downloadSpeeds.filter { downloadingIDs.contains($0.key) }
        decryptSamples = decryptSamples.filter { decryptingIDs.contains($0.key) }
        decryptSpeeds = decryptSpeeds.filter { decryptingIDs.contains($0.key) }

        downloadBytesPerSecond = Self.total(
            of: downloadSpeeds,
            samples: downloadSamples,
            referenceTime: referenceTime
        )
        decryptBytesPerSecond = Self.total(
            of: decryptSpeeds,
            samples: decryptSamples,
            referenceTime: referenceTime
        )
        recordHistory(at: referenceTime)
    }

    mutating func reset() {
        downloadBytesPerSecond = 0
        decryptBytesPerSecond = 0
        history.removeAll()
        downloadSamples.removeAll()
        decryptSamples.removeAll()
        downloadSpeeds.removeAll()
        decryptSpeeds.removeAll()
        nextHistoryID = 0
        lastHistoryTime = nil
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func ingest(
        id: String,
        bytes: Double,
        time: Date,
        samples: inout [String: [Sample]],
        speeds: inout [String: Double]
    ) {
        let current = Sample(bytes: bytes, time: time)
        guard var timeline = samples[id], let previous = timeline.last else {
            samples[id] = [current]
            return
        }

        let sincePrevious = time.timeIntervalSince(previous.time)
        guard sincePrevious >= 0 else { return }
        if bytes < previous.bytes || sincePrevious > Self.staleWindow {
            // 重试会把阶段进度清零；旧速度不能跨重试沿用。
            speeds[id] = nil
            samples[id] = [current]
            return
        }

        if sincePrevious == 0 {
            timeline[timeline.count - 1] = current
        } else {
            timeline.append(current)
        }

        // 保留窗口边界之前的最后一个点作为基线，避免裁剪点本身让分母忽长忽短。
        while timeline.count > 2,
              time.timeIntervalSince(timeline[1].time) > Self.rollingWindow {
            timeline.removeFirst()
        }
        samples[id] = timeline

        guard let baseline = timeline.first else { return }
        let elapsed = time.timeIntervalSince(baseline.time)
        guard elapsed >= Self.minimumSampleWindow else { return }
        let delta = bytes - baseline.bytes
        guard delta >= 0 else { return }
        let windowed = delta / elapsed
        speeds[id] = speeds[id].map {
            $0 + Self.smoothing * (windowed - $0)
        } ?? windowed
    }

    private static func total(
        of speeds: [String: Double],
        samples: [String: [Sample]],
        referenceTime: Date
    ) -> Double {
        speeds.reduce(0) { partial, entry in
            guard let sample = samples[entry.key]?.last,
                  referenceTime.timeIntervalSince(sample.time) <= Self.staleWindow else {
                return partial
            }
            return partial + entry.value
        }
    }

    private mutating func recordHistory(at time: Date) {
        if let lastHistoryTime {
            guard time >= lastHistoryTime else { return }
            // 同一个节流窗口内的事件改写当前点，而不是各自追加一个 —— 读数仍然
            // 每个事件都更新，只有折线的横轴被抽稀。
            if time.timeIntervalSince(lastHistoryTime) < Self.historyInterval, !history.isEmpty {
                history[history.count - 1] = TaskSpeedPoint(
                    id: history[history.count - 1].id,
                    downloadBytesPerSecond: downloadBytesPerSecond,
                    decryptBytesPerSecond: decryptBytesPerSecond
                )
                return
            }
        }

        history.append(
            TaskSpeedPoint(
                id: nextHistoryID,
                downloadBytesPerSecond: downloadBytesPerSecond,
                decryptBytesPerSecond: decryptBytesPerSecond
            )
        )
        nextHistoryID &+= 1
        lastHistoryTime = time
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }
}

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
