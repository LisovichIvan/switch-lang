import Foundation

// UI accesses this interface only on the main thread. The implementation owns
// its listener lifetime; the entry point joins the separate processing worker.
// Event callbacks never invoke AppKit controls.
protocol ApplicationRuntime: AnyObject {
  var isListening: Bool { get }
  var replacementFailure: UInt32 { get }
  var onReport: ((UInt32) -> Void)? { get set }
  func begin() -> Bool
  func stop()
  func setHotkey(code: UInt16, modifiers: UInt64, bound: Bool)
  func setPaused(_ paused: Bool)
  func setRecording(_ recording: Bool)
  func setAutomatic(_ automatic: Bool)
  func invalidate()
  func acknowledgeReplacementFailure()
}

// Blocking access is reserved for control/worker code. The event callback must
// use tryWithLock and pass through/invalidate if a snapshot cannot be obtained.
final class SharedValue<Value> {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }

  func tryWithLock<Result>(_ body: (inout Value) -> Result) -> Result? {
    guard lock.try() else { return nil }
    defer { lock.unlock() }
    return body(&value)
  }
}
