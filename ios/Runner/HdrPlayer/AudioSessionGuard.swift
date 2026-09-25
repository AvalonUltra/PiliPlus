import AVFoundation
import ObjectiveC

/// Keeps the process-wide AVAudioSession active while an AVPlayer session
/// intends to play.
///
/// Several components deactivate the shared session on their own schedule:
/// libmpv's audiounit output on teardown (media_kit destroys the mpv core on a
/// delayed timer after `dispose()`), flutter_volume_controller when its
/// listener is cancelled, and the audio_session plugin from a background
/// queue. Deactivating a session with running I/O silences AVPlayer, which
/// keeps rendering video but never restarts audio — the "picture continues,
/// sound gone" failure after a quality switch rebuilt the backend. While a
/// session holds the guard those deactivations are dropped; activations and
/// category changes pass through untouched.
enum AudioSessionGuard {
    private static let lock = NSLock()
    private static var holders = Set<ObjectIdentifier>()
    private static var installed = false

    private typealias SetActiveImp =
        @convention(c) (AnyObject, Selector, ObjCBool, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool
    private typealias SetActiveOptionsImp =
        @convention(c) (AnyObject, Selector, ObjCBool, UInt, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool

    static func hold(_ owner: AnyObject) {
        lock.lock()
        holders.insert(ObjectIdentifier(owner))
        lock.unlock()
    }

    static func release(_ owner: AnyObject) {
        lock.lock()
        holders.remove(ObjectIdentifier(owner))
        lock.unlock()
    }

    private static var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !holders.isEmpty
    }

    /// Installs the interception once. Must run before any media backend is
    /// created (plugin registration at launch).
    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        let cls: AnyClass = AVAudioSession.self

        let sel = NSSelectorFromString("setActive:error:")
        if let method = class_getInstanceMethod(cls, sel) {
            let original = unsafeBitCast(method_getImplementation(method), to: SetActiveImp.self)
            let block: @convention(block) (AnyObject, ObjCBool, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool = {
                session, active, error in
                if !active.boolValue, isHeld {
                    NSLog("[HdrPlayer] ignored audio session deactivation during playback")
                    return true
                }
                return original(session, sel, active, error)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        let optSel = NSSelectorFromString("setActive:withOptions:error:")
        if let method = class_getInstanceMethod(cls, optSel) {
            let original = unsafeBitCast(method_getImplementation(method), to: SetActiveOptionsImp.self)
            let block: @convention(block) (AnyObject, ObjCBool, UInt, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool = {
                session, active, options, error in
                if !active.boolValue, isHeld {
                    NSLog("[HdrPlayer] ignored audio session deactivation during playback")
                    return true
                }
                return original(session, optSel, active, options, error)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}
