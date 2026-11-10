import AppKit
import ApplicationServices

private let originalTestTag: Int64 = 0x5357_4C54_4553_5431
let deliveredTestTag: Int64 = 0x5357_4C54_4553_5432

private let addressedInputCallback: CGEventTapCallBack = { _, type, event, pointer in
  guard let pointer else { return Unmanaged.passUnretained(event) }
  let adapter = Unmanaged<ScopedInputAdapter>.fromOpaque(pointer).takeUnretainedValue()
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    adapter.reportFailure()
    return Unmanaged.passUnretained(event)
  }
  guard event.getIntegerValueField(.eventSourceUserData) == originalTestTag else {
    return Unmanaged.passUnretained(event)
  }
  guard adapter.scopedOriginalEvents.fetchAdd(1) < 256 else {
    adapter.reportFailure()
    return nil
  }
  adapter.enqueue(type: type, event: event)
  return nil
}

private let addressedReplayCallback: CGEventTapCallBack = { _, type, event, pointer in
  guard let pointer else { return Unmanaged.passUnretained(event) }
  let adapter = Unmanaged<ScopedInputAdapter>.fromOpaque(pointer).takeUnretainedValue()
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    adapter.reportFailure()
    return Unmanaged.passUnretained(event)
  }
  let tag = event.getIntegerValueField(.eventSourceUserData)
  if tag == originalTestTag || tag == deliveredTestTag {
    // An already addressed event must not be recursively re-posted if it
    // also traverses an annotated-session tap.
    if event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(adapter.fixturePID) {
      return Unmanaged.passUnretained(event)
    }
    adapter.routedEvents.fetchAdd(1)
    event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(adapter.fixturePID))
    event.postToPid(adapter.fixturePID)
    return nil
  }
  return Unmanaged.passUnretained(event)
}

// This independent run loop keeps backend delivery and replay routing alive
// while the production listener is synchronously verifying AX, and during its
// shutdown. It never waits for the listener from either event callback.
final class ScopedInputAdapter {
  let fixturePID: pid_t
  let consumedHotkeys: AtomicUInt64
  let scopedOriginalEvents: AtomicUInt64
  let enqueuedEvents: AtomicUInt64
  let handledEvents: AtomicUInt64
  let routedEvents: AtomicUInt64
  private let runtime: KeyboardRuntime
  private let listenerLoop: CFRunLoop
  private let deliverySource: CGEventSource
  private let pending: AtomicUInt64
  private let stopping: AtomicUInt64
  private let failureReported: AtomicUInt64
  private let loop = SharedValue<CFRunLoop?>(nil)
  private let finished = DispatchGroup()
  private let onError: () -> Void
  private var thread: Thread?

  init(runtime: KeyboardRuntime, fixturePID: pid_t, onError: @escaping () -> Void) throws {
    self.runtime = runtime
    guard let listenerLoop = runtime.coordination.withLock({ $0.loop }) else {
      throw RuntimeFailure(stage: "diagnostic listener unavailable", detail: 0)
    }
    self.listenerLoop = listenerLoop
    guard let deliverySource = CGEventSource(stateID: .privateState) else {
      throw RuntimeFailure(stage: "diagnostic delivery source unavailable", detail: 0)
    }
    deliverySource.userData = deliveredTestTag
    deliverySource.localEventsSuppressionInterval = 0
    self.deliverySource = deliverySource
    self.fixturePID = fixturePID
    self.onError = onError
    consumedHotkeys = try AtomicUInt64()
    scopedOriginalEvents = try AtomicUInt64()
    enqueuedEvents = try AtomicUInt64()
    handledEvents = try AtomicUInt64()
    routedEvents = try AtomicUInt64()
    pending = try AtomicUInt64()
    stopping = try AtomicUInt64()
    failureReported = try AtomicUInt64()
  }

  func start(ready: @escaping (Bool) -> Void) {
    finished.enter()
    let thread = Thread { [self] in
      defer { finished.leave() }
      autoreleasepool {
        let mask =
          CGEventMask(1 << CGEventType.keyDown.rawValue)
          | CGEventMask(1 << CGEventType.keyUp.rawValue)
          | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var installed: [(CFMachPort, CFRunLoopSource)] = []
        let current = CFRunLoopGetCurrent()
        defer {
          for (tap, source) in installed {
            CFMachPortInvalidate(tap)
            CFRunLoopRemoveSource(current, source, .commonModes)
          }
          loop.withLock { $0 = nil }
        }
        for scoped in [true, false] {
          let tap =
            scoped
            ? CGEvent.tapCreateForPid(
              pid: fixturePID, place: .headInsertEventTap, options: .defaultTap,
              eventsOfInterest: mask, callback: addressedInputCallback, userInfo: pointer)
            : CGEvent.tapCreate(
              tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
              eventsOfInterest: mask, callback: addressedReplayCallback, userInfo: pointer)
          guard let tap else {
            DispatchQueue.main.async { ready(false) }
            return
          }
          guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            DispatchQueue.main.async { ready(false) }
            return
          }
          installed.append((tap, source))
          CFRunLoopAddSource(current, source, .commonModes)
        }
        loop.withLock { $0 = current }
        DispatchQueue.main.async { ready(true) }
        if !stopping.boolValue { CFRunLoopRun() }
      }
    }
    thread.name = "switch-lang-test-routing"
    self.thread = thread
    thread.start()
  }

  fileprivate func reportFailure() {
    if failureReported.compareExchange(expected: 0, desired: 1) {
      DispatchQueue.main.async { [self] in onError() }
    }
  }

  fileprivate func enqueue(type: CGEventType, event: CGEvent) {
    guard !stopping.boolValue else { return }
    let previous = pending.fetchAdd(1)
    guard previous < 4, let copy = event.copy() else {
      pending.fetchAdd(UInt64.max)
      reportFailure()
      return
    }
    enqueuedEvents.fetchAdd(1)
    CFRunLoopPerformBlock(listenerLoop, CFRunLoopMode.commonModes.rawValue) { [self, copy] in
      defer { pending.fetchAdd(UInt64.max) }
      guard !stopping.boolValue else { return }
      // Use a pre-tagged source. Do not rely on re-tagging a copied CGEvent:
      // an offline check on this host showed its original userData persisted.
      let keycode = UInt16(truncatingIfNeeded: copy.getIntegerValueField(.keyboardEventKeycode))
      guard
        let delivered = CGEvent(
          keyboardEventSource: deliverySource, virtualKey: keycode, keyDown: type != .keyUp)
      else {
        reportFailure()
        return
      }
      delivered.type = type
      delivered.flags = copy.flags
      delivered.timestamp = copy.timestamp
      delivered.setIntegerValueField(
        .keyboardEventKeyboardType, value: copy.getIntegerValueField(.keyboardEventKeyboardType))
      delivered.setIntegerValueField(
        .keyboardEventAutorepeat, value: copy.getIntegerValueField(.keyboardEventAutorepeat))
      delivered.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(fixturePID))
      guard delivered.getIntegerValueField(.eventSourceUserData) == deliveredTestTag else {
        reportFailure()
        return
      }
      // Only the diagnostic COPY of the handler's proxy parameter is optional.
      // Its body is byte-for-byte unchanged. No callback proxy escapes a callback.
      let output = runtime.handleEvent(proxy: nil, type: type, event: delivered)
      handledEvents.fetchAdd(1)
      if output == nil, type == .keyDown, keycode == 97 {
        consumedHotkeys.fetchAdd(1)
      }
      if !stopping.boolValue, let output { output.postToPid(fixturePID) }
    }
    CFRunLoopWakeUp(listenerLoop)
  }

  func stopAcceptingInput() { stopping.boolValue = true }

  func stopAndWait() {
    stopping.boolValue = true
    loop.withLock { current in
      if let current {
        CFRunLoopStop(current)
        CFRunLoopWakeUp(current)
      }
    }
    finished.wait()
    thread = nil
  }
}
