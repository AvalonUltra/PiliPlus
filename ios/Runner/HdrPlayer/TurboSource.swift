import AVFoundation
import Foundation

/// One DASH track as loaded by DashHlsBridge, kept for fast-rate playback.
struct TurboTrackSource {
    struct Segment {
        let offset: UInt64
        let size: UInt64
        let duration: Double
    }

    let tag: String
    /// Remote URL, or a local file path when `isLocal`.
    let url: String
    let isLocal: Bool
    /// ftyp+moov exactly as served to the HLS engine (sample entry patches applied).
    let initBytes: [UInt8]
    let segments: [Segment]
    let width: Int
    let height: Int
}

/// A prepared fast-rate window: an ordinary MP4 covering
/// content time [origin, end] of the current video track (+ audio).
final class TurboWindow {
    let videoTag: String
    /// Content time shown at window time 0.
    let origin: Double
    /// Content time where the window stops presenting.
    let end: Double
    /// The window runs to the end of the content.
    let reachesEnd: Bool
    let asset: AVURLAsset
    let loader: TurboAssetLoader

    init(videoTag: String, origin: Double, end: Double, reachesEnd: Bool, asset: AVURLAsset, loader: TurboAssetLoader) {
        self.videoTag = videoTag
        self.origin = origin
        self.end = end
        self.reachesEnd = reachesEnd
        self.asset = asset
        self.loader = loader
    }

    func covers(_ contentTime: Double, margin: Double) -> Bool {
        contentTime >= origin && (reachesEnd ? contentTime < end : contentTime + margin < end)
    }
}

/// Builds fast-rate windows from the DASH tracks of one session. Moof headers
/// are fetched per segment on demand and cached for later windows.
final class TurboSource {
    let videos: [TurboTrackSource]
    let audio: TurboTrackSource?
    private let headers: [String: String]
    private let lock = NSLock()
    private var inits: [String: TurboTrackInit] = [:]
    private var cache: [String: [Int: [TurboFragment]]] = [:]
    private var windowCounter = 0
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    init(videos: [TurboTrackSource], audio: TurboTrackSource?, headers: [String: String]) {
        self.videos = videos
        self.audio = audio
        self.headers = headers
    }

    deinit {
        session.invalidateAndCancel()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The video track whose size matches the picture currently shown.
    func videoTag(matching size: CGSize) -> String? {
        guard let first = videos.first else { return nil }
        guard videos.count > 1, size.width > 0, size.height > 0 else { return first.tag }
        let exact = videos.first { $0.width == Int(size.width) && $0.height == Int(size.height) }
        if let exact { return exact.tag }
        return videos.min { abs($0.height - Int(size.height)) < abs($1.height - Int(size.height)) }?.tag
    }

    /// Builds a window that starts at the segment containing `contentTime`
    /// and covers at least `minDuration` seconds (or runs to the end).
    func makeWindow(videoTag: String, from contentTime: Double, minDuration: Double) async throws -> TurboWindow {
        guard let video = videos.first(where: { $0.tag == videoTag }) else {
            throw TurboMp4Error.unsupported("unknown video track \(videoTag)")
        }
        let videoInit = try trackInit(video)
        guard videoInit.isVideo, !video.segments.isEmpty else {
            throw TurboMp4Error.unsupported("not a video track")
        }

        let starts = Self.starts(video.segments)
        var i0 = 0
        while i0 + 1 < video.segments.count, starts[i0 + 1] <= contentTime { i0 += 1 }
        var i1 = i0
        while i1 + 1 < video.segments.count,
              starts[i1] + video.segments[i1].duration - starts[i0] < minDuration {
            i1 += 1
        }
        let videoFragments = try await fragments(video, videoInit, i0 ... i1)
        guard let first = videoFragments.first else { throw TurboMp4Error.malformed("no video fragments") }

        let videoScale = Double(videoInit.timescale)
        let origin = Double(first.baseDecodeTime) / videoScale
        let videoMedia = videoFragments.reduce(UInt64(0)) { $0 + $1.duration }
        let skip = UInt64(max(0, videoInit.mediaTime))
        guard videoMedia > skip else { throw TurboMp4Error.malformed("window shorter than edit") }
        let videoPresent = videoMedia - skip
        let end = origin + Double(videoPresent) / videoScale

        let videoWindow = TurboTrackWindow(
            track: videoInit,
            fragments: videoFragments,
            regionStart: video.segments[i0].offset,
            regionEnd: video.segments[i1].offset + video.segments[i1].size,
            mediaTime: videoInit.mediaTime,
            presentDuration: videoPresent
        )

        var audioWindow: TurboTrackWindow?
        if let audio, !audio.segments.isEmpty {
            let audioInit = try trackInit(audio)
            guard !audioInit.isVideo else { throw TurboMp4Error.unsupported("audio track is video") }
            let audioScale = Double(audioInit.timescale)
            let audioStarts = Self.starts(audio.segments)
            var j0 = 0
            while j0 + 1 < audio.segments.count, audioStarts[j0 + 1] <= origin - 0.2 { j0 += 1 }
            var j1 = j0
            while j1 + 1 < audio.segments.count,
                  audioStarts[j1] + audio.segments[j1].duration < end + 0.2 {
                j1 += 1
            }
            var audioFragments = try await fragments(audio, audioInit, j0 ... j1)
            // sidx durations are approximate; make sure the first audio
            // fragment really starts at or before the video origin.
            let originTicks = origin * audioScale + Double(audioInit.mediaTime)
            while j0 > 0, let head = audioFragments.first, Double(head.baseDecodeTime) > originTicks {
                j0 -= 1
                audioFragments = try await fragments(audio, audioInit, j0 ... j0) + audioFragments
            }
            if let head = audioFragments.first {
                let mediaTime = max(
                    0,
                    Int64((origin * audioScale).rounded()) - Int64(head.baseDecodeTime) + audioInit.mediaTime
                )
                let audioMedia = audioFragments.reduce(UInt64(0)) { $0 + $1.duration }
                if audioMedia > UInt64(mediaTime) {
                    let wanted = UInt64(((end - origin) * audioScale).rounded())
                    audioWindow = TurboTrackWindow(
                        track: audioInit,
                        fragments: audioFragments,
                        regionStart: audio.segments[j0].offset,
                        regionEnd: audio.segments[j1].offset + audio.segments[j1].size,
                        mediaTime: mediaTime,
                        presentDuration: min(audioMedia - UInt64(mediaTime), wanted)
                    )
                }
            }
        }

        let movie = try turboBuildMovie(video: videoWindow, audio: audioWindow)
        var sources = [video]
        if audioWindow != nil, let audio { sources.append(audio) }
        let loader = TurboAssetLoader(movie: movie, sources: sources, headers: headers)
        let id: Int = locked {
            windowCounter += 1
            return windowCounter
        }
        let url = URL(string: "\(TurboAssetLoader.scheme)://window\(id)/turbo.mp4")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return TurboWindow(
            videoTag: videoTag,
            origin: origin,
            end: end,
            reachesEnd: i1 == video.segments.count - 1,
            asset: asset,
            loader: loader
        )
    }

    // MARK: - Fragments

    private static func starts(_ segments: [TurboTrackSource.Segment]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(segments.count)
        var t = 0.0
        for s in segments {
            result.append(t)
            t += s.duration
        }
        return result
    }

    private func trackInit(_ track: TurboTrackSource) throws -> TurboTrackInit {
        if let cached = locked({ inits[track.tag] }) { return cached }
        let parsed = try TurboTrackInit(bytes: track.initBytes)
        locked { inits[track.tag] = parsed }
        return parsed
    }

    private func fragments(
        _ track: TurboTrackSource,
        _ trackInit: TurboTrackInit,
        _ range: ClosedRange<Int>
    ) async throws -> [TurboFragment] {
        var results: [Int: [TurboFragment]] = [:]
        try await withThrowingTaskGroup(of: (Int, [TurboFragment]).self) { group in
            var next = range.lowerBound
            let limit = 6
            while next <= range.upperBound, next - range.lowerBound < limit {
                let k = next
                next += 1
                group.addTask { (k, try await self.segmentFragments(track, trackInit, k)) }
            }
            while let (k, value) = try await group.next() {
                results[k] = value
                if next <= range.upperBound {
                    let k = next
                    next += 1
                    group.addTask { (k, try await self.segmentFragments(track, trackInit, k)) }
                }
            }
        }
        return try range.flatMap { k -> [TurboFragment] in
            guard let value = results[k] else { throw TurboMp4Error.malformed("missing segment \(k)") }
            return value
        }
    }

    /// Parses every moof of one sidx subsegment (normally exactly one).
    private func segmentFragments(
        _ track: TurboTrackSource,
        _ trackInit: TurboTrackInit,
        _ k: Int
    ) async throws -> [TurboFragment] {
        if let cached = locked({ cache[track.tag]?[k] }) { return cached }
        try Task.checkCancellation()

        let segment = track.segments[k]
        let end = segment.offset + segment.size
        var buffer: [UInt8] = []
        var bufferStart: UInt64 = 0
        func covers(_ from: UInt64, _ to: UInt64) -> Bool {
            from >= bufferStart && to <= bufferStart + UInt64(buffer.count)
        }

        var result: [TurboFragment] = []
        var position = segment.offset
        while position + 8 <= end {
            if !covers(position, min(end, position + 16)) {
                buffer = try await read(track, from: position, length: min(8 << 10, end - position))
                bufferStart = position
            }
            guard let header = turboBoxHeader(buffer, at: Int(position - bufferStart)) else {
                throw TurboMp4Error.malformed("unreadable box in segment \(k)")
            }
            let boxEnd = position + UInt64(header.size)
            guard boxEnd <= end else { throw TurboMp4Error.malformed("box crosses segment \(k)") }
            if header.type == "moof" {
                if !covers(position, boxEnd) {
                    buffer = try await read(track, from: position, length: min(UInt64(header.size) + 16, end - position))
                    bufferStart = position
                }
                result.append(
                    try turboParseMoof(buffer, at: Int(position - bufferStart), moofOffset: position, track: trackInit)
                )
            }
            position = boxEnd
        }
        guard !result.isEmpty else { throw TurboMp4Error.malformed("segment \(k) has no moof") }
        locked { cache[track.tag, default: [:]][k] = result }
        return result
    }

    private func read(_ track: TurboTrackSource, from offset: UInt64, length: UInt64) async throws -> [UInt8] {
        if track.isLocal {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: track.url))
            defer { try? handle.close() }
            handle.seek(toFileOffset: offset)
            return [UInt8](handle.readData(ofLength: Int(length)))
        }
        guard let url = URL(string: track.url) else { throw TurboMp4Error.malformed("bad url") }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        let handle = CancellableTask()
        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: TurboMp4Error.malformed("empty response"))
                    }
                }
                handle.start(task)
            }
        } onCancel: {
            handle.cancel()
        }
        guard let http = response as? HTTPURLResponse else { throw TurboMp4Error.malformed("no http response") }
        if http.statusCode == 206 {
            guard TurboAssetLoader.contentRangeStart(http) == offset else {
                throw TurboMp4Error.malformed("content-range mismatch")
            }
            return [UInt8](data.prefix(Int(length)))
        }
        if http.statusCode == 200, offset == 0 {
            return [UInt8](data.prefix(Int(length)))
        }
        throw DashHlsError.http(http.statusCode, url.host ?? "?")
    }
}

/// Lets Swift task cancellation cancel a URLSession task (window builds are
/// abandoned on dispose).
private final class CancellableTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func start(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

// MARK: - Resource loader

/// Serves a TurboMovie to AVFoundation: header bytes from memory, mdat bytes
/// mapped onto byte ranges of the source tracks (CDN or local files).
final class TurboAssetLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let scheme = "piliplusturbo"

    let queue = DispatchQueue(label: "piliplus.turbo.loader")
    private let movie: TurboMovie
    private let sources: [TurboTrackSource]
    private let headers: [String: String]
    private var session: URLSession?
    private var invalidated = false

    private enum Piece {
        case header(Range<Int>)
        case source(index: Int, offset: UInt64, length: UInt64)
    }

    private final class Job {
        let request: AVAssetResourceLoadingRequest
        var pieces: [Piece]
        var task: URLSessionDataTask?
        var expectedStart: UInt64 = 0
        var expectedLength: UInt64 = 0
        var received: UInt64 = 0
        var retries = 0
        var current: Piece?
        var cancelled = false

        init(request: AVAssetResourceLoadingRequest, pieces: [Piece]) {
            self.request = request
            self.pieces = pieces
        }
    }

    private var jobs: [ObjectIdentifier: Job] = [:]
    private var taskJobs: [Int: Job] = [:]

    init(movie: TurboMovie, sources: [TurboTrackSource], headers: [String: String]) {
        self.movie = movie
        self.sources = sources
        self.headers = headers
        super.init()
    }

    /// Breaks the URLSession ↔ delegate retain cycle; call when the window is dropped.
    func invalidate() {
        queue.async {
            self.invalidated = true
            for job in self.jobs.values {
                job.cancelled = true
                job.task?.cancel()
            }
            self.jobs.removeAll()
            self.taskJobs.removeAll()
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }

    private func urlSession() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let created = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        session = created
        return created
    }

    static func contentRangeStart(_ response: HTTPURLResponse) -> UInt64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        // "bytes 123-456/789"
        let spec = value.split(separator: " ").last ?? ""
        return spec.split(separator: "-").first.flatMap { UInt64($0) }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        if invalidated {
            loadingRequest.finishLoading(with: TurboMp4Error.unsupported("window released"))
            return true
        }
        let total = movie.totalLength
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = AVFileType.mp4.rawValue
            info.contentLength = Int64(total)
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = UInt64(max(0, dataRequest.requestedOffset))
        let end = dataRequest.requestsAllDataToEndOfResource
            ? total
            : min(total, start + UInt64(max(0, dataRequest.requestedLength)))
        guard start < end else {
            loadingRequest.finishLoading()
            return true
        }
        let job = Job(request: loadingRequest, pieces: pieces(from: start, to: end))
        jobs[ObjectIdentifier(loadingRequest)] = job
        advance(job)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let job = jobs.removeValue(forKey: ObjectIdentifier(loadingRequest)) else { return }
        job.cancelled = true
        if let task = job.task {
            taskJobs.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
    }

    private func pieces(from start: UInt64, to end: UInt64) -> [Piece] {
        var result: [Piece] = []
        let headerLength = UInt64(movie.header.count)
        if start < headerLength {
            result.append(.header(Int(start) ..< Int(min(end, headerLength))))
        }
        var regionStart = headerLength
        for region in movie.regions {
            let regionEnd = regionStart + region.length
            let a = max(start, regionStart)
            let b = min(end, regionEnd)
            if a < b {
                result.append(.source(index: region.source, offset: region.sourceOffset + (a - regionStart), length: b - a))
            }
            regionStart = regionEnd
        }
        return result
    }

    private func finish(_ job: Job, error: Error? = nil) {
        jobs.removeValue(forKey: ObjectIdentifier(job.request))
        if let task = job.task {
            taskJobs.removeValue(forKey: task.taskIdentifier)
            job.task = nil
        }
        guard !job.cancelled else { return }
        job.cancelled = true
        if let error {
            job.request.finishLoading(with: error)
        } else {
            job.request.finishLoading()
        }
    }

    private func advance(_ job: Job) {
        guard !job.cancelled, !invalidated else { return }
        guard !job.pieces.isEmpty else {
            finish(job)
            return
        }
        let piece = job.pieces.removeFirst()
        job.current = piece
        switch piece {
        case .header(let range):
            job.request.dataRequest?.respond(with: Data(movie.header[range]))
            advance(job)
        case .source(let index, let offset, let length):
            let source = sources[index]
            if source.isLocal {
                readLocal(job, path: source.url, offset: offset, remaining: length)
            } else {
                guard let url = URL(string: source.url) else {
                    finish(job, error: TurboMp4Error.malformed("bad url"))
                    return
                }
                var request = URLRequest(url: url)
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
                let task = urlSession().dataTask(with: request)
                job.task = task
                job.expectedStart = offset
                job.expectedLength = length
                job.received = 0
                taskJobs[task.taskIdentifier] = job
                task.resume()
            }
        }
    }

    private func readLocal(_ job: Job, path: String, offset: UInt64, remaining: UInt64) {
        guard !job.cancelled, !invalidated else { return }
        guard remaining > 0 else {
            advance(job)
            return
        }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            handle.seek(toFileOffset: offset)
            let chunk = handle.readData(ofLength: Int(min(remaining, 1 << 20)))
            guard !chunk.isEmpty else {
                finish(job, error: TurboMp4Error.malformed("local file truncated"))
                return
            }
            job.request.dataRequest?.respond(with: chunk)
            let count = UInt64(chunk.count)
            // Yield between chunks so cancellation can land.
            queue.async { [weak self] in
                self?.readLocal(job, path: path, offset: offset + count, remaining: remaining - count)
            }
        } catch {
            finish(job, error: error)
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let job = taskJobs[dataTask.taskIdentifier], !job.cancelled else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        let ok = http?.statusCode == 206 && http.flatMap(Self.contentRangeStart) == job.expectedStart
        if !ok {
            completionHandler(.cancel)
            finish(job, error: DashHlsError.http(http?.statusCode ?? -1, dataTask.originalRequest?.url?.host ?? "?"))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = taskJobs[dataTask.taskIdentifier], !job.cancelled else { return }
        let room = job.expectedLength - job.received
        let slice = UInt64(data.count) > room ? data.prefix(Int(room)) : data
        if !slice.isEmpty {
            job.request.dataRequest?.respond(with: slice)
            job.received += UInt64(slice.count)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = taskJobs.removeValue(forKey: task.taskIdentifier) else { return }
        job.task = nil
        guard !job.cancelled else { return }
        if job.received >= job.expectedLength {
            advance(job)
            return
        }
        // Short read (connection dropped mid-range): resume where it stopped.
        if case .source(let index, let offset, let length)? = job.current,
           job.retries < 3 || job.received > 0 {
            // Count only failures that made no progress.
            job.retries = job.received > 0 ? 1 : job.retries + 1
            let done = job.received
            job.pieces.insert(.source(index: index, offset: offset + done, length: length - done), at: 0)
            advance(job)
            return
        }
        finish(job, error: error ?? TurboMp4Error.malformed("short read"))
    }
}
