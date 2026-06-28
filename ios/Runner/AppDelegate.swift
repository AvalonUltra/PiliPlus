import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.applicationSupportsShakeToEdit = false // Disable shake to undo
    if let registrar = registrar(forPlugin: "IosHdrPlayerPlugin") {
      IosHdrPlayerPlugin.register(with: registrar)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IosHdrPlayerPlugin") {
      IosHdrPlayerPlugin.register(with: registrar)
    }
  }
}

private func intValue(_ value: Any?) -> Int? {
  if let value = value as? Int { return value }
  if let value = value as? NSNumber { return value.intValue }
  return nil
}

private func doubleValue(_ value: Any?) -> Double? {
  if let value = value as? Double { return value }
  if let value = value as? NSNumber { return value.doubleValue }
  return nil
}

private final class IosHdrPlayerPlugin: NSObject, FlutterPlugin {
  private static let channelName = "PiliPlus/IosHdrPlayer"
  private static let viewType = "com.example.piliplus/ios_hdr_player_view"

  private var sessions: [Int: IosHdrPlayerSession] = [:]
  private var nextSessionId = 1

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = IosHdrPlayerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.register(IosHdrPlayerViewFactory(plugin: instance), withId: viewType)
  }

  func session(id: Int) -> IosHdrPlayerSession? {
    sessions[id]
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "create":
        let id = nextSessionId
        nextSessionId += 1
        sessions[id] = IosHdrPlayerSession()
        result(id)
      case "supportsHdr":
        result(IosHdrPlayerSession.supportsHdr(qualityCode: intValue(args["qualityCode"])))
      case "open":
        try requireSession(args).open(arguments: args)
        result(nil)
      case "play":
        try requireSession(args).play()
        result(nil)
      case "pause":
        try requireSession(args).pause()
        result(nil)
      case "seekTo":
        try requireSession(args).seekTo(positionMs: intValue(args["positionMs"]) ?? 0)
        result(nil)
      case "setPlaybackSpeed":
        try requireSession(args).setPlaybackSpeed(doubleValue(args["speed"]) ?? 1.0)
        result(nil)
      case "setFitMode":
        try requireSession(args).setFitMode(args["fitMode"] as? String ?? "contain")
        result(nil)
      case "syncTo":
        try requireSession(args).syncTo(positionMs: intValue(args["positionMs"]) ?? 0)
        result(nil)
      case "screenshot":
        try requireSession(args).screenshot(result: result)
      case "dispose":
        if let sessionId = intValue(args["sessionId"]) {
          sessions.removeValue(forKey: sessionId)?.dispose()
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(
        FlutterError(
          code: "ios_hdr_player_error",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func requireSession(_ args: [String: Any]) throws -> IosHdrPlayerSession {
    guard let sessionId = intValue(args["sessionId"]) else {
      throw NSError(
        domain: "IosHdrPlayer",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "sessionId is required"]
      )
    }
    guard let session = sessions[sessionId] else {
      throw NSError(
        domain: "IosHdrPlayer",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "session \(sessionId) does not exist"]
      )
    }
    return session
  }
}

private final class IosHdrPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private weak var plugin: IosHdrPlayerPlugin?

  init(plugin: IosHdrPlayerPlugin) {
    self.plugin = plugin
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let arguments = args as? [String: Any]
    let sessionId = intValue(arguments?["sessionId"])
    let session = sessionId.flatMap { plugin?.session(id: $0) }
    return IosHdrPlatformView(frame: frame, session: session)
  }
}

private final class IosHdrPlatformView: NSObject, FlutterPlatformView {
  private let platformView: UIView

  init(frame: CGRect, session: IosHdrPlayerSession?) {
    if let view = session?.view {
      platformView = view
    } else {
      platformView = UIView(frame: frame)
      platformView.backgroundColor = .black
    }
    platformView.frame = frame
    super.init()
  }

  func view() -> UIView {
    platformView
  }
}

private final class IosHdrPlayerContainerView: UIView {
  override static var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }
}

private final class IosHdrPlayerSession {
  let view = IosHdrPlayerContainerView()
  private let player = AVPlayer()
  private var rate: Float = 1.0

  init() {
    view.backgroundColor = .black
    view.playerLayer.player = player
    view.playerLayer.videoGravity = .resizeAspect
    player.isMuted = true
    player.automaticallyWaitsToMinimizeStalling = true
  }

  func open(arguments: [String: Any]) throws {
    guard let videoUrl = arguments["videoUrl"] as? String, !videoUrl.isEmpty else {
      throw NSError(
        domain: "IosHdrPlayer",
        code: -3,
        userInfo: [NSLocalizedDescriptionKey: "videoUrl is required"]
      )
    }

    let isFileSource = arguments["isFileSource"] as? Bool ?? false
    let url: URL?
    if isFileSource {
      url = URL(fileURLWithPath: videoUrl)
    } else {
      url = URL(string: videoUrl)
    }
    guard let mediaUrl = url else {
      throw NSError(
        domain: "IosHdrPlayer",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "invalid videoUrl"]
      )
    }

    let rawHeaders = arguments["headers"] as? [String: Any] ?? [:]
    let headers = rawHeaders.compactMapValues { $0 as? String }
    let asset: AVURLAsset
    if headers.isEmpty {
      asset = AVURLAsset(url: mediaUrl)
    } else {
      asset = AVURLAsset(url: mediaUrl, options: [AVURLAssetHTTPHeaderFieldsKey: headers])
    }
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 5

    setFitMode(arguments["fitMode"] as? String ?? "contain")
    player.replaceCurrentItem(with: item)
    player.isMuted = true

    if let startMs = intValue(arguments["startMs"]), startMs > 0 {
      seekTo(positionMs: startMs)
    }
  }

  func play() {
    player.playImmediately(atRate: rate)
  }

  func pause() {
    player.pause()
  }

  func seekTo(positionMs: Int) {
    let time = CMTime(seconds: Double(max(positionMs, 0)) / 1000.0, preferredTimescale: 1000)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func setPlaybackSpeed(_ speed: Double) {
    rate = Float(max(speed, 0.1))
    if player.timeControlStatus != .paused {
      player.rate = rate
    }
  }

  func setFitMode(_ fitMode: String) {
    switch fitMode {
    case "fill":
      view.playerLayer.videoGravity = .resize
    case "cover", "fitWidth", "fitHeight":
      view.playerLayer.videoGravity = .resizeAspectFill
    default:
      view.playerLayer.videoGravity = .resizeAspect
    }
  }

  func syncTo(positionMs: Int) {
    guard player.currentItem != nil else { return }
    let currentSeconds = player.currentTime().seconds
    guard currentSeconds.isFinite else { return }
    let targetSeconds = Double(max(positionMs, 0)) / 1000.0
    if abs(currentSeconds - targetSeconds) > 0.45 {
      seekTo(positionMs: positionMs)
    }
  }

  func screenshot(result: @escaping FlutterResult) {
    guard let asset = player.currentItem?.asset else {
      result(nil)
      return
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let time = player.currentTime()
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let data = UIImage(cgImage: cgImage).pngData()
        DispatchQueue.main.async {
          if let data = data {
            result(FlutterStandardTypedData(bytes: data))
          } else {
            result(nil)
          }
        }
      } catch {
        DispatchQueue.main.async {
          result(nil)
        }
      }
    }
  }

  func dispose() {
    player.pause()
    player.replaceCurrentItem(with: nil)
    view.playerLayer.player = nil
  }

  static func supportsHdr(qualityCode: Int?) -> Bool {
    let hdrQualityCodes: Set<Int> = [125, 126, 129]
    if let qualityCode = qualityCode, !hdrQualityCodes.contains(qualityCode) {
      return false
    }
    return UIScreen.main.traitCollection.displayGamut == .P3
  }
}
