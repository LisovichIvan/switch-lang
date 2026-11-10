import ApplicationServices
import Carbon
import Foundation

extension KeyboardRuntime {
  func replacementLive(_ snapshot: ReplacementSnapshot) -> Bool {
    !snapshot.cancelled.boolValue && !stopping.boolValue && isListening && !paused.boolValue
      && replacementFailure == 0 && !recording.boolValue && sessionActive.boolValue
      && !sleeping.boolValue && inputGeneration.value == snapshot.generation
  }

  func actionTapEnabled() -> Bool {
    guard isListening, !stopping.boolValue, let activeTap else { return false }
    return CGEvent.tapIsEnabled(tap: activeTap)
  }

  func modifiersReleased() -> Bool {
    CGEventSource.flagsState(.hidSystemState).rawValue & replacementModifierMask == 0
      && consumedKey.value == 0
  }

  // This main queue block captures ONLY a bounded snapshot and requests.
  // In particular it never captures job, context, a worker or a callback proxy.
  private func requestLayout(_ job: ReplacementJob, selectTarget: Bool) -> Bool {
    let request: MainLayoutRequest
    do { request = try MainLayoutRequest() } catch {
      DiagnosticLogger.shared.record(.replacementRefused, RuntimeReason.allocationFailed.rawValue)
      return false
    }
    let snapshot = job.snapshot
    guard let source = job.source else { return false }
    let prepared = selectTarget ? job.preparation : nil
    let accepted = coordination.withLock { state -> Bool in
      guard replacementLive(snapshot), state.outstandingRequest == nil else { return false }
      state.outstandingRequest = request
      job.mainRequest = request
      return true
    }
    guard accepted else { return false }
    DispatchQueue.main.async { [self, snapshot, request, prepared, source] in
      let began = request.begin()
      var success =
        began && replacementLive(snapshot) && secureInputOff() && AXIsProcessTrusted()
        && CGPreflightPostEventAccess()
      if success {
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        success = KeyboardLayouts.sourceLayout(current) == source
      }
      if success && !selectTarget {
        request.targetSource = KeyboardLayouts.copyTargetSource(snapshot.target)
        var planResult = KeyboardPlanError.unsupported.rawValue
        if let target = request.targetSource,
          let pointer = TISGetInputSourceProperty(target, kTISPropertyUnicodeKeyLayoutData)
        {
          // SAFETY: TIS property is retained by target for this scope;
          // verify its CF type before copying to independent Data.
          let object = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
          if CFGetTypeID(object) == CFDataGetTypeID() {
            let data = unsafeBitCast(object, to: CFData.self)
            let count = CFDataGetLength(data)
            if count > 0, let bytes = CFDataGetBytePtr(data) {
              do {
                request.plan = try KeyboardEventPlan(
                  original: snapshot.original, replacement: snapshot.replacement,
                  layoutData: Data(bytes: bytes, count: count), keyboardType: UInt32(LMGetKbdType())
                )
                planResult = 0
              } catch let error as KeyboardPlanError { planResult = error.rawValue } catch {
                planResult = KeyboardPlanError.allocation.rawValue
              }
            }
          }
        }
        success = request.plan != nil
        DiagnosticLogger.shared.record(.replacementKeyboardPlan, planResult)
      } else if success, let target = prepared?.targetSource {
        success = replacementLive(snapshot)
        if success {
          snapshot.expectsLayoutChange.boolValue = true
          let status = TISSelectInputSource(target)
          if status != noErr { DiagnosticLogger.shared.record(.replacementLayoutSwitch, status) }
          success = status == noErr
          let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
          success =
            success
            && runtimeCondition(
              KeyboardLayouts.sourceLayout(current) == snapshot.target,
              .replacementLayoutSwitch, .layoutUnconfirmed)
          refreshLayoutSnapshot()
          if success { DiagnosticLogger.shared.record(.replacementLayoutSwitch, 0) }
        }
      } else {
        success = false
      }
      // ACK means this block has finished all side effects. Cancellation
      // alone never releases the single outstanding slot.
      coordination.withLock { state in
        if state.outstandingRequest === request { state.outstandingRequest = nil }
      }
      if began { request.complete(success: success) }
    }
    let delivered =
      request.done.wait(timeout: .now() + .nanoseconds(Int(actionBudgetNS))) == .success
    if !delivered {
      snapshot.cancelled.boolValue = true
      request.cancel()
    }
    coordination.withLock { _ in job.mainRequest = nil }
    let success =
      delivered && request.phase.value == MainRequestPhase.completed.rawValue && request.success
    if success && !selectTarget { job.preparation = request }
    return runtimeCondition(success, .replacementRefused, .mainUnavailable)
  }

  private func postKeyboardRange(_ job: ReplacementJob, begin: Int, end: Int) -> Bool {
    guard let plan = job.preparation?.plan else { return false }
    return emitKeyboardRange(
      plan, begin: begin, end: end,
      post: { event in
        job.result = 3  // Publication is void; delivery is uncertain from here.
        event.postToPid(job.pid)
      },
      mayContinue: {
        replacementLive(job.snapshot) && actionTapEnabled() && modifiersReleased()
          && secureInputOff()
      })
  }

  private func readKeyboardState(
    _ job: ReplacementJob, caret: Int,
    characterCount: Int, layout: Layout, removedCount: Int
  ) -> KeyboardConfirmation {
    job.snapshot.contextDirty.value = 0
    guard let context = job.context, replacementLive(job.snapshot),
      context.sameFocus(generation: job.snapshot.generation)
    else { return .rejected }
    let layoutMatches = layoutSnapshot.withLock { $0.layout == layout }
    var confirmed = false
    if layoutMatches, let current = context.copyRange(), let count = context.characterCount() {
      confirmed =
        positionMatches(current, actualCount: count, caret: caret, expectedCount: characterCount)
        && terminalScreenCountMatches(
          actual: context.terminalScreenCount, original: job.terminalScreenCount,
          removed: removedCount)
    }
    return confirmed && replacementLive(job.snapshot)
      && context.sameFocus(generation: job.snapshot.generation) ? .confirmed : .pending
  }

  private func verifyReplacement(
    _ job: ReplacementJob, caret: Int,
    characterCount: Int, layout: Layout, removedCount: Int
  ) -> Bool {
    let now = monotonicNowNS()
    guard now != 0 else { return false }
    return awaitKeyboardConfirmation(
      changed: job.snapshot.contextChanged, deadline: now &+ actionBudgetNS,
      readState: {
        self.readKeyboardState(
          job, caret: caret, characterCount: characterCount, layout: layout,
          removedCount: removedCount)
      },
      now: monotonicNowNS)
  }

  private func executeReplacement(_ job: ReplacementJob) {
    guard let context = job.context,
      runtimeCondition(CGPreflightPostEventAccess(), .replacementRefused, .postingNotTrusted)
    else { return }
    guard let refreshed = context.refresh() else {
      _ = context.replacementCondition(false, .replacementRefused)
      return
    }
    let caret = refreshed.selection
    let snapshot = job.snapshot
    let length = snapshot.original.count
    guard runtimeCondition(context.focus == job.focus, .replacementRefused, .focusChanged),
      runtimeCondition(context.layout != snapshot.target, .replacementRefused, .layoutChanged),
      runtimeCondition(caret.location >= length, .replacementRefused, .invalidRange),
      runtimeCondition(context.candidateConfirmed, .replacementRefused, .anchorUnconfirmed),
      runtimeCondition(
        context.candidateCaret == caret.location, .replacementRefused, .caretChanged),
      runtimeCondition(
        snapshot.generation == context.candidateGeneration
          || snapshot.generation &- context.candidateGeneration == 1,
        .replacementRefused, .candidateGeneration), let source = context.layout,
      let element = context.element
    else { return }
    job.source = source
    guard AXUIElementGetPid(element, &job.pid) == .success, job.pid > 0 else { return }
    coordination.withLock { _ in job.expectedElement = element }
    let range = CFRange(location: caret.location - length, length: length)
    guard let originalCount = context.characterCount() else {
      _ = context.replacementCondition(false, .replacementRefused)
      return
    }
    job.terminalScreenCount = context.terminalScreenCount
    guard originalCount >= caret.location,
      context.replacementCondition(
        context.replacementRangeAvailable(range, total: originalCount), .replacementRangeRead),
      requestLayout(job, selectTarget: false), let plan = job.preparation?.plan
    else { return }
    // Key-down/up and Shift releases are all allocated before deletion.
    guard replacementLive(snapshot), modifiersReleased(), secureInputOff(),
      runtimeCondition(CGPreflightPostEventAccess(), .replacementRefused, .postingNotTrusted),
      context.replacementCondition(
        context.sameFocus(generation: snapshot.generation), .replacementRefused),
      let finalCaret = context.copyRange(), finalCaret.length == 0,
      finalCaret.location == caret.location,
      let finalCount = context.characterCount(), finalCount == originalCount,
      terminalScreenCountMatches(
        actual: context.terminalScreenCount, original: job.terminalScreenCount, removed: 0),
      context.replacementRangeAvailable(range, total: finalCount), beforeDeadline(job.deadline),
      actionTapEnabled()
    else { return }
    if job.beforeAction {
      guard automaticEnabled,
        deferredAction.claim(generation: snapshot.generation, now: monotonicNowNS())
      else { return }
    }
    context.candidateConfirmed = false
    snapshot.phase.value = ReplacementPhase.deleting.rawValue
    DiagnosticLogger.shared.record(.replacementKeyboardDelete, 0)
    let posted = postKeyboardRange(job, begin: 0, end: plan.deletionEnd)
    let deleted =
      posted
      && verifyReplacement(
        job, caret: range.location,
        characterCount: originalCount - length, layout: source, removedCount: length)
    if !deleted && posted {
      DiagnosticLogger.shared.record(
        .replacementKeyboardDelete, RuntimeReason.verificationTimeout.rawValue)
    }
    snapshot.phase.value = ReplacementPhase.switching.rawValue
    if job.beforeAction { deferredAction.phase = .switching }
    let switched = deleted && requestLayout(job, selectTarget: true)
    snapshot.phase.value = ReplacementPhase.typing.rawValue
    // TIS may have stalled while the app moved the caret. Recheck DELETED
    // position/count immediately before typing, not the original position.
    let typed =
      switched
      && runtimeCondition(
        readKeyboardState(
          job, caret: range.location,
          characterCount: originalCount - length, layout: snapshot.target, removedCount: length)
          == .confirmed,
        .replacementRefused, .anchorUnconfirmed)
      && CGPreflightPostEventAccess()
      && postKeyboardRange(job, begin: plan.deletionEnd, end: plan.events.count)
    if typed {
      DiagnosticLogger.shared.record(.replacementKeyboardTyped, 0)
      snapshot.phase.value = ReplacementPhase.verifying.rawValue
      if verifyReplacement(
        job, caret: caret.location, characterCount: originalCount,
        layout: snapshot.target, removedCount: 0)
      {
        job.result = 1
        DiagnosticLogger.shared.record(.replacementPositionVerification, 0)
      } else {
        DiagnosticLogger.shared.record(
          .replacementPositionVerification, RuntimeReason.verificationTimeout.rawValue)
      }
    }
  }

  func finishReplacement(_ job: ReplacementJob) {
    guard
      job.snapshot.phase.exchange(ReplacementPhase.completed.rawValue)
        != ReplacementPhase.completed.rawValue
    else { return }
    if waitingReplacement === job { waitingReplacement = nil }
    if let timer = job.timer {
      CFRunLoopTimerInvalidate(timer)
      job.timer = nil
    }
    if job.beforeAction && deferredAction.generation == job.snapshot.generation {
      let saved = resolveReplacementAction(
        &deferredAction, result: &job.result, suppressed: &suppressedActionKey)
      if let saved {
        saved.postToPid(job.pid)
        invalidate()
      } else if job.result == 4 {
        DiagnosticLogger.shared.record(.replacementActionSuppressed, 0)
      } else {
        readyDeferredAction()
      }
    }
    if job.result == 3 || job.result == 4 {
      failure.value = UInt64(job.result)
      setPaused(true)
    }
    if job.result == 1 { report(0) }
    coordination.withLock { state in if state.job === job { state.job = nil } }
    job.context = nil  // End the exclusive loan BEFORE waking its owner.
    job.done.signal()
  }

  private func beforeDeadline(_ deadline: UInt64) -> Bool {
    let now = monotonicNowNS()
    return now != 0 && now < deadline
  }

  private func runReplacement(_ job: ReplacementJob) {
    job.scheduled = false
    if job.snapshot.phase.value == ReplacementPhase.completed.rawValue { return }
    guard replacementLive(job.snapshot), beforeDeadline(job.deadline),
      !job.beforeAction
        || deferredAction.mayStart(generation: job.snapshot.generation, now: monotonicNowNS())
    else {
      finishReplacement(job)
      return
    }
    if !modifiersReleased() {
      job.snapshot.phase.value = ReplacementPhase.waitingModifiers.rawValue
      waitingReplacement = job
      job.heldModifiers =
        CGEventSource.flagsState(.hidSystemState).rawValue & replacementModifierMask
      if job.timer == nil {
        let now = monotonicNowNS()
        let remaining =
          now != 0 && now < job.deadline ? Double(job.deadline - now) / 1_000_000_000 : 0
        job.timer = CFRunLoopTimerCreateWithHandler(
          kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + remaining, 0, 0, 0
        ) { [weak self, weak job] _ in
          guard let self, let job else { return }
          DiagnosticLogger.shared.record(.replacementRefused, RuntimeReason.modifiersHeld.rawValue)
          job.snapshot.cancelled.boolValue = true
          self.finishReplacement(job)
        }
        if let timer = job.timer {
          CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        } else {
          finishReplacement(job)
        }
      }
      return
    }
    waitingReplacement = nil
    job.snapshot.phase.value = ReplacementPhase.preparing.rawValue
    executeReplacement(job)
    finishReplacement(job)
  }

  private func queueReplacement(_ job: ReplacementJob) {
    guard !job.scheduled else { return }
    job.scheduled = true
    CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue) {
      [self, job] in runReplacement(job)
    }
    CFRunLoopWakeUp(CFRunLoopGetCurrent())
  }

  func replacementRelease(type: CGEventType, event: CGEvent) -> Bool {
    guard let job = waitingReplacement else { return false }
    let keycode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue & replacementModifierMask
    let savedKey =
      job.beforeAction
      ? deferredAction.keyDown.map {
        UInt32(truncatingIfNeeded: $0.getIntegerValueField(.keyboardEventKeycode)) + 1
      } ?? 0 : 0
    let release = isPreparationRelease(
      type: type, keycode: keycode, flags: flags, heldModifiers: job.heldModifiers,
      savedActionKey: savedKey)
    if type == .keyDown && consumedKey.value == UInt64(keycode) + 1
      && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    {
      return true
    }
    if release { job.heldModifiers = flags } else { job.snapshot.cancelled.boolValue = true }
    queueReplacement(job)
    return release
  }

  func replace(
    context: AXContext, focus: UInt64, generation: UInt64, original: [UInt16],
    replacement: [UInt16],
    target: Layout, beforeAction: Bool
  ) -> Int32 {
    guard
      runtimeCondition(
        !original.isEmpty && original.count <= 128 && replacement.count == original.count,
        .replacementRefused, .invalidArgument)
    else { return 0 }
    let now = monotonicNowNS()
    guard now != 0 else { return 0 }
    let job: ReplacementJob
    do {
      job = try ReplacementJob(
        context: context, focus: focus, generation: generation, original: original,
        replacement: replacement, target: target, beforeAction: beforeAction, now: now)
    } catch {
      DiagnosticLogger.shared.record(.replacementRefused, RuntimeReason.allocationFailed.rawValue)
      return 0
    }
    let queued = coordination.withLock { state -> Bool in
      guard let loop = state.loop, !stopping.boolValue, state.job == nil,
        state.outstandingRequest == nil
      else { return false }
      state.job = job
      CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self, job] in
        if beforeAction && deferredAction.generation == generation {
          job.deadline = deferredAction.deadline
        }
        runReplacement(job)
      }
      CFRunLoopWakeUp(loop)
      return true
    }
    guard queued else {
      job.context = nil
      return 0
    }
    // Exactly one job; only the correction worker waits here. Listener stop
    // completes queued loans. Queued main blocks never hold this loan.
    job.done.wait()
    return job.result
  }
}
