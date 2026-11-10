import CoreGraphics
import IOKit
import IOKit.hidsystem

// Listener-thread resource, never opened or reset from the event callback.
// No remapping, seizure, persistent preferences or synthetic keyboard events.
final class CapsLockController {
  private let read: () -> Bool?
  private let set: () -> Bool
  private let close: () -> Void

  init?() {
    // MACH_PORT_NULL selects the default IOKit main port on macOS 11 too.
    let service = IOServiceGetMatchingService(mach_port_t(0), IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var connection: io_connect_t = 0
    let result = IOServiceOpen(
      service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection)
    DiagnosticLogger.shared.record(.capsControllerOpen, result)
    guard result == KERN_SUCCESS, connection != 0 else {
      if connection != 0 { IOServiceClose(connection) }
      return nil
    }
    read = {
      var locked = false
      let result = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &locked)
      DiagnosticLogger.shared.record(.capsRead, result)
      return result == KERN_SUCCESS ? locked : nil
    }
    set = {
      let result = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false)
      DiagnosticLogger.shared.record(.capsClear, result)
      return result == KERN_SUCCESS
    }
    close = { IOServiceClose(connection) }
  }

  // The injected variant does not discover/open IOKit, even transiently.
  // The owner supplies the same read/clear/close lifecycle for pure tests.
  init(read: @escaping () -> Bool?, set: @escaping () -> Bool, close: @escaping () -> Void) {
    self.read = read
    self.set = set
    self.close = close
  }

  deinit { close() }

  // One read, at most one clear, then one verification. No retries and no
  // eligible command unless the observed on -> off transition is confirmed.
  func reset() -> (success: Bool, wasLocked: Bool) {
    guard let locked = read() else { return (false, false) }
    guard locked else { return (true, false) }
    guard set(), let verified = read(), !verified else { return (false, false) }
    return (true, true)
  }

  static func normalize(_ event: CGEvent) {
    event.flags.remove(.maskAlphaShift)
  }
}
