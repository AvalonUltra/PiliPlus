import AVFoundation
import Flutter
import UIKit

/// Hosts one AVPlayerLayer per playback engine of a session ("slot" 0 is the
/// HLS player, 1/2 are fast-rate windows). Every layer stays in the render
/// tree; the active engine's layer is simply raised above the others, so an
/// incoming engine has already rendered its first frame when it is revealed.
final class HdrPlayerContainerView: UIView {
    private var slotLayers: [Int: AVPlayerLayer] = [:]
    private var frontSlot = 0

    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            for layer in slotLayers.values { layer.videoGravity = videoGravity }
        }
    }

    func setPlayer(_ player: AVPlayer?, slot: Int) {
        if player == nil {
            if let layer = slotLayers.removeValue(forKey: slot) {
                layer.player = nil
                layer.removeFromSuperlayer()
            }
            return
        }
        let layer = slotLayers[slot] ?? {
            let created = AVPlayerLayer()
            created.videoGravity = videoGravity
            created.frame = bounds
            self.layer.addSublayer(created)
            slotLayers[slot] = created
            return created
        }()
        layer.player = player
        bringToFront(slot: frontSlot)
    }

    func bringToFront(slot: Int) {
        frontSlot = slot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (s, layer) in slotLayers {
            layer.zPosition = s == slot ? 1 : 0
        }
        CATransaction.commit()
    }

    func detachAll() {
        for layer in slotLayers.values { layer.player = nil }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in slotLayers.values { layer.frame = bounds }
        CATransaction.commit()
    }
}

/// One AVPlayer with its item; `window` is set for fast-rate engines, whose
/// item time is offset from the content time by `window.origin`.
private final class PlaybackEngine {
    let slot: Int
    let player = AVPlayer()
    let window: TurboWindow?
    var videoOutput: AVPlayerItemVideoOutput?
    var observations: [NSKeyValueObservation] = []
    var notificationTokens: [NSObjectProtocol] = []
    var dropped = false

    init(slot: Int, window: TurboWindow?) {
        self.slot = slot
        self.window = window
        player.actionAtItemEnd = .pause
    }

    var isMain: Bool { window == nil }
    var origin: Double { window?.origin ?? 0 }
    var item: AVPlayerItem? { player.currentItem }

    func contentTime() -> Double {
        guard let item else { return origin }
        let seconds = item.currentTime().seconds
        return (seconds.isFinite ? seconds : 0) + origin
    }

    func itemTime(_ content: Double) -> CMTime {
        CMTime(seconds: max(0, content - origin), preferredTimescale: 90000)
    }

    func covers(_ content: Double, margin: Double) -> Bool {
        window?.covers(content, margin: margin) ?? true
    }

    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        window?.loader.invalidate()
    }
}

/// A hand-over from the active engine to another one at a common content time.
private final class EngineTransition {
    let from: PlaybackEngine
    let toMain: Bool
    var target: PlaybackEngine?
    var targetTime: Double = 0
    var attempts = 0
    var seekIssuedAt: CFTimeInterval = 0
    /// Bumped for every seek issued on the target; callbacks of superseded
    /// seeks/prerolls compare it and bail out.
    var generation = 0
    /// forceSwap is in progress; everything else stands down.
    var forcing = false
    var readyObservation: NSKeyValueObservation?
    var boundaryToken: Any?
    var deadline: DispatchWorkItem?

    init(from: PlaybackEngine, toMain: Bool) {
        self.from = from
        self.toMain = toMain
    }
}

/// One playback session backed by AVPlayer, mirroring the event protocol of
/// the Android Media3 implementation in HdrPlayerPlugin.kt.
///
/// AVPlayer's HLS engine renders at most 2x: above that it switches to trick
/// play and shows keyframes only. Rates above 2x therefore run on a second
/// AVPlayer playing an ordinary MP4 window of the same DASH bytes
/// (TurboSource). The HLS player keeps going at 2x until that window is
/// ready, then the two meet at a common content time and swap seamlessly;
/// dropping back to <= 2x hands over the same way.
final class HdrPlayerSession: NSObject {
    private static let hlsMaxRate: Float = 2.0
    private static let windowSeconds = 120.0

    private let sessionId: Int
    private let sendEvent: (Int, String, [String: Any]) -> Void

    private let main = PlaybackEngine(slot: 0, window: nil)
    private var player: AVPlayer { main.player }
    private lazy var active: PlaybackEngine = main
    /// Inactive fast-rate engine kept for the next hand-over.
    private var spare: PlaybackEngine?
    private var transition: EngineTransition?
    private var turboSource: TurboSource?
    private var turboBlockedUntil: CFTimeInterval = 0
    private var unblockWork: DispatchWorkItem?
    /// Highest rate Dart may ask for soon (long-press speed); above 2x the
    /// next window is prepared ahead of time so a press engages quickly.
    private var fastRateHint: Float = 0
    /// The single in-flight window build (not tied to a transition, so a
    /// cancelled hand-over still leaves a warm window behind).
    private var windowTask: Task<Void, Never>?
    /// A built window nobody has used yet.
    private var warmWindow: TurboWindow?
    private var lastWarmAttempt: CFTimeInterval = 0
    /// Wall-clock lead (seconds) given to the incoming engine; adapted to how
    /// long seek + preroll actually took.
    private var leadToFast = 1.0
    private var leadToMain = 0.8
    /// Main became active but its layer is raised only once its seek lands,
    /// so a stale frame from minutes ago is never shown.
    private var mainRaisePending = false
    /// Main took over from a playing fast engine and must resume once its
    /// seek lands, even if Dart seeks again before that.
    private var resumeMainAfterSeek = false
    /// A > 2x rate was used in this session; only then is a ready spare
    /// engine kept around (otherwise warm-ups prepare the window only).
    private var fastRateUsed = false

    private var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// Every Flutter platform view showing this session (see makeView()).
    private let attachedViews = NSHashTable<HdrPlayerContainerView>.weakObjects()
    private var bridge: DashHlsBridge?
    private var progressTimer: Timer?

    private var playWhenReady = false {
        didSet {
            // While this session wants sound, other components must not be
            // able to deactivate the shared audio session under it.
            if playWhenReady, !disposed {
                AudioSessionGuard.hold(self)
            } else {
                AudioSessionGuard.release(self)
            }
        }
    }
    private var desiredRate: Float = 1.0
    private var volume: Float = 1.0
    private var reportedPlaying = false
    private var pendingStartMs: Int64 = 0
    private var disposed = false

    init(sessionId: Int, sendEvent: @escaping (Int, String, [String: Any]) -> Void) {
        self.sessionId = sessionId
        self.sendEvent = sendEvent
        super.init()
    }

    /// The audio session is process-wide state. Switching to this backend
    /// disposes the media_kit player, which tears down the `.playback`
    /// category it had installed; without re-arming it the session falls back
    /// to `.soloAmbient`, where the ring/silent switch mutes playback outright
    /// and audio stops in the background. AVPlayer itself never configures
    /// this, so every session must claim it before attaching an item.
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal: playback still works through the speaker in most
            // states, only silent-switch/background behaviour degrades.
            NSLog("[HdrPlayer] audio session setup failed: \(error)")
        }
    }

    /// A fresh view for one Flutter platform view, with its own AVPlayerLayers
    /// on the session's players (multiple layers per player are supported).
    ///
    /// Handing every platform view the same UIView breaks across page
    /// transitions: all video pages share one player controller, so while
    /// the outgoing page is popped it still rebuilds against the session the
    /// returning page just opened, re-parents the single view into its own
    /// platform view, and takes it along when it is disposed — the returning
    /// page is left black with audio still playing.
    func makeView() -> HdrPlayerContainerView {
        let view = HdrPlayerContainerView()
        view.backgroundColor = .clear
        view.videoGravity = videoGravity
        if !disposed {
            for engine in liveEngines {
                view.setPlayer(engine.player, slot: engine.slot)
            }
            view.bringToFront(slot: active.slot)
        }
        attachedViews.add(view)
        return view
    }

    private var liveEngines: [PlaybackEngine] {
        var engines = [main]
        if !active.isMain { engines.append(active) }
        if let spare, spare !== active { engines.append(spare) }
        return engines
    }

    // MARK: - Public control surface

    func open(
        videoUrl: String,
        audioUrl: String?,
        isFileSource: Bool,
        startMs: Int64,
        headers: [String: String],
        fitMode: String,
        qualityCode: Int?,
        frameRate: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        variants: [DashHlsBridge.VariantInput]? = nil
    ) {
        setFitMode(fitMode)
        activateAudioSession()
        pendingStartMs = startMs
        let bridge = DashHlsBridge(headers: headers)
        self.bridge = bridge
        Task { [weak self] in
            do {
                if let variants, variants.count > 1 {
                    // Multi-variant ABR: AVPlayer switches quality seamlessly.
                    try await bridge.prepare(
                        variants: variants,
                        audioUrl: audioUrl,
                        isFileSource: isFileSource
                    )
                } else {
                    try await bridge.prepare(
                        videoUrl: variants?.first?.url ?? videoUrl,
                        audioUrl: audioUrl,
                        isFileSource: isFileSource,
                        qualityCode: qualityCode,
                        frameRate: frameRate,
                        width: width,
                        height: height
                    )
                }
                await MainActor.run { [weak self] in
                    self?.attachItem(bridge: bridge, headers: headers)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.reportError(error)
                }
            }
        }
    }

    private func attachItem(bridge: DashHlsBridge, headers: [String: String]) {
        if disposed { return }
        var options: [String: Any] = [:]
        // Applies to every HTTP request AVPlayer issues for this asset,
        // including the media segments that go straight to the CDN.
        options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        let asset = AVURLAsset(url: bridge.masterUrl, options: options)
        asset.resourceLoader.setDelegate(bridge, queue: bridge.resourceLoaderQueue)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        turboSource = bridge.makeTurboSource()

        observeMain(item)
        player.replaceCurrentItem(with: item)
        // Watchdog: if the item never becomes ready, surface an error so the
        // Dart side can fall back instead of showing a black view forever.
        // Only fail when nothing has been fetched — if bytes are flowing the
        // item is merely buffering on a slow connection, so keep waiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak item] in
            guard let self, !self.disposed, let item, item.status == .unknown else { return }
            let transferred = item.accessLog()?.events.last?.numberOfBytesTransferred ?? 0
            if transferred > 0 { return }
            self.reportError(
                NSError(
                    domain: "HdrPlayer",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "player not ready within 12s, no data transferred",
                    ]
                )
            )
        }
        if pendingStartMs > 0 {
            let target = CMTime(value: pendingStartMs, timescale: 1000)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if playWhenReady {
            player.playImmediately(atRate: rate(for: main))
            updateFastRate()
        }
    }

    func play() {
        playWhenReady = true
        guard main.item != nil else { return }
        // Re-arm: an interruption (call, another app) can deactivate the
        // session while this item stays loaded.
        activateAudioSession()
        active.player.playImmediately(atRate: rate(for: active))
        updateFastRate()
    }

    func pause() {
        playWhenReady = false
        resumeMainAfterSeek = false
        cancelTransition()
        for engine in liveEngines { engine.player.pause() }
    }

    func seekTo(positionMs: Int64) {
        let target = Double(max(0, positionMs)) / 1000
        cancelTransition()
        if !active.isMain {
            if active.covers(target, margin: 3) {
                let engine = active
                engine.player.seek(to: engine.itemTime(target), toleranceBefore: .zero, toleranceAfter: .zero) {
                    [weak self] finished in
                    self?.onMain {
                        guard let self, !self.disposed else { return }
                        self.sendTimeline()
                        if finished { self.updateFastRate() }
                    }
                }
                return
            }
            // Outside the fast-rate window: continue on the HLS player.
            let previous = active
            let wasPlaying = previous.player.rate != 0
            makeActive(main, raise: false)
            previous.player.pause()
            retire(previous)
            if wasPlaying { resumeMainAfterSeek = true }
            seekMain(to: target, resume: wasPlaying)
            return
        }
        seekMain(to: target, resume: false)
    }

    /// Seeks the HLS player. `resume` restarts it afterwards — only used when
    /// it takes over from a fast engine that was playing; a plain seek keeps
    /// whatever play state AVPlayer had (it may have paused on its own).
    private func seekMain(to target: Double, resume: Bool) {
        player.seek(to: CMTime(seconds: target, preferredTimescale: 90000), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            self?.onMain {
                guard let self, !self.disposed else { return }
                self.sendTimeline()
                // A superseded seek neither raises main (its frame is stale)
                // nor consumes the pending resume.
                guard finished, self.active === self.main else { return }
                self.raiseMainIfPending()
                let shouldResume = resume || self.resumeMainAfterSeek
                self.resumeMainAfterSeek = false
                if shouldResume, self.playWhenReady, self.player.timeControlStatus == .paused {
                    self.player.playImmediately(atRate: self.rate(for: self.main))
                    self.syncReportedState()
                }
                self.updateFastRate()
            }
        }
    }

    func setPlaybackSpeed(_ speed: Float) {
        desiredRate = max(0.1, speed)
        if desiredRate > Self.hlsMaxRate + 0.001 { fastRateUsed = true }
        if playWhenReady, active.player.timeControlStatus != .paused {
            active.player.rate = rate(for: active)
        }
        updateFastRate()
    }

    func setFastRateHint(_ rate: Float) {
        fastRateHint = rate
        maybeWarm()
    }

    func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        for engine in liveEngines { engine.player.volume = self.volume }
    }

    func setFitMode(_ fitMode: String) {
        switch fitMode {
        case "fill":
            videoGravity = .resize
        case "cover":
            videoGravity = .resizeAspectFill
        default:
            // contain / fitWidth / fitHeight: the Flutter side already sizes
            // the platform view, aspect fit matches Android's behaviour.
            videoGravity = .resizeAspect
        }
        for view in attachedViews.allObjects {
            view.videoGravity = videoGravity
        }
    }

    func screenshot() -> FlutterStandardTypedData? {
        let engine = active
        guard let item = engine.item else { return nil }
        // Attach the BGRA (SDR) output tap lazily: keeping it on the item
        // during normal playback pulls the pipeline out of the EDR/HDR path.
        let output: AVPlayerItemVideoOutput
        if let existing = engine.videoOutput {
            output = existing
        } else {
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            engine.videoOutput = output
            Thread.sleep(forTimeInterval: 0.15)
        }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) || item.status == .readyToPlay,
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return nil }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        guard let png = UIImage(cgImage: cgImage).pngData() else { return nil }
        return FlutterStandardTypedData(bytes: png)
    }

    func dispose() {
        disposed = true
        playWhenReady = false
        resumeMainAfterSeek = false
        cancelTransition()
        stopProgress()
        windowTask?.cancel()
        windowTask = nil
        unblockWork?.cancel()
        unblockWork = nil
        warmWindow?.loader.invalidate()
        warmWindow = nil
        for engine in liveEngines { engine.tearDown() }
        spare = nil
        active = main
        turboSource = nil
        for view in attachedViews.allObjects {
            view.detachAll()
        }
        bridge = nil
    }

    // MARK: - Fast-rate hand-over

    private func rate(for engine: PlaybackEngine) -> Float {
        engine.isMain ? min(desiredRate, Self.hlsMaxRate) : desiredRate
    }

    private var fastRateAvailable: Bool {
        turboSource != nil && CACurrentMediaTime() >= turboBlockedUntil
    }

    private var wantsFastEngine: Bool {
        desiredRate > Self.hlsMaxRate + 0.001 && fastRateAvailable
    }

    /// Reconciles which engine should play for the current rate and starts
    /// or cancels a hand-over accordingly. Only acts while playing.
    private func updateFastRate() {
        guard !disposed, playWhenReady, main.item?.status == .readyToPlay else { return }
        if active.isMain {
            if wantsFastEngine {
                ensureTransition(toMain: false)
            } else {
                cancelTransition()
                maybeWarm()
            }
        } else if wantsFastEngine {
            if transition?.toMain == true { cancelTransition() }
            checkWindowEnd()
        } else {
            ensureTransition(toMain: true)
        }
    }

    /// Stay on HLS (capped at 2x, still smooth) for a while after a failure.
    private func blockFastRate(_ error: Error) {
        NSLog("[HdrPlayer] fast-rate playback unavailable: \(error)")
        turboBlockedUntil = CACurrentMediaTime() + 30
        unblockWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateFastRate() }
        unblockWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.1, execute: work)
    }

    private func currentVideoTag() -> String? {
        if let tag = active.window?.videoTag { return tag }
        return turboSource?.videoTag(matching: main.item?.presentationSize ?? .zero)
    }

    /// Prepares the next window ahead of a likely speed-up (long press).
    private func maybeWarm() {
        guard !disposed, active.isMain, transition == nil, windowTask == nil,
              max(fastRateHint, desiredRate) > Self.hlsMaxRate + 0.001,
              fastRateAvailable,
              main.item?.status == .readyToPlay,
              CACurrentMediaTime() - lastWarmAttempt > 5
        else { return }
        let now = main.contentTime()
        // Rebuild once the remaining lead drops below a quarter window.
        let margin = Self.windowSeconds / 4
        if let spare, spare.covers(now + 2, margin: margin) { return }
        if let warmWindow, warmWindow.covers(now + 2, margin: margin) { return }
        lastWarmAttempt = CACurrentMediaTime()
        requestWindow(from: now)
    }

    private func requestWindow(from start: Double) {
        guard windowTask == nil, let source = turboSource, let tag = currentVideoTag() else { return }
        windowTask = Task { [weak self] in
            let began = CACurrentMediaTime()
            do {
                let window = try await source.makeWindow(
                    videoTag: tag,
                    from: start,
                    minDuration: Self.windowSeconds
                )
                NSLog(
                    "[HdrPlayer] fast-rate window %@ %.1f–%.1f s ready in %.2f s",
                    tag, window.origin, window.end, CACurrentMediaTime() - began
                )
                await MainActor.run { [weak self] in
                    guard let self else {
                        window.loader.invalidate()
                        return
                    }
                    self.windowReady(window)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.windowFailed(error)
                }
            }
        }
    }

    private func windowReady(_ window: TurboWindow) {
        windowTask = nil
        guard !disposed else {
            window.loader.invalidate()
            return
        }
        if let transition, !transition.toMain, transition.target == nil {
            let start = transition.from.contentTime()
            if window.covers(start + 1, margin: 10) {
                begin(transition, target: makeFastEngine(window))
            } else {
                // Built for a position we have since left (seek): rebuild.
                window.loader.invalidate()
                requestWindow(from: start)
            }
            return
        }
        // Nobody is waiting. Once > 2x has been used in this session, keep a
        // ready engine so a long press only has to seek it (item readiness
        // costs a round trip); before that only the window is kept, so
        // sessions that never speed up download nothing extra.
        if active.isMain, transition == nil, fastRateUsed {
            warmWindow?.loader.invalidate()
            warmWindow = nil
            _ = makeFastEngine(window, standby: true)
        } else {
            warmWindow?.loader.invalidate()
            warmWindow = window
        }
    }

    private func windowFailed(_ error: Error) {
        windowTask = nil
        guard !disposed, !(error is CancellationError) else { return }
        guard let transition, !transition.toMain, transition.target == nil else {
            // A background warm-up: just back off, a press builds its own.
            NSLog("[HdrPlayer] fast-rate warm-up failed: \(error)")
            lastWarmAttempt = CACurrentMediaTime() + 25
            return
        }
        blockFastRate(error)
        cancelTransition()
        updateFastRate()
    }

    private func checkWindowEnd() {
        guard !active.isMain, let window = active.window, !window.reachesEnd else { return }
        let now = active.contentTime()
        let remaining = window.end - now
        if remaining < max(0.3, Double(desiredRate) * 0.3) {
            // A hand-over that is already parked or forcing finishes on its
            // own (its deadline fires before the window ends).
            if let transition, transition.target != nil, remaining > 0.05 { return }
            // The next engine did not take over in time.
            hardSwitchToMain(at: now)
            return
        }
        if transition == nil, remaining < max(8, Double(desiredRate) * 4) {
            ensureTransition(toMain: !wantsFastEngine)
        }
    }

    private func ensureTransition(toMain: Bool) {
        if let current = transition {
            if current.toMain == toMain { return }
            cancelTransition()
        }
        let transition = EngineTransition(from: active, toMain: toMain)
        self.transition = transition
        if toMain {
            begin(transition, target: main)
            return
        }
        let start = active.contentTime()
        let expected = start + Double(max(0.5, rate(for: active))) * leadToFast
        if let spare, spare !== active, spare.covers(expected, margin: 20) {
            begin(transition, target: spare)
            return
        }
        if let window = warmWindow {
            warmWindow = nil
            if window.covers(expected, margin: 20) {
                begin(transition, target: makeFastEngine(window))
                return
            }
            window.loader.invalidate()
        }
        // An in-flight build (e.g. a warm-up) is picked up by windowReady.
        requestWindow(from: start)
    }

    private func makeFastEngine(_ window: TurboWindow, standby: Bool = false) -> PlaybackEngine {
        if let old = spare, old !== active, old !== transition?.target {
            drop(old)
        }
        let slot = active.slot == 1 ? 2 : 1
        let engine = PlaybackEngine(slot: slot, window: window)
        engine.player.volume = volume
        // A window that ends before the content must not pause itself at its
        // end (Dart would see a spurious "paused"); the hand-over or the
        // end-of-window fallback takes it from there.
        engine.player.actionAtItemEnd = window.reachesEnd ? .pause : .none
        let item = AVPlayerItem(asset: window.asset)
        // A standby engine only needs to become ready, not to buffer ahead.
        if standby { item.preferredForwardBufferDuration = 1 }
        observeFast(engine, item: item)
        engine.player.replaceCurrentItem(with: item)
        for view in attachedViews.allObjects {
            view.setPlayer(engine.player, slot: slot)
        }
        spare = engine
        return engine
    }

    private func drop(_ engine: PlaybackEngine) {
        guard engine !== main, engine !== active, !engine.dropped else { return }
        engine.dropped = true
        if spare === engine { spare = nil }
        engine.tearDown()
        for view in attachedViews.allObjects {
            view.setPlayer(nil, slot: engine.slot)
        }
    }

    /// Keeps a fast-rate engine that just went off screen as the spare
    /// (reusable for the next speed-up nearby); only one spare is kept.
    private func retire(_ engine: PlaybackEngine) {
        guard !engine.isMain, engine !== active, !engine.dropped else { return }
        if let old = spare, old !== engine {
            drop(old)
        }
        spare = engine
    }

    private func begin(_ transition: EngineTransition, target: PlaybackEngine) {
        transition.target = target
        guard let item = target.item else {
            transitionFailed(transition, TurboMp4Error.malformed("engine without item"))
            return
        }
        if item.status == .failed {
            transitionFailed(transition, item.error ?? TurboMp4Error.malformed("item failed"))
            return
        }
        if !target.isMain {
            item.preferredForwardBufferDuration = 0  // automatic again
        }
        // Seek right away even if the item is not ready yet: AVPlayer defers
        // the seek, and the item then loads the hand-over point directly
        // instead of first buffering the start of the window. Item failure
        // is reported through observeFast → fastEngineDied.
        seekTarget(transition)
    }

    /// The incoming engine could not be used: give up on this hand-over
    /// without touching the engine that is playing.
    private func transitionFailed(_ transition: EngineTransition, _ error: Error) {
        guard self.transition === transition else { return }
        let target = transition.target
        cancelTransition()
        if let target, !target.isMain {
            blockFastRate(error)
            drop(target)
        }
        updateFastRate()
    }

    /// Parks the incoming engine a little ahead of the outgoing one; the swap
    /// happens when the outgoing engine reaches that point.
    private func seekTarget(_ transition: EngineTransition) {
        guard self.transition === transition, !transition.forcing, let target = transition.target else { return }
        let from = transition.from
        let fromRate = max(0.5, Double(from.player.rate > 0 ? from.player.rate : rate(for: from)))
        let leadWall = (transition.toMain ? leadToMain : leadToFast) * pow(2, Double(transition.attempts))
        let now = from.contentTime()
        var targetTime = now + fromRate * leadWall
        if let window = target.window {
            if targetTime < window.origin, window.origin - now < 4 {
                targetTime = window.origin + 0.05
            }
            guard window.covers(targetTime, margin: 1) else {
                transitionFailed(transition, TurboMp4Error.malformed("window does not cover hand-over"))
                return
            }
        }
        if let window = from.window, !window.reachesEnd {
            // Meet before the outgoing window runs out, and before the
            // end-of-window fallback threshold (rate * 0.3 s of content).
            let limit = window.end - max(0.5, fromRate * 0.3)
            if targetTime > limit {
                if now + 0.2 >= limit {
                    forceSwap(transition)
                    return
                }
                targetTime = limit
            }
        }
        transition.targetTime = targetTime
        transition.seekIssuedAt = CACurrentMediaTime()
        transition.generation += 1
        let generation = transition.generation
        target.player.pause()
        target.player.seek(to: target.itemTime(targetTime), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self, weak transition] finished in
            self?.onMain {
                guard let self, let transition, self.transition === transition,
                      !transition.forcing, transition.generation == generation
                else { return }
                if finished {
                    self.prerollTarget(transition)
                } else {
                    self.retryOrForce(transition)
                }
            }
        }
        transition.deadline?.cancel()
        var delay = leadWall + 5
        if let window = from.window, !window.reachesEnd {
            // Force before the outgoing window ends, but after the meeting point.
            delay = min(delay, max(0.1, (window.end - now) / fromRate - 0.15))
        }
        let deadline = DispatchWorkItem { [weak self, weak transition] in
            guard let self, let transition, self.transition === transition else { return }
            if transition.from.player.rate == 0 {
                // The outgoing engine stopped (interruption): re-evaluate on play.
                self.cancelTransition()
                return
            }
            self.forceSwap(transition)
        }
        transition.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: deadline)
    }

    private func prerollTarget(_ transition: EngineTransition) {
        guard let target = transition.target, !transition.forcing else { return }
        let generation = transition.generation
        let arm = { [weak self, weak transition] in
            guard let self, let transition, self.transition === transition,
                  !transition.forcing, transition.generation == generation
            else { return }
            self.armBoundary(transition)
        }
        // preroll raises unless the player is ready and stopped.
        if target.player.status == .readyToPlay,
           target.item?.status == .readyToPlay,
           target.player.rate == 0 {
            target.player.preroll(atRate: rate(for: target)) { [weak self] _ in
                self?.onMain(arm)
            }
        } else {
            arm()
        }
    }

    private func learnLead(_ transition: EngineTransition) {
        let took = CACurrentMediaTime() - transition.seekIssuedAt
        guard took.isFinite, took > 0 else { return }
        let wanted = min(3.0, max(0.4, took * 1.3 + 0.15))
        if transition.toMain {
            leadToMain = (leadToMain + wanted) / 2
        } else {
            leadToFast = (leadToFast + wanted) / 2
        }
    }

    private func armBoundary(_ transition: EngineTransition) {
        guard !transition.forcing else { return }
        let from = transition.from
        learnLead(transition)
        if from.contentTime() >= transition.targetTime - 0.01 {
            retryOrForce(transition)
            return
        }
        let time = from.itemTime(transition.targetTime)
        transition.boundaryToken = from.player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: time)],
            queue: .main
        ) { [weak self, weak transition] in
            guard let self, let transition, self.transition === transition else { return }
            self.swap(transition)
        }
    }

    private func retryOrForce(_ transition: EngineTransition) {
        guard self.transition === transition, !transition.forcing else { return }
        removeBoundary(transition)
        transition.attempts += 1
        if transition.attempts >= 3 {
            forceSwap(transition)
        } else {
            seekTarget(transition)
        }
    }

    /// Last resort when the engines never meet: jump to where the outgoing
    /// engine is now (a small visible skip instead of an endless wait).
    private func forceSwap(_ transition: EngineTransition) {
        guard self.transition === transition, !transition.forcing, let target = transition.target else { return }
        transition.forcing = true
        transition.generation += 1
        removeBoundary(transition)
        transition.deadline?.cancel()
        transition.deadline = nil
        let now = transition.from.contentTime()
        guard target.covers(now, margin: 0.5) else {
            transitionFailed(transition, TurboMp4Error.malformed("forced hand-over outside window"))
            return
        }
        target.player.cancelPendingPrerolls()
        target.player.seek(to: target.itemTime(now), toleranceBefore: .zero, toleranceAfter: .positiveInfinity) {
            [weak self, weak transition] finished in
            self?.onMain {
                guard let self, let transition, self.transition === transition else { return }
                if finished {
                    self.swap(transition)
                } else {
                    self.transitionFailed(transition, TurboMp4Error.malformed("forced hand-over seek interrupted"))
                }
            }
        }
        // Never wait forever on the forced seek.
        let watchdog = DispatchWorkItem { [weak self, weak transition] in
            guard let self, let transition, self.transition === transition else { return }
            self.transitionFailed(transition, TurboMp4Error.malformed("forced hand-over timed out"))
        }
        transition.deadline = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: watchdog)
    }

    private func swap(_ transition: EngineTransition) {
        guard self.transition === transition, let target = transition.target else { return }
        removeBoundary(transition)
        transition.deadline?.cancel()
        transition.deadline = nil
        transition.readyObservation = nil
        self.transition = nil
        let from = transition.from
        let resume = playWhenReady && from.player.rate != 0
        NSLog(
            "[HdrPlayer] hand-over slot %d → %d at %.3f s (outgoing at %.3f s, attempt %d)",
            from.slot, target.slot, target.contentTime(), from.contentTime(), transition.attempts
        )
        makeActive(target)
        if resume {
            target.player.playImmediately(atRate: rate(for: target))
        }
        from.player.pause()
        if !target.isMain, spare === target {
            spare = nil
        }
        if !from.isMain {
            if target.isMain {
                retire(from)  // reusable for the next long press nearby
            } else {
                drop(from)
            }
        }
        syncReportedState()
        sendTimeline()
        updateFastRate()
    }

    private func removeBoundary(_ transition: EngineTransition) {
        if let token = transition.boundaryToken {
            transition.from.player.removeTimeObserver(token)
            transition.boundaryToken = nil
        }
    }

    private func cancelTransition() {
        guard let transition else { return }
        self.transition = nil
        transition.readyObservation = nil
        transition.deadline?.cancel()
        transition.deadline = nil
        removeBoundary(transition)
        if let target = transition.target, target !== active {
            target.player.pause()
        }
    }

    private func makeActive(_ engine: PlaybackEngine, raise: Bool = true) {
        active = engine
        engine.player.volume = volume
        if raise {
            mainRaisePending = false
            for view in attachedViews.allObjects {
                view.bringToFront(slot: engine.slot)
            }
        } else {
            mainRaisePending = true
            // Safety net in case the seek that should raise it never lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.active === engine else { return }
                self.raiseMainIfPending()
            }
        }
    }

    private func raiseMainIfPending() {
        guard mainRaisePending else { return }
        mainRaisePending = false
        for view in attachedViews.allObjects {
            view.bringToFront(slot: active.slot)
        }
    }

    /// Continue on the HLS player at `content` (fallback paths only).
    private func hardSwitchToMain(at content: Double) {
        guard !active.isMain else {
            cancelTransition()
            return
        }
        // A next fast window that is already parked can take over instead.
        if wantsFastEngine, let transition, let target = transition.target, !target.isMain,
           target.item?.status == .readyToPlay, target.covers(content, margin: 0.5) {
            forceSwap(transition)
            return
        }
        cancelTransition()
        let previous = active
        makeActive(main, raise: false)
        previous.player.pause()
        if let window = previous.window, window.end <= content + 1 {
            drop(previous)  // played out; keep any prepared next window instead
        } else {
            retire(previous)
        }
        if playWhenReady { resumeMainAfterSeek = true }
        seekMain(to: content, resume: playWhenReady)
    }

    private func fastEngineDied(_ engine: PlaybackEngine, error: Error) {
        guard !engine.dropped else { return }
        blockFastRate(error)
        if engine === active {
            hardSwitchToMain(at: engine.contentTime())
            drop(engine)
        } else if let transition, transition.target === engine {
            cancelTransition()
            drop(engine)
            updateFastRate()
        } else {
            drop(engine)
        }
    }

    // MARK: - Observation

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private func observeMain(_ item: AVPlayerItem) {
        let engine = main
        engine.observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            self?.onMain {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    if self.active === engine {
                        self.sendTimeline()
                        self.send("buffering", ["value": false])
                    }
                    self.send("ready")
                    self.updateFastRate()
                case .failed:
                    self.reportError(item.error ?? DashHlsError.parse("item failed"))
                default:
                    break
                }
            }
        })

        engine.observations.append(item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            if size.width > 0, size.height > 0 {
                self?.send("size", ["width": Int(size.width), "height": Int(size.height)])
            }
        })

        observeCommon(engine, item: item)

        engine.notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.active === engine else { return }
                self.contentCompleted()
            }
        )

        engine.notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notification in
                let error =
                    notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.reportError(error ?? DashHlsError.parse("failed to play to end"))
            }
        )
    }

    private func observeFast(_ engine: PlaybackEngine, item: AVPlayerItem) {
        engine.observations.append(item.observe(\.status, options: [.new]) { [weak self, weak engine] item, _ in
            guard item.status == .failed else { return }
            self?.onMain {
                guard let self, let engine else { return }
                self.fastEngineDied(engine, error: item.error ?? TurboMp4Error.malformed("item failed"))
            }
        })

        observeCommon(engine, item: item)

        engine.notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak engine] _ in
                guard let self, let engine, self.active === engine, let window = engine.window else { return }
                if window.reachesEnd {
                    self.contentCompleted()
                } else {
                    self.hardSwitchToMain(at: window.end)
                }
            }
        )

        engine.notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak engine] notification in
                guard let self, let engine else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.fastEngineDied(engine, error: error ?? TurboMp4Error.malformed("failed to play to end"))
            }
        )
    }

    /// Buffering and play state, forwarded only for the engine on screen.
    private func observeCommon(_ engine: PlaybackEngine, item: AVPlayerItem) {
        engine.observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self, weak engine] item, _ in
            guard item.isPlaybackBufferEmpty else { return }
            self?.onMain {
                guard let self, self.active === engine else { return }
                self.send("buffering", ["value": true])
            }
        })

        engine.observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self, weak engine] item, _ in
            guard item.isPlaybackLikelyToKeepUp else { return }
            self?.onMain {
                guard let self, self.active === engine else { return }
                self.send("buffering", ["value": false])
            }
        })

        engine.observations.append(engine.player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak engine] _, _ in
            self?.onMain {
                guard let self, let engine, self.active === engine else { return }
                self.syncReportedState()
            }
        })
    }

    /// Emits playing / paused / buffering for the active engine's state.
    private func syncReportedState() {
        guard !disposed else { return }
        switch active.player.timeControlStatus {
        case .playing:
            reportedPlaying = true
            send("playing")
            startProgress()
        case .waitingToPlayAtSpecifiedRate:
            send("buffering", ["value": true])
        case .paused:
            if reportedPlaying {
                reportedPlaying = false
                send("paused")
            }
            stopProgress()
        @unknown default:
            break
        }
    }

    private func contentCompleted() {
        cancelTransition()
        resumeMainAfterSeek = false
        playWhenReady = false
        send("completed")
        stopProgress()
    }



    // MARK: - Progress heartbeat (250 ms, mirrors the Android tick)

    private func startProgress() {
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Like the old periodic time observer: no position ticks while
            // stalled (Dart clears its buffering indicator on every tick).
            if self.active.player.timeControlStatus == .playing {
                self.sendTimeline()
            }
            if self.active.isMain {
                self.maybeWarm()
            } else {
                self.checkWindowEnd()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func sendTimeline() {
        guard let mainItem = main.item else { return }
        let engine = active
        let positionMs = Int64(engine.contentTime() * 1000)
        let durationMs = mainItem.duration.milliseconds
        var bufferedMs: Int64 = 0
        if let item = engine.item {
            // The range around the playhead; older ranges linger after seeks.
            let now = item.currentTime().seconds
            for value in item.loadedTimeRanges {
                let range = value.timeRangeValue
                let start = range.start.seconds
                let end = CMTimeAdd(range.start, range.duration).seconds
                if start.isFinite, end.isFinite, start <= now + 0.5, end >= now {
                    bufferedMs = max(bufferedMs, Int64((end + engine.origin) * 1000))
                }
            }
        }
        send(
            "position",
            [
                "positionMs": positionMs,
                "durationMs": durationMs,
                "bufferedMs": max(bufferedMs, positionMs),
            ]
        )
        send("duration", ["durationMs": durationMs])
        send("buffered", ["bufferedMs": max(bufferedMs, positionMs)])
    }

    // MARK: - Events

    private func send(_ type: String, _ data: [String: Any] = [:]) {
        sendEvent(sessionId, type, data)
    }

    private func reportError(_ error: Error) {
        var isAudioError = false
        if let dashError = error as? DashHlsError {
            isAudioError = dashError.isAudioError
        }
        let nsError = error as NSError
        var logDetail = ""
        if let last = main.item?.errorLog()?.events.last {
            var uri = last.uri ?? "-"
            if uri.count > 120 { uri = String(uri.prefix(120)) + "…" }
            logDetail = " || log[\(last.errorStatusCode) \(last.errorComment ?? "")] \(uri)"
        }
        send(
            "error",
            [
                "message": error.localizedDescription + logDetail,
                "errorCode": nsError.code,
                "errorCodeName": "\(nsError.domain)(\(nsError.code))",
                "cause": (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.description ?? "",
                "rendererName": "",
                "rendererFormat": "",
                "isAudioError": isAudioError,
            ]
        )
    }
}

extension CMTime {
    var milliseconds: Int64 {
        guard isNumeric, seconds.isFinite else { return 0 }
        return Int64(seconds * 1000)
    }
}
