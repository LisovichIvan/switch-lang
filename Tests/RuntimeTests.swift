import ApplicationServices
import Carbon
import Foundation

// All fixtures are synthetic/unposted: no event tap, AX messaging, TIS selection,
// IOKit controller, permissions, application UI, settings or keychain access.
func runRuntimeTests() throws -> Int {
  let tests: [() throws -> Void] = [
    testContextEnabledAttributeCompatibility,
    testMetadataOnlyAttributes,
    testTerminalReadOnlyKeyboardContext,
    testTerminalInsertionLineValidation,
    testTerminalInputEchoProgress,
    testTerminalPreInputAnchor,
    testRuntimeStaleContextNotifications,
    testTerminalScreenCharacterCount,
    testRuntimeActionEligibility,
    testRuntimeActionOwnershipAndMetadata,
    testRuntimeActionResultAndSuppression,
    testRuntimeMainCancellationAndAcknowledgement,
    testRuntimeRepeatedOwnLayoutNotifications,
    testRuntimeIndependentConfirmationDeadlines,
    testRuntimePreparationReleases,
    testRuntimeNumericRangesAndTime,
    testRuntimeCapsGenerationClaims,
    testRuntimeEmissionCancellation,
    testRuntimeFailureRequiresExplicitAcknowledgement,
    testRuntimePassedThroughActionsInvalidateTracking,
  ]
  for test in tests { try test() }
  return tests.count
}

private func testContextEnabledAttributeCompatibility() throws {
  // Regression: a focused editable AppKit NSTextView rejected manual-en-ru
  // before deletion solely because AXEnabled returned attributeUnsupported.
  try requireTest(
    contextFlagAccepted(
      attribute: kAXEnabledAttribute, isTextArea: true, error: .attributeUnsupported, value: nil),
    "standard NSTextView does not require an unsupported AXEnabled attribute")
  for isTextArea in [false, true] {
    for attribute in [kAXEnabledAttribute, kAXFocusedAttribute] {
      try requireTest(
        contextFlagAccepted(
          attribute: attribute, isTextArea: isTextArea, error: .success, value: kCFBooleanTrue),
        "supported context flag must be true")
      for value: CFTypeRef? in [nil, kCFBooleanFalse, NSNumber(value: 1), "true" as CFString] {
        try requireTest(
          !contextFlagAccepted(
            attribute: attribute, isTextArea: isTextArea, error: .success, value: value),
          "disabled, unfocused, missing or malformed flags refuse input")
      }
      for error in [AXError.noValue, .cannotComplete, .apiDisabled, .invalidUIElement, .failure] {
        for value: CFTypeRef? in [nil, kCFBooleanTrue] {
          try requireTest(
            !contextFlagAccepted(
              attribute: attribute, isTextArea: isTextArea, error: error, value: value),
            "missing value or AX failure is not unsupported-attribute compatibility")
        }
      }
    }
  }
  try requireTest(
    !contextFlagAccepted(
      attribute: kAXFocusedAttribute, isTextArea: true, error: .attributeUnsupported, value: nil),
    "focus must always be positively confirmed")
  try requireTest(
    !contextFlagAccepted(
      attribute: kAXEnabledAttribute, isTextArea: false, error: .attributeUnsupported, value: nil),
    "unsupported AXEnabled compatibility is limited to the verified AXTextArea role")
  try requireTest(
    !contextFlagAccepted(
      attribute: kAXEnabledAttribute, isTextArea: true, error: .attributeUnsupported,
      value: kCFBooleanTrue),
    "an inconsistent unsupported response does not bypass flag validation")
}

private func testMetadataOnlyAttributes() throws {
  let expected: Set<String> = [
    "AXRole", "AXSubrole", "AXFocused", "AXEnabled", "AXContainsProtectedContent",
    "AXSelectedTextRanges", "AXSelectedTextRange", "AXFocusedUIElement",
    "AXNumberOfCharacters", "AXInsertionPointLineNumber",
  ]
  let actual = AXMetadataAttribute.allCases.map { $0.name }
  try requireTest(
    actual.count == expected.count && Set(actual) == expected,
    "the AX boundary exposes only metadata, never field contents or selected text")
}

private func testTerminalReadOnlyKeyboardContext() throws {
  // Apple Terminal's AXTextArea reports both text attributes as non-settable,
  // while its verified insertion caret and physical keyboard input work.
  try requireTest(
    keyboardContextEditable(hasWritableText: false, isVerifiedTerminal: true),
    "verified Terminal keyboard input must not require AX text-write capability")
  try requireTest(
    !keyboardContextEditable(hasWritableText: false, isVerifiedTerminal: false),
    "other read-only screens remain rejected")
  for terminal in [false, true] {
    try requireTest(
      keyboardContextEditable(hasWritableText: true, isVerifiedTerminal: terminal),
      "ordinary writable text remains accepted")
  }
}

private func testTerminalInsertionLineValidation() throws {
  // Captured from our isolated native TTY fixture, not a user shell:
  // insertion cursor 38 -> 32 after six Backspaces, while AX count stays 68.
  let anchor = TerminalLineAnchor(number: 30, location: 30)
  try requireTest(
    terminalInsertionAnchor(
      selection: CFRange(location: 38, length: 0), lineNumber: 30,
      lineRange: CFRange(location: 30, length: 9)) == anchor,
    "tracking uses insertion metadata without rejecting a newly echoed letter from a later AX reply"
  )
  for caret in [38, 32] {
    try requireTest(
      terminalLineAnchor(
        selection: CFRange(location: caret, length: 0), characterCount: 68, lineNumber: 30,
        lineRange: CFRange(location: 30, length: 9)) == anchor,
      "Terminal line and cursor bounds remain verifiable after erasure without reading a tail")
  }
  try requireTest(
    terminalLineAnchor(
      selection: CFRange(location: 38, length: 0), characterCount: 68, lineNumber: 30,
      lineRange: CFRange(location: 30, length: 8)) == anchor,
    "Terminal can omit the line terminator from its numeric range")
  for (selection, count, line, range) in [
    (CFRange(location: 32, length: 1), 68, 30, CFRange(location: 30, length: 2)),
    (CFRange(location: -1, length: 0), 68, 30, CFRange(location: 30, length: 2)),
    (CFRange(location: 32, length: 0), 31, 30, CFRange(location: 30, length: 2)),
    (CFRange(location: 32, length: 0), 68, -1, CFRange(location: 30, length: 2)),
    (CFRange(location: 32, length: 0), 68, 30, CFRange(location: 33, length: 0)),
    (CFRange(location: 32, length: 0), 68, 30, CFRange(location: 30, length: 1)),
    (CFRange(location: 32, length: 0), 68, 30, CFRange(location: 30, length: Int.max)),
    (CFRange(location: Int.max, length: 0), 68, 30, CFRange(location: 30, length: 2)),
  ] {
    try requireTest(
      terminalLineAnchor(
        selection: selection, characterCount: count, lineNumber: line, lineRange: range)
        == nil,
      "selection, invalid insertion line and overflowing AX ranges refuse Terminal correction")
  }
  try requireTest(
    terminalLineAnchor(
      selection: CFRange(location: 0, length: 0), characterCount: Int.max, lineNumber: 0,
      lineRange: CFRange(location: 0, length: Int.max))
      == TerminalLineAnchor(number: 0, location: 0),
    "large numeric bounds neither allocate nor read any application text")
}

private func testTerminalInputEchoProgress() throws {
  var visible = TerminalInputProgress()
  visible.prime(caret: 32)
  for _ in 0..<6 { visible.observe(units: 1, backspace: false) }
  try requireTest(
    visible.confirms(caret: 38) && !visible.confirms(caret: 32),
    "Terminal must echo the observed input at the advancing insertion cursor")
  visible.observe(units: 0, backspace: true)
  try requireTest(visible.confirms(caret: 37), "observed user Backspace updates Terminal progress")
  var hidden = TerminalInputProgress()
  hidden.prime(caret: 38)  // A matching word was already printed before input.
  for _ in 0..<6 { hidden.observe(units: 1, backspace: false) }
  try requireTest(
    !hidden.confirms(caret: 38),
    "preprinted matching suffix plus no-echo input must refuse correction before deletion")
  hidden.prime(caret: 38)
  try requireTest(
    !hidden.confirms(caret: 38), "AX notifications cannot rebase a mismatch after input began")
  var unprimed = TerminalInputProgress()
  unprimed.observe(units: 1, backspace: false)
  unprimed.prime(caret: 38)
  try requireTest(
    !unprimed.confirms(caret: 38), "input without a pre-input cursor anchor cannot be adopted later"
  )
  var overflow = TerminalInputProgress()
  overflow.prime(caret: Int.max)
  overflow.observe(units: 1, backspace: false)
  try requireTest(!overflow.confirms(caret: Int.max), "Terminal cursor arithmetic cannot overflow")
  var unknownPrefix = TerminalInputProgress()
  unknownPrefix.prime(caret: 38)
  for _ in 0..<6 { unknownPrefix.observe(units: 1, backspace: false) }
  for _ in 0..<7 { unknownPrefix.observe(units: 0, backspace: true) }
  unknownPrefix.observe(units: 1, backspace: false)
  try requireTest(
    !unknownPrefix.confirms(caret: 38),
    "no-echo input cannot regain a preprinted match by deleting beyond the initial cursor anchor")
  var empty = TerminalInputProgress()
  empty.prime(caret: 0)
  empty.observe(units: 0, backspace: true)
  try requireTest(!empty.confirms(caret: 0), "unknown deletion before the anchor is not clamped")
}

private func testTerminalPreInputAnchor() throws {
  var input = InputMetadata(kind: .key, keycode: 5, generation: 8, timestampNS: 200)
  let anchor = TerminalPreInputAnchor(caret: 32, generation: 7, finishedNS: 100)
  try requireTest(
    anchor.precedes(input, processedGeneration: 7),
    "a pre-key snapshot survives late AX notification processing without retroactive rebasing")
  for processed: UInt64 in [0, 6, 8, UInt64.max] {
    try requireTest(
      !anchor.precedes(input, processedGeneration: processed), "anchor belongs to one generation")
  }
  for generation: UInt64 in [0, 7, 9, UInt64.max] {
    input.generation = generation
    try requireTest(
      !anchor.precedes(input, processedGeneration: 7), "generation gaps reject pre-input evidence")
  }
  input.generation = 8
  for finished: UInt64 in [0, 200, 201, UInt64.max] {
    let late = TerminalPreInputAnchor(caret: 32, generation: 7, finishedNS: finished)
    try requireTest(
      !late.precedes(input, processedGeneration: 7), "capture must finish strictly before the key")
  }
  for kind in [InputKind.hotkey, .action, .contextChanged, .reset, .stop] {
    input.kind = kind
    try requireTest(
      !anchor.precedes(input, processedGeneration: 7),
      "only the first ordinary input can adopt an anchor")
  }
  input.kind = .key
  for keycode: UInt16 in [36, 48, 76, 123] {
    input.keycode = keycode
    try requireTest(
      !anchor.precedes(input, processedGeneration: 7), "navigation cannot revive a word")
  }
  input.keycode = 5
  input.flags = CGEventFlags.maskCommand.rawValue
  try requireTest(
    !anchor.precedes(input, processedGeneration: 7), "shortcuts invalidate the armed context")
  input.flags = 0
  try requireTest(
    !TerminalPreInputAnchor(caret: -1, generation: 7, finishedNS: 100).precedes(
      input, processedGeneration: 7),
    "negative pre-input positions are never accepted")
  var visible = TerminalInputProgress()
  visible.prime(caret: anchor.caret)
  for _ in 0..<6 { visible.observe(units: 1, backspace: false) }
  try requireTest(visible.confirms(caret: 38), "fresh pre-input baseline permits visible progress")
  try requireTest(!visible.confirms(caret: 32), "pre-input capture does not authorize hidden input")
  var hiddenBackspace = TerminalInputProgress()
  hiddenBackspace.prime(caret: anchor.caret)
  for _ in 0..<6 { hiddenBackspace.observe(units: 0, backspace: true) }
  for _ in 0..<6 { hiddenBackspace.observe(units: 1, backspace: false) }
  try requireTest(
    !hiddenBackspace.confirms(caret: 32), "fresh capture cannot bypass the initial deletion bound")
}

private func testRuntimeStaleContextNotifications() throws {
  var input = InputMetadata(kind: .contextChanged)
  input.generation = 7
  try requireTest(
    contextNotificationIsCurrent(input, processedGeneration: 7, currentGeneration: 7),
    "current AX notification may confirm the tracked candidate")
  try requireTest(
    !contextNotificationIsCurrent(input, processedGeneration: 7, currentGeneration: 8),
    "AX reads must not invalidate the old candidate while the next key is pending")
  input.generation = 8
  try requireTest(
    !contextNotificationIsCurrent(input, processedGeneration: 7, currentGeneration: 8),
    "AX notification cannot overtake unprocessed key metadata")
  input.generation = 6
  try requireTest(
    !contextNotificationIsCurrent(input, processedGeneration: 7, currentGeneration: 7),
    "old AX notifications cannot re-anchor a newer candidate")
  input.kind = .key
  try requireTest(
    contextNotificationIsCurrent(input, processedGeneration: 7, currentGeneration: 8),
    "key metadata is not discarded by the AX-only staleness predicate")
}

private func testTerminalScreenCharacterCount() throws {
  try requireTest(
    terminalScreenCountMatches(actual: nil, original: nil, removed: 6),
    "ordinary text fields do not use Terminal screen-count compatibility")
  for actual in [68, 62] {
    try requireTest(
      terminalScreenCountMatches(actual: actual, original: 68, removed: 6),
      "Terminal may retain blank cells or trim erased characters")
  }
  for actual: Int? in [nil, 0, 61, 63, 67, 69, Int.max] {
    try requireTest(
      !terminalScreenCountMatches(actual: actual, original: 68, removed: 6),
      "unrelated Terminal output or a missing count cannot confirm deletion")
  }
  try requireTest(
    terminalScreenCountMatches(actual: 68, original: 68, removed: 0)
      && !terminalScreenCountMatches(actual: 62, original: 68, removed: 0)
      && !terminalScreenCountMatches(actual: 68, original: nil, removed: 0)
      && !terminalScreenCountMatches(actual: nil, original: 68, removed: 0)
      && !terminalScreenCountMatches(actual: 68, original: 68, removed: -1)
      && !terminalScreenCountMatches(actual: 68, original: 68, removed: 69),
    "pre-delete and final screen counts are exact and cannot change surface kind")
}

private func testRuntimeActionEligibility() throws {
  for keycode: UInt16 in 0..<128 {
    try requireTest(
      actionEligible(
        keycode: keycode, flags: 0, automatic: true, hotkey: false, repeated: false,
        candidate: 7, generation: 8) == [UInt16(36), 48, 76].contains(keycode),
      "only Enter/Tab actions")
  }
  for keycode: UInt16 in [36, 48, 76] {
    try requireTest(
      actionEligible(
        keycode: keycode,
        flags: CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlphaShift.rawValue,
        automatic: true, hotkey: false, repeated: false, candidate: 7, generation: 8),
      "shifted action allowed")
    for flags in [
      CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn, .maskHelp,
    ] {
      try requireTest(
        !actionEligible(
          keycode: keycode, flags: flags.rawValue, automatic: true, hotkey: false,
          repeated: false, candidate: 7, generation: 8), "shortcut is not deferred")
    }
    for (automatic, hotkey, repeated, candidate, generation) in [
      (false, false, false, UInt64(7), UInt64(8)), (true, true, false, 7, 8),
      (true, false, true, 7, 8),
      (true, false, false, 0, 1), (true, false, false, 7, 9), (true, false, false, 8, 8),
    ] {
      try requireTest(
        !actionEligible(
          keycode: keycode, flags: 0, automatic: automatic, hotkey: hotkey,
          repeated: repeated, candidate: candidate, generation: generation),
        "invalid action candidate")
    }
  }
}

private func testRuntimeActionOwnershipAndMetadata() throws {
  for keycode: UInt16 in [36, 48, 76] {
    guard let original = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true)
    else {
      throw TestFailure(description: "allocate synthetic action")
    }
    original.flags = .maskShift
    original.setIntegerValueField(.keyboardEventKeyboardType, value: 41)
    original.timestamp = 12345
    guard let saved = original.copy() else { throw TestFailure(description: "copy action") }
    var action = DeferredAction(phase: .pending, generation: 8, deadline: 100, keyDown: saved)
    try requireTest(
      action.mayStart(generation: 8, now: 99) && !action.mayStart(generation: 8, now: 0)
        && !action.mayStart(generation: 7, now: 99) && !action.mayStart(generation: 8, now: 100)
        && !action.mayStart(generation: 8, now: 101), "monotonic action deadline/generation")
    for phase in [ActionPhase.committing, .switching, .ready, .idle] {
      action.phase = phase
      try requireTest(!action.mayStart(generation: 8, now: 99), "only pending action can start")
    }
    action.phase = .pending
    try requireTest(
      action.markReady() && !action.markReady() && !action.claim(generation: 8, now: 99),
      "cancellation wins over late mutation")
    action.phase = .pending
    try requireTest(
      action.claim(generation: 8, now: 99) && !action.markReady()
        && !action.claim(generation: 8, now: 99),
      "timeout cannot release committing action")
    action.phase = .switching
    try requireTest(!action.markReady(), "layout switch cannot release unverified action")
    let taken = action.take()
    try requireTest(
      taken === saved && action.phase == .idle && action.take() == nil && taken?.type == .keyDown
        && taken?.getIntegerValueField(.keyboardEventKeycode) == Int64(keycode)
        && taken?.getIntegerValueField(.keyboardEventKeyboardType) == 41
        && taken?.flags == .maskShift && taken?.timestamp == 12345,
      "one-shot action ownership preserves original metadata")
  }
  let runtime = try KeyboardRuntime(submitInput: { _ in true })
  let wake = runtime.createActionWake()
  try requireTest(
    wake?.type == .null && wake?.getIntegerValueField(.eventSourceUserData) == actionWakeTag,
    "unposted null wake metadata")
}

private func testRuntimeActionResultAndSuppression() throws {
  for keycode: UInt16 in [36, 48, 76] {
    for initialResult: Int32 in [0, 1, 3, 4] {
      guard let saved = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true) else {
        throw TestFailure(description: "allocate synthetic action result")
      }
      saved.flags = .maskShift
      var action = DeferredAction(phase: .switching, generation: 8, keyDown: saved)
      var suppressed: UInt32 = 0
      var result = initialResult
      let returned = resolveReplacementAction(&action, result: &result, suppressed: &suppressed)
      if initialResult == 0 {
        try requireTest(
          returned == nil && action.phase == .pending && action.keyDown === saved
            && suppressed == 0,
          "pre-deletion refusal preserves ordinary action")
      } else if initialResult == 1 {
        try requireTest(
          returned === saved && returned?.flags == .maskShift && result == 1
            && action.phase == .idle && action.keyDown == nil && suppressed == 0,
          "verified action delivered exactly once")
      } else {
        try requireTest(
          returned == nil && action.phase == .idle && action.keyDown == nil && result == 4
            && suppressed == UInt32(keycode) + 1,
          "uncertain destructive result suppresses saved action")
        try requireTest(
          !suppressActionEvent(pending: &suppressed, type: .keyUp, keycode: 0, repeated: false)
            && suppressed == UInt32(keycode) + 1, "unrelated release preserved")
        try requireTest(
          suppressActionEvent(
            pending: &suppressed, type: .keyDown, keycode: keycode, repeated: true)
            && suppressActionEvent(
              pending: &suppressed, type: .keyUp, keycode: keycode, repeated: false)
            && suppressed == 0,
          "uncertain action repeats and release suppressed")
        suppressed = UInt32(keycode) + 1
        try requireTest(
          !suppressActionEvent(
            pending: &suppressed, type: .keyDown, keycode: keycode, repeated: false)
            && suppressed == 0, "fresh deliberate action is not swallowed")
      }
      _ = action.take()
    }
  }
}

private func testRuntimeMainCancellationAndAcknowledgement() throws {
  let cancelled = try MainLayoutRequest()
  cancelled.cancel()
  cancelled.cancel()
  try requireTest(
    !cancelled.begin() && cancelled.phase.value == MainRequestPhase.cancelled.rawValue
      && cancelled.done.wait(timeout: .now()) == .success
      && cancelled.done.wait(timeout: .now()) == .timedOut,
    "cancel signals once and queued main cannot begin")
  let running = try MainLayoutRequest()
  try requireTest(running.begin() && !running.begin(), "main request begins exactly once")
  running.cancel()
  try requireTest(
    running.phase.value == MainRequestPhase.running.rawValue
      && running.done.wait(timeout: .now()) == .timedOut,
    "running main request is not falsely acknowledged")
  running.complete(success: true)
  try requireTest(
    !running.begin() && running.success
      && running.phase.value == MainRequestPhase.completed.rawValue
      && running.done.wait(timeout: .now()) == .success, "running main completes without retry")
  var coordination = RuntimeCoordination()
  coordination.outstandingRequest = cancelled
  try requireTest(
    coordination.outstandingRequest === cancelled,
    "cancelled main slot retained until queued block ACK")
  coordination.outstandingRequest = nil  // Simulate the main block's ACK, not a timeout.
  try requireTest(coordination.outstandingRequest == nil, "main ACK releases slot")
}

private func testRuntimeRepeatedOwnLayoutNotifications() throws {
  for target in [Layout.english, .russian] {
    let snapshot = try ReplacementSnapshot(
      generation: 7, original: [97], replacement: [0x444], target: target)
    snapshot.expectsLayoutChange.boolValue = true
    snapshot.phase.value = ReplacementPhase.verifying.rawValue
    // Live AppKit reproduction: two selected-source notifications for one
    // successful TIS switch invalidated the job after text had been typed.
    for _ in 0..<3 {
      try requireTest(
        replacementAcceptsLayoutNotification(snapshot, readCurrentLayout: { target }),
        "repeated own TIS notifications must preserve final text verification")
    }
    try requireTest(
      !replacementAcceptsLayoutNotification(snapshot, readCurrentLayout: { target.opposite })
        && !replacementAcceptsLayoutNotification(snapshot, readCurrentLayout: { nil }),
      "external or unknown layout is never accepted as an own switch")
    for phase in [ReplacementPhase.queued, .waitingModifiers, .preparing, .deleting, .completed] {
      snapshot.phase.value = phase.rawValue
      var reads = 0
      try requireTest(
        !replacementAcceptsLayoutNotification(
          snapshot,
          readCurrentLayout: {
            reads += 1
            return target
          }) && reads == 0,
        "own notifications require an active switch or verification stage")
    }
    snapshot.phase.value = ReplacementPhase.typing.rawValue
    snapshot.cancelled.boolValue = true
    try requireTest(
      !replacementAcceptsLayoutNotification(snapshot, readCurrentLayout: { target }),
      "a cancelled job cannot accept a layout notification")
    snapshot.cancelled.boolValue = false
    snapshot.expectsLayoutChange.boolValue = false
    try requireTest(
      !replacementAcceptsLayoutNotification(snapshot, readCurrentLayout: { target }),
      "an unarmed job cannot accept a layout notification")
  }
}

private func testRuntimeIndependentConfirmationDeadlines() throws {
  let noisy = DispatchSemaphore(value: 0)
  var syntheticNow: UInt64 = 10
  var reads = 0
  let matched = awaitKeyboardConfirmation(
    changed: noisy, deadline: 10 + actionBudgetNS,
    readState: {
      reads += 1
      syntheticNow += actionBudgetNS / 2
      noisy.signal()
      return reads >= 6 ? .rejected : .pending
    }, now: { syntheticNow })
  try requireTest(
    !matched && reads == 3, "notification storm cannot extend deadline; final read performed")
  var finalReads = 0
  try requireTest(
    awaitKeyboardConfirmation(
      changed: noisy, deadline: 20,
      readState: {
        finalReads += 1
        return .confirmed
      }, now: { 20 }) && finalReads == 1, "final read may confirm exact state")
  try requireTest(
    !awaitKeyboardConfirmation(changed: noisy, deadline: 20, readState: { .rejected }, now: { 19 }),
    "unsafe focus rejects without wait")
  var zeroReads = 0
  try requireTest(
    !awaitKeyboardConfirmation(
      changed: noisy, deadline: 20,
      readState: {
        zeroReads += 1
        return .confirmed
      }, now: { 0 }) && zeroReads == 0, "clock failure is not fresh confirmation")
  for start: UInt64 in [100, 1_000_000_000] {
    var now = start
    var count = 0
    try requireTest(
      awaitKeyboardConfirmation(
        changed: noisy, deadline: start + actionBudgetNS,
        readState: {
          count += 1
          now += actionBudgetNS
          return count == 2 ? .confirmed : .pending
        }, now: { now }) && count == 2, "each confirmation stage owns an independent deadline")
  }
  try requireTest(
    positionMatches(CFRange(location: 4, length: 0), actualCount: 9, caret: 4, expectedCount: 9)
      && !positionMatches(
        CFRange(location: 5, length: 0), actualCount: 9, caret: 4, expectedCount: 9)
      && !positionMatches(
        CFRange(location: 4, length: 1), actualCount: 9, caret: 4, expectedCount: 9)
      && !positionMatches(
        CFRange(location: 4, length: 0), actualCount: 10, caret: 4, expectedCount: 9),
    "deleted caret, empty selection and character count all required")
}

private func testRuntimePreparationReleases() throws {
  try requireTest(
    isPreparationRelease(
      type: .flagsChanged, keycode: 56, flags: 0,
      heldModifiers: CGEventFlags.maskShift.rawValue, savedActionKey: 0),
    "modifier release accepted")
  try requireTest(
    !isPreparationRelease(
      type: .flagsChanged, keycode: 55, flags: CGEventFlags.maskCommand.rawValue,
      heldModifiers: 0, savedActionKey: 0), "new modifier cancels")
  try requireTest(
    isPreparationRelease(type: .keyUp, keycode: 97, flags: 0, heldModifiers: 0, savedActionKey: 0),
    "hotkey release accepted")
  try requireTest(
    !isPreparationRelease(
      type: .keyUp, keycode: 36, flags: 0, heldModifiers: 0, savedActionKey: 37),
    "saved action release cancels")
  try requireTest(
    !isPreparationRelease(type: .keyDown, keycode: 0, flags: 0, heldModifiers: 0, savedActionKey: 0)
      && !isPreparationRelease(
        type: .scrollWheel, keycode: 0, flags: 0, heldModifiers: 0, savedActionKey: 0),
    "new physical input wins")
}

private func testRuntimeNumericRangesAndTime() throws {
  var range = CFRange(location: 3, length: 6)
  guard let value = AXValueCreate(.cfRange, &range) else {
    throw TestFailure(description: "allocate local AX range value")
  }
  var decoded = CFRange(location: 0, length: 0)
  try requireTest(
    AXValueGetValue(value, .cfRange, &decoded) && decoded.location == 3 && decoded.length == 6,
    "local AX range roundtrip")
  let before = monotonicNowNS()
  let after = monotonicNowNS()
  try requireTest(before != 0 && after >= before, "CLOCK_MONOTONIC supplies event freshness")
}

private func testRuntimeCapsGenerationClaims() throws {
  let generation = try AtomicUInt64(7)
  try requireTest(
    generation.compareExchange(expected: 7, desired: 8) && generation.value == 8
      && !generation.compareExchange(expected: 7, desired: 8) && generation.value == 8,
    "Caps claim compares captured generation")
  generation.fetchAdd(1)
  try requireTest(
    !generation.compareExchange(expected: 8, desired: 9) && generation.value == 9
      && generation.compareExchange(expected: 9, desired: 10) && generation.value == 10,
    "invalidation cannot become fresh Caps command")
  let snapshot = try ReplacementSnapshot(
    generation: 10, original: [102], replacement: [0x430], target: .russian)
  snapshot.signalContext()
  snapshot.signalContext()
  try requireTest(
    snapshot.contextChanged.wait(timeout: .now()) == .success
      && snapshot.contextChanged.wait(timeout: .now()) == .timedOut,
    "own AX notifications coalesced")
  snapshot.contextDirty.value = 0
  snapshot.signalContext()
  try requireTest(
    snapshot.contextChanged.wait(timeout: .now()) == .success,
    "new verification read rearms context signal")
}

// Minimal synthetic uchr resource: one A key in lower/upper tables. No TIS read.
private func runtimeEmissionPlan() throws -> KeyboardEventPlan {
  var bytes = [UInt8](repeating: 0, count: 580)
  func put16(_ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
  }
  func put32(_ offset: Int, _ value: Int) {
    put16(offset, UInt16(truncatingIfNeeded: value))
    put16(offset + 2, UInt16(truncatingIfNeeded: value >> 16))
  }
  put16(0, 0x1002)
  put16(2, 0x100)
  put32(8, 1)
  put32(20, 40)
  put32(24, 52)
  put16(40, 0x3001)
  put32(44, 4)
  bytes[50] = 1
  bytes[51] = 1
  put16(52, 0x4001)
  put16(54, 128)
  put32(56, 2)
  put32(60, 68)
  put32(64, 324)
  for index in 0..<256 { put16(68 + index * 2, 0xffff) }
  put16(68, 97)
  put16(324, 65)
  return try KeyboardEventPlan(
    original: Array("Ф".utf16), replacement: [65], layoutData: Data(bytes), keyboardType: 40)
}

private func testRuntimeEmissionCancellation() throws {
  let plan = try runtimeEmissionPlan()
  try requireTest(
    plan.deletionEnd == 2 && plan.events.count == 6, "synthetic delete/shift/type plan")
  for allowance in 0...4 {
    var trace: [CGEvent] = []
    var checks = 0
    let emitted = emitKeyboardRange(
      plan, begin: 0, end: 6, post: { trace.append($0) },
      mayContinue: {
        defer { checks += 1 }
        return checks < allowance
      })
    try requireTest(
      emitted == (allowance == 4) && trace.count == [0, 2, 4, 6, 6][allowance],
      "emission cancellation count")
    for index in trace.indices {
      let expected = allowance == 2 && index == 3 ? 5 : index
      try requireTest(
        trace[index] === plan.events[expected], "release own key and Shift even after cancellation")
    }
  }
  var posts = 0
  try requireTest(
    !emitKeyboardRange(plan, begin: 0, end: 1, post: { _ in posts += 1 }, mayContinue: { true })
      && !emitKeyboardRange(
        plan, begin: 0, end: 7, post: { _ in posts += 1 }, mayContinue: { true })
      && posts == 0,
    "invalid emission ranges never post")
}

private func testRuntimeFailureRequiresExplicitAcknowledgement() throws {
  let runtime = try KeyboardRuntime(submitInput: { _ in true })
  runtime.failure.value = 3
  runtime.setPaused(false)
  try requireTest(
    runtime.paused.boolValue && runtime.replacementFailure == 3,
    "routine resume cannot clear destructive latch")
  runtime.acknowledgeReplacementFailure()
  try requireTest(
    runtime.replacementFailure == 0 && runtime.paused.boolValue,
    "acknowledgement alone does not silently resume")
  runtime.setPaused(false)
  try requireTest(!runtime.paused.boolValue, "explicit acknowledged resume succeeds")
}

private func testRuntimePassedThroughActionsInvalidateTracking() throws {
  for keycode: UInt16 in [36, 48, 76] {
    try requireTest(
      invalidatesKeyTracking(InputMetadata(kind: .key, keycode: keycode))
        && !invalidatesKeyTracking(InputMetadata(kind: .action, keycode: keycode)),
      "passed-through action never corrects text after submission/focus change")
  }
  for keycode: UInt16 in [0, 49, 51] {
    try requireTest(
      !invalidatesKeyTracking(InputMetadata(kind: .key, keycode: keycode)),
      "ordinary input retains tracking")
  }
}
