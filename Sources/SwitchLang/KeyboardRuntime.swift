import AppKit
import ApplicationServices
import Carbon
import Foundation

private let keyboardRuntimeCallback: CGEventTapCallBack = { proxy, type, event, pointer in
  guard let pointer else { return Unmanaged.passUnretained(event) }
  // SAFETY: the listener thread retains runtime until the tap is invalidated.
  let runtime = Unmanaged<KeyboardRuntime>.fromOpaque(pointer).takeUnretainedValue()
  return runtime.handleEvent(proxy: proxy, type: type, event: event).map {
    Unmanaged.passUnretained($0)
  }
}

private let keyboardSourceCallback: CFNotificationCallback = { _, pointer, name, _, _ in
  guard let pointer, let name else { return }
  // SAFETY: begin/stop register and remove this observer during runtime's life.
  let runtime = Unmanaged<KeyboardRuntime>.fromOpaque(pointer).takeUnretainedValue()
  runtime.inputSourceChanged(name.rawValue)
}

final class KeyboardRuntime: ApplicationRuntime {
  let inputGeneration: AtomicUInt64
  let hotkeyBinding: AtomicUInt64
  let consumedKey: AtomicUInt64
  let capsLockReady: AtomicUInt64
  let paused: AtomicUInt64
  let failure: AtomicUInt64
  let recording: AtomicUInt64
  let listening: AtomicUInt64
  let starting: AtomicUInt64
  let stopping: AtomicUInt64
  let sessionActive: AtomicUInt64
  let sleeping: AtomicUInt64
  let automatic: AtomicUInt64
  let secureInputGuard: AtomicUInt64
  let actionCandidate: AtomicUInt64
  private let pendingReports: AtomicUInt64
  private let reportsQueued: AtomicUInt64
  private let contextObservation = AXObservation()
  private let terminalAnchorCapture = SharedValue<TerminalAnchorCapture?>(nil)
  let coordination = SharedValue(RuntimeCoordination())
  let layoutSnapshot = SharedValue<(layout: Layout?, data: Data?)>((nil, nil))
  private let submitInput: (InputMetadata) -> Bool
  var onReport: ((UInt32) -> Void)?
  private let listenerFinished = DispatchGroup()
  private var listenerThread: Thread?
  private var workspaceObservers: [NSObjectProtocol] = []
  // The fields below belong exclusively to listener, never main/worker.
  var activeTap: CFMachPort?
  var deferredAction = DeferredAction()
  var waitingReplacement: ReplacementJob?
  var suppressedActionKey: UInt32 = 0
  private var actionWakeReady = false
  private var capsController: CapsLockController?
  private var capsConfigurationPending = false
  private var capsResetPending = false
  private var capsConfigurationOutcome: Int32 = -1

  init(submitInput: @escaping (InputMetadata) -> Bool) throws {
    self.submitInput = submitInput
    inputGeneration = try AtomicUInt64()
    hotkeyBinding = try AtomicUInt64()
    consumedKey = try AtomicUInt64()
    capsLockReady = try AtomicUInt64()
    paused = try AtomicUInt64()
    failure = try AtomicUInt64()
    recording = try AtomicUInt64()
    listening = try AtomicUInt64()
    starting = try AtomicUInt64()
    stopping = try AtomicUInt64()
    sessionActive = try AtomicUInt64(1)
    sleeping = try AtomicUInt64()
    automatic = try AtomicUInt64()
    secureInputGuard = try AtomicUInt64()
    actionCandidate = try AtomicUInt64()
    pendingReports = try AtomicUInt64()
    reportsQueued = try AtomicUInt64()
  }

  var isListening: Bool { listening.boolValue }
  var replacementFailure: UInt32 { UInt32(truncatingIfNeeded: failure.value) }
  var automaticEnabled: Bool { automatic.boolValue }
  var onListenerThread: Bool { Thread.current === listenerThread }

  // The Carbon query is explicitly not thread safe. Contention is unsafe,
  // not a reason to spin or block the event callback.
  func secureInputOff() -> Bool {
    guard secureInputGuard.compareExchange(expected: 0, desired: 1) else { return false }
    defer { secureInputGuard.value = 0 }
    return !IsSecureEventInputEnabled()
  }

  // Callback-safe bounded numeric coalescing. UI access happens only on main.
  func report(_ status: UInt32) {
    guard status < 64 else { return }
    pendingReports.fetchOr(UInt64(1) << status)
    if reportsQueued.compareExchange(expected: 0, desired: 1) {
      DispatchQueue.main.async { [weak self] in self?.deliverReports() }
    }
  }

  private func deliverReports() {
    let reports = pendingReports.exchange(0)
    reportsQueued.value = 0
    for status: UInt32 in 0..<64 where reports & (UInt64(1) << status) != 0 { onReport?(status) }
    // A producer racing the exchange either scheduled delivery itself or is
    // covered here. At most one waiting delivery, never one block per key.
    if pendingReports.value != 0 && reportsQueued.compareExchange(expected: 0, desired: 1) {
      DispatchQueue.main.async { [weak self] in self?.deliverReports() }
    }
  }

  func publishActionCandidate(_ generation: UInt64) { actionCandidate.value = generation }
  func finishAction(_ generation: UInt64) {
    requestActionCompletion(generation: generation, pendingOnly: true)
  }
  func acknowledgeReplacementFailure() { failure.value = 0 }

  func setHotkey(code: UInt16, modifiers: UInt64, bound: Bool) {
    let binding = bound ? ((modifiers & bindingModifierMask) << 16) | (UInt64(code) + 1) : 0
    if hotkeyBinding.exchange(binding) != binding { capsLockReady.value = 0 }
    invalidate()
    requestCapsConfiguration()
  }

  func setPaused(_ value: Bool) {
    let value = value || replacementFailure != 0
    if paused.exchange(value ? 1 : 0) != (value ? 1 : 0) { capsLockReady.value = 0 }
    invalidate()
    requestCapsConfiguration()
  }

  func setRecording(_ value: Bool) {
    if recording.exchange(value ? 1 : 0) != (value ? 1 : 0) { capsLockReady.value = 0 }
    invalidate()
    requestCapsConfiguration()
  }

  func setAutomatic(_ value: Bool) {
    automatic.boolValue = value
    invalidate()
  }

  func submitNotification(_ kind: InputKind) {
    _ = submitInput(
      InputMetadata(kind: kind, generation: inputGeneration.value, timestampNS: monotonicNowNS()))
  }

  func invalidate() {
    actionCandidate.value = 0
    inputGeneration.fetchAdd(1)
    submitNotification(.reset)
    requestActionCompletion(generation: 0, pendingOnly: false)
  }

  func performOnListener(_ body: @escaping () -> Void) {
    coordination.withLock { state in
      if let loop = state.loop, !stopping.boolValue {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, body)
        CFRunLoopWakeUp(loop)
      }
    }
  }

  private func requestActionCompletion(generation: UInt64, pendingOnly: Bool) {
    let invalidation = inputGeneration.value
    let completion = { [self] in
      let matches =
        generation == 0
        ? deferredAction.generation < invalidation : deferredAction.generation == generation
      if matches && (!pendingOnly || deferredAction.phase == .pending) { readyDeferredAction() }
    }
    if onListenerThread { completion() } else { performOnListener(completion) }
  }

  func createActionWake() -> CGEvent? {
    guard let wake = CGEvent(source: nil) else { return nil }
    wake.type = .null
    wake.setIntegerValueField(.eventSourceUserData, value: actionWakeTag)
    return wake
  }

  func readyDeferredAction() {
    guard deferredAction.markReady() else { return }
    // Event-driven wake with one-shot fallback; never a polling timer.
    let fallback = CFRunLoopTimerCreateWithHandler(
      kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.01, 0, 0, 0
    ) { [weak self] timer in
      guard let self, let timer, self.deferredAction.timer.map({ CFEqual($0, timer) }) == true
      else { return }
      self.actionExpired()
    }
    if let fallback {
      if let old = deferredAction.timer { CFRunLoopTimerInvalidate(old) }
      deferredAction.timer = fallback
      CFRunLoopAddTimer(CFRunLoopGetCurrent(), fallback, .commonModes)
    }
    invalidate()
    if let wake = deferredAction.wake { wake.post(tap: .cgSessionEventTap) }
    if fallback == nil { flushDeferredAction(proxy: nil) }
  }

  func flushDeferredAction(proxy: CGEventTapProxy?) {
    // Destructive phases must only be resolved by the executor, not timeout,
    // tap loss or unrelated invalidation.
    guard deferredAction.phase == .pending || deferredAction.phase == .ready else { return }
    guard let saved = deferredAction.take() else { return }
    if let proxy { saved.tapPostEvent(proxy) } else { saved.post(tap: .cgAnnotatedSessionEventTap) }
  }

  private func actionExpired() {
    if deferredAction.phase == .ready {
      flushDeferredAction(proxy: nil)
    } else {
      readyDeferredAction()
    }
  }

  private func probeActionReplay() {
    actionWakeReady = false
    if let wake = createActionWake() { wake.post(tap: .cgSessionEventTap) }
    if let timer = CFRunLoopTimerCreateWithHandler(
      kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.1, 0, 0, 0,
      { [weak self] _ in
        if let self, !self.actionWakeReady { self.report(5) }
      })
    {
      CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    } else {
      report(5)
    }
  }

  private func deferAction(_ event: CGEvent, input: inout InputMetadata) -> Bool {
    guard let saved = event.copy(), let wake = createActionWake() else { return false }
    let now = monotonicNowNS()
    guard now != 0,
      let timer = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.1,
        0, 0, 0,
        { [weak self] timer in
          guard let self, let timer, self.deferredAction.timer.map({ CFEqual($0, timer) }) == true
          else { return }
          self.actionExpired()
        })
    else { return false }
    deferredAction = DeferredAction(
      phase: .pending, generation: input.generation,
      deadline: now &+ actionBudgetNS, keyDown: saved, wake: wake, timer: timer)
    input.kind = .action
    guard submitInput(input) else {
      _ = deferredAction.take()
      return false
    }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    return true
  }

  var capsHotkeyAssigned: Bool { hotkeyBinding.value == 58 }
  var capsHotkeyActive: Bool {
    capsHotkeyAssigned && isListening && !stopping.boolValue && !paused.boolValue
      && replacementFailure == 0 && !recording.boolValue && sessionActive.boolValue
      && !sleeping.boolValue
  }

  private func closeCapsController() {
    capsLockReady.value = 0
    capsController = nil
  }

  private func capsControlFailed() {
    closeCapsController()
    paused.boolValue = true
    invalidate()
    report(7)
  }

  private func configurationOutcome(_ detail: Int32) {
    guard DiagnosticLogger.shared.isEnabled else {
      capsConfigurationOutcome = -1
      return
    }
    guard capsConfigurationOutcome != detail else { return }
    capsConfigurationOutcome = detail
    DiagnosticLogger.shared.record(
      detail == 0 ? .capsConfigurationReady : .capsConfigurationBlocked, detail)
  }

  private func configureCapsHotkey() {
    guard capsHotkeyActive else {
      configurationOutcome(RuntimeReason.capsInactive.rawValue)
      closeCapsController()
      return
    }
    guard secureInputOff() else {
      configurationOutcome(RuntimeReason.secureInputUnsafe.rawValue)
      closeCapsController()
      return
    }
    guard AXIsProcessTrusted() else {
      configurationOutcome(RuntimeReason.notTrusted.rawValue)
      closeCapsController()
      return
    }
    if capsLockReady.boolValue {
      configurationOutcome(0)
      return
    }
    if capsController == nil { capsController = CapsLockController() }
    guard let reset = capsController?.reset(), reset.success else {
      DiagnosticLogger.shared.record(.capsResetFailed, 1)
      capsControlFailed()
      return
    }
    DiagnosticLogger.shared.record(reset.wasLocked ? .capsResetVerified : .capsNoTransition, 1)
    capsLockReady.boolValue = true
    configurationOutcome(0)
    report(8)
  }

  private func queueCapsConfiguration() {
    guard !capsConfigurationPending else { return }
    capsConfigurationPending = true
    CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue) { [self] in
      capsConfigurationPending = false
      configureCapsHotkey()
    }
    CFRunLoopWakeUp(CFRunLoopGetCurrent())
  }

  func requestCapsConfiguration() {
    if onListenerThread {
      queueCapsConfiguration()
    } else {
      performOnListener { [self] in queueCapsConfiguration() }
    }
  }

  private func queueCapsCommand(_ event: CGEvent) {
    guard !capsResetPending else {
      DiagnosticLogger.shared.record(.capsResetCoalesced, 0)
      return
    }
    capsResetPending = true
    DiagnosticLogger.shared.record(.capsResetQueued, 0)
    let input = InputMetadata(
      kind: .hotkey, keycode: 57,
      flags: event.flags.rawValue
        & (bindingModifierMask | CGEventFlags.maskSecondaryFn.rawValue
          | CGEventFlags.maskHelp.rawValue),
      generation: inputGeneration.value, timestampNS: monotonicNowNS())
    CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue) { [self] in
      capsResetPending = false
      guard runtimeCondition(capsHotkeyActive, .capsBlocked, .capsInactive),
        runtimeCondition(capsLockReady.boolValue, .capsBlocked, .capsNotReady),
        runtimeCondition(secureInputOff(), .capsBlocked, .secureInputUnsafe),
        runtimeCondition(AXIsProcessTrusted(), .capsBlocked, .notTrusted)
      else { return }
      guard let reset = capsController?.reset(), reset.success else {
        DiagnosticLogger.shared.record(.capsResetFailed, 2)
        capsControlFailed()
        return
      }
      guard reset.wasLocked else {
        DiagnosticLogger.shared.record(.capsNoTransition, 2)
        return
      }
      DiagnosticLogger.shared.record(.capsResetVerified, 2)
      guard input.flags == 0 else {
        DiagnosticLogger.shared.record(.capsModifiersRejected, 0)
        return
      }
      guard inputGeneration.value == input.generation else {
        DiagnosticLogger.shared.record(.capsGenerationChanged, 0)
        return
      }
      guard runtimeCondition(capsHotkeyActive, .capsBlocked, .capsInactive),
        runtimeCondition(secureInputOff(), .capsBlocked, .secureInputUnsafe)
      else { return }
      guard
        inputGeneration.compareExchange(expected: input.generation, desired: input.generation &+ 1)
      else {
        DiagnosticLogger.shared.record(.capsGenerationChanged, 0)
        return
      }
      var command = input
      command.generation &+= 1
      if submitInput(command) {
        DiagnosticLogger.shared.record(.capsCommandQueued, 0)
      } else {
        DiagnosticLogger.shared.record(.capsCommandQueueFull, 0)
        invalidate()
      }
    }
    CFRunLoopWakeUp(CFRunLoopGetCurrent())
  }

  func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> CGEvent? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      listening.boolValue = false
      capsLockReady.boolValue = false
      invalidate()
      report(3)
      flushDeferredAction(proxy: nil)
      return event
    }
    let tag = event.getIntegerValueField(.eventSourceUserData)
    if type == .null && tag == actionWakeTag {
      if !actionWakeReady { report(6) }
      actionWakeReady = true
      if deferredAction.phase == .ready { flushDeferredAction(proxy: proxy) }
      return nil
    }
    if tag == KeyboardEventPlan.eventTag || type == .null { return event }
    let keycode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if suppressActionEvent(
      pending: &suppressedActionKey, type: type, keycode: keycode, repeated: repeated)
    {
      return nil
    }
    let preparationRelease = replacementRelease(type: type, event: event)
    if deferredAction.phase != .idle && !preparationRelease {
      readyDeferredAction()
      flushDeferredAction(proxy: proxy)
    }
    let observedCaps =
      keycode == 57 && (type == .flagsChanged || type == .keyDown) && capsHotkeyAssigned
    if observedCaps {
      DiagnosticLogger.shared.record(
        event.flags.contains(.maskAlphaShift) ? .capsObservedOn : .capsObservedOff, 0)
    }
    if type == .keyUp {
      if capsHotkeyActive && capsLockReady.boolValue && secureInputOff() {
        if keycode == 57 { return nil }
        CapsLockController.normalize(event)
      }
      if consumedKey.value == UInt64(keycode) + 1 {
        consumedKey.value = 0
        return nil
      }
      return event
    }
    for (blocked, reason) in [
      (paused.boolValue || replacementFailure != 0, RuntimeReason.paused),
      (recording.boolValue, .recording), (!sessionActive.boolValue, .inactiveSession),
      (sleeping.boolValue, .sleeping),
    ] {
      if blocked {
        if observedCaps { DiagnosticLogger.shared.record(.capsBlocked, reason.rawValue) }
        return event
      }
    }
    guard secureInputOff() else {
      if observedCaps {
        DiagnosticLogger.shared.record(.capsBlocked, RuntimeReason.secureInputUnsafe.rawValue)
      }
      capsLockReady.value = 0
      invalidate()
      return event
    }
    if capsHotkeyAssigned {
      if !capsLockReady.boolValue {
        if observedCaps {
          DiagnosticLogger.shared.record(.capsBlocked, RuntimeReason.capsNotReady.rawValue)
        }
        queueCapsConfiguration()
      }
      if keycode == 57 && (type == .flagsChanged || type == .keyDown) {
        if capsLockReady.boolValue && event.flags.contains(.maskAlphaShift) {
          queueCapsCommand(event)
        }
        return nil
      }
      if capsLockReady.boolValue { CapsLockController.normalize(event) }
    }
    if type == .flagsChanged { return event }
    let generation = inputGeneration.fetchAdd(1) &+ 1
    guard type == .keyDown else {
      submitNotification(.reset)
      return event
    }
    let flags = event.flags.rawValue
    let binding = hotkeyBinding.value
    let hotkey =
      binding != 0 && binding & 0xffff == UInt64(keycode) + 1
      && binding >> 16 == flags & bindingModifierMask
    if hotkey && repeated { return consumedKey.value == UInt64(keycode) + 1 ? nil : event }
    var input = InputMetadata(
      kind: hotkey ? .hotkey : .key, keycode: keycode,
      keyboardType: UInt16(
        truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeyboardType)), flags: flags,
      generation: generation, timestampNS: monotonicNowNS())
    if actionWakeReady
      && actionEligible(
        keycode: keycode, flags: flags, automatic: automaticEnabled,
        hotkey: hotkey, repeated: repeated, candidate: actionCandidate.value, generation: generation
      ) && deferAction(event, input: &input)
    {
      return nil
    }
    // The failed deferred submission must not mislabel a passed-through action.
    input.kind = hotkey ? .hotkey : .key
    if submitInput(input) && hotkey {
      consumedKey.value = UInt64(keycode) + 1
      return nil
    }
    return event
  }

  func refreshLayoutSnapshot() {
    let snapshot = KeyboardLayouts.currentSnapshot()
    layoutSnapshot.withLock { $0 = snapshot }
  }

  func inputSourceChanged(_ name: CFString) {
    var ownChange = false
    if Thread.isMainThread && CFEqual(name, kTISNotifySelectedKeyboardInputSourceChanged) {
      let snapshot = coordination.withLock { $0.job?.snapshot }
      if let snapshot {
        ownChange = replacementAcceptsLayoutNotification(snapshot) {
          let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
          return KeyboardLayouts.sourceLayout(current)
        }
      }
    }
    if !ownChange { invalidate() }
    DispatchQueue.main.async { [weak self] in self?.refreshLayoutSnapshot() }
  }

  func observeContext(processIdentifier: pid_t, element: AXUIElement) {
    contextObservation.request(
      AXObservationTarget(processIdentifier: processIdentifier, element: element) {
        [weak self] element, name in self?.handleAXNotification(element: element, name: name)
      })
  }

  func clearContextObservation() { contextObservation.request(nil) }

  func armTerminalAnchor(element: AXUIElement, generation: UInt64) {
    guard inputGeneration.value == generation else { return }
    terminalAnchorCapture.withLock { capture in
      guard inputGeneration.value == generation else { return }
      if let capture, capture.generation == generation, CFEqual(capture.element, element) { return }
      capture = TerminalAnchorCapture(element: element, generation: generation)
    }
  }

  func discardTerminalAnchor() { terminalAnchorCapture.withLock { $0 = nil } }

  func takeTerminalAnchor(
    for input: InputMetadata, processedGeneration: UInt64
  ) -> TerminalPreInputSnapshot? {
    guard input.kind == .key || input.kind == .hotkey || input.kind == .action else { return nil }
    return terminalAnchorCapture.withLock { capture in
      defer { capture = nil }
      guard let captured = capture, let anchor = captured.anchor,
        anchor.precedes(input, processedGeneration: processedGeneration)
      else { return nil }
      return TerminalPreInputSnapshot(element: captured.element, anchor: anchor)
    }
  }

  private func captureTerminalAnchor(element: AXUIElement) {
    precondition(Thread.isMainThread)
    guard let request = terminalAnchorCapture.withLock({ $0 }),
      request.generation == inputGeneration.value, CFEqual(request.element, element)
    else { return }
    var value: CFTypeRef?
    guard readAXMetadata(.selectedTextRange, from: element, value: &value) == .success,
      let value, CFGetTypeID(value) == AXValueGetTypeID()
    else { return }
    // SAFETY: validated AXValue dynamic type and range payload; no text read.
    let rangeValue = unsafeBitCast(value, to: AXValue.self)
    var range = CFRange(location: -1, length: -1)
    guard AXValueGetType(rangeValue) == .cfRange,
      AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0, range.length == 0,
      inputGeneration.value == request.generation
    else { return }
    let finishedNS = monotonicNowNS()
    terminalAnchorCapture.withLock { capture in
      guard var current = capture, current.generation == request.generation,
        CFEqual(current.element, element), inputGeneration.value == request.generation
      else { return }
      current.anchor = TerminalPreInputAnchor(
        caret: range.location, generation: request.generation, finishedNS: finishedNS)
      capture = current
    }
  }

  func handleAXNotification(element: AXUIElement, name: CFString) {
    if CFEqual(name, kAXFocusedUIElementChangedNotification as CFString)
      || CFEqual(name, kAXFocusedWindowChangedNotification as CFString)
      || CFEqual(name, kAXUIElementDestroyedNotification as CFString)
    {
      capsLockReady.value = 0
      invalidate()
      requestCapsConfiguration()
    } else {
      // Only armed after a cleared tracker, and only until the next input
      // generation. One caret read on main, never AX work on the event tap.
      captureTerminalAnchor(element: element)
      let replacement = coordination.withLock { state -> ReplacementSnapshot? in
        guard let job = state.job, job.snapshot.phase.value >= ReplacementPhase.deleting.rawValue,
          job.snapshot.phase.value < ReplacementPhase.completed.rawValue,
          let expected = job.expectedElement, CFEqual(expected, element)
        else { return nil }
        return job.snapshot
      }
      if let replacement {
        replacement.signalContext()
      } else {
        submitNotification(.contextChanged)
      }
    }
  }

  private func installWorkspaceObservers() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.sessionDidResignActiveNotification,
      NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.willSleepNotification,
      NSWorkspace.didWakeNotification,
    ] {
      workspaceObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
          guard let self else { return }
          switch notification.name {
          case NSWorkspace.sessionDidResignActiveNotification: self.sessionActive.boolValue = false
          case NSWorkspace.sessionDidBecomeActiveNotification: self.sessionActive.boolValue = true
          case NSWorkspace.willSleepNotification: self.sleeping.boolValue = true
          case NSWorkspace.didWakeNotification: self.sleeping.boolValue = false
          default: break
          }
          self.capsLockReady.value = 0
          self.invalidate()
          self.requestCapsConfiguration()
        })
    }
    let centerCF = CFNotificationCenterGetDistributedCenter()
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      centerCF, pointer, keyboardSourceCallback, kTISNotifySelectedKeyboardInputSourceChanged,
      nil, .deliverImmediately)
    CFNotificationCenterAddObserver(
      centerCF, pointer, keyboardSourceCallback, kTISNotifyEnabledKeyboardInputSourcesChanged,
      nil, .deliverImmediately)
  }

  func begin() -> Bool {
    guard Thread.isMainThread, AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
      return false
    }
    if stopping.boolValue && starting.boolValue { return false }
    contextObservation.start()
    refreshLayoutSnapshot()
    if let retry = coordination.withLock({ state -> Bool? in
      guard let tap = state.tap else { return nil }
      CGEvent.tapEnable(tap: tap, enable: true)
      let enabled = CGEvent.tapIsEnabled(tap: tap)
      listening.boolValue = enabled
      if enabled, let loop = state.loop {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
          capsLockReady.value = 0
          configureCapsHotkey()
          probeActionReplay()
        }
        CFRunLoopWakeUp(loop)
      }
      return enabled
    }) {
      return retry
    }
    if starting.exchange(1) != 0 { return true }
    stopping.value = 0
    if workspaceObservers.isEmpty { installWorkspaceObservers() }
    listenerFinished.enter()
    let thread = Thread { [self] in listenerMain() }
    thread.name = "switch-lang-listener"
    listenerThread = thread
    thread.start()
    return true
  }

  private func listenerMain() {
    autoreleasepool {
      defer {
        starting.value = 0
        listenerFinished.leave()
      }
      let types: [CGEventType] = [
        .null, .flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .scrollWheel,
      ]
      let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
      guard
        let tap = CGEvent.tapCreate(
          tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
          eventsOfInterest: mask, callback: keyboardRuntimeCallback,
          userInfo: Unmanaged.passUnretained(self).toOpaque()),
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
      else {
        report(3)
        return
      }
      let loop = CFRunLoopGetCurrent()
      activeTap = tap
      coordination.withLock {
        $0.tap = tap
        $0.loop = loop
      }
      CFRunLoopAddSource(loop, source, .commonModes)
      listening.value = 1
      configureCapsHotkey()
      submitNotification(.contextChanged)
      probeActionReplay()
      if !stopping.boolValue { CFRunLoopRun() }
      listening.value = 0
      let unfinished = coordination.withLock { state -> ReplacementJob? in
        state.tap = nil
        state.loop = nil
        return state.job
      }
      if let unfinished { finishReplacement(unfinished) }
      flushDeferredAction(proxy: nil)
      closeCapsController()
      capsConfigurationPending = false
      capsResetPending = false
      CFMachPortInvalidate(tap)
      CFRunLoopRemoveSource(loop, source, .commonModes)
      activeTap = nil
    }
  }

  func stop() {
    discardTerminalAnchor()
    contextObservation.stop()
    stopping.boolValue = true
    listening.boolValue = false
    invalidate()
    coordination.withLock { state in
      state.outstandingRequest?.cancel()
      if let job = state.job {
        job.snapshot.cancelled.boolValue = true
        job.mainRequest?.cancel()
        job.snapshot.signalContext()
      }
      if let loop = state.loop {
        CFRunLoopStop(loop)
        CFRunLoopWakeUp(loop)
      }
    }
    let center = NSWorkspace.shared.notificationCenter
    for observer in workspaceObservers { center.removeObserver(observer) }
    workspaceObservers.removeAll()
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDistributedCenter(), pointer,
      CFNotificationName(kTISNotifySelectedKeyboardInputSourceChanged), nil)
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDistributedCenter(), pointer,
      CFNotificationName(kTISNotifyEnabledKeyboardInputSourcesChanged), nil)
    layoutSnapshot.withLock { $0 = (nil, nil) }
  }

  func waitUntilStopped() { listenerFinished.wait() }
}
