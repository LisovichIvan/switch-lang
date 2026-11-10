import AppKit
import ApplicationServices
import Foundation

func contextFlagAccepted(
  attribute: String, isTextArea: Bool, error: AXError, value: CFTypeRef?
) -> Bool {
  // The verified AppKit NSTextView omits AXEnabled. Limit compatibility to
  // AXTextArea; safeElement still requires focus and protection checks.
  if isTextArea && attribute == kAXEnabledAttribute && error == .attributeUnsupported
    && value == nil
  {
    return true
  }
  return error == .success
    && value.map {
      CFGetTypeID($0) == CFBooleanGetTypeID() && CFEqual($0, kCFBooleanTrue)
    } == true
}

func keyboardContextEditable(hasWritableText: Bool, isVerifiedTerminal: Bool) -> Bool {
  hasWritableText || isVerifiedTerminal
}

final class AXContext {
  unowned let runtime: KeyboardRuntime
  let system: AXUIElement
  private(set) var element: AXUIElement?
  private(set) var focus: UInt64 = 0
  private(set) var layout: Layout?
  var candidateConfirmed = false
  private(set) var candidateCaret = 0
  private(set) var candidateGeneration: UInt64 = 0
  private var failureStage: DiagnosticStage = .contextUnavailable
  private var failureDetail: Int32 = 0
  private var terminalElement: AXUIElement?
  private var terminalApplication: NSRunningApplication?
  private var terminalAnchor: TerminalLineAnchor?
  private var terminalProgress = TerminalInputProgress()
  private(set) var terminalScreenCount: Int?

  init(runtime: KeyboardRuntime) throws {
    self.runtime = runtime
    system = AXUIElementCreateSystemWide()
    let error = AXUIElementSetMessagingTimeout(system, 0.025)
    guard error == .success else {
      throw RuntimeFailure(stage: "AX messaging timeout", detail: error.rawValue)
    }
  }

  deinit { reset() }

  func reset() {
    runtime.clearContextObservation()
    element = nil
    layout = nil
    candidateConfirmed = false
    candidateCaret = 0
    candidateGeneration = 0
    terminalElement = nil
    terminalApplication = nil
    terminalAnchor = nil
    terminalProgress = TerminalInputProgress()
    terminalScreenCount = nil
    focus &+= 1
  }

  @discardableResult
  func condition(_ accepted: Bool, _ stage: DiagnosticStage, _ reason: RuntimeReason) -> Bool {
    condition(accepted, stage, detail: reason.rawValue)
  }

  @discardableResult
  private func condition(_ accepted: Bool, _ stage: DiagnosticStage, detail: Int32) -> Bool {
    if !accepted {
      failureStage = stage
      failureDetail = detail
      DiagnosticLogger.shared.setContextStatus(stage, detail)
    }
    return accepted
  }

  private func axResult(_ result: AXError, _ stage: DiagnosticStage) -> Bool {
    condition(result == .success, stage, detail: result.rawValue)
  }

  func replacementCondition(_ accepted: Bool, _ stage: DiagnosticStage) -> Bool {
    if !accepted {
      DiagnosticLogger.shared.record(failureStage, failureDetail)
      DiagnosticLogger.shared.record(stage, RuntimeReason.contextRejected.rawValue)
    }
    return accepted
  }

  func copyRange(_ target: AXUIElement? = nil, captureTerminalCount: Bool = true) -> CFRange? {
    guard let target = target ?? element else {
      condition(false, .contextRangeRead, .missingValue)
      return nil
    }
    var object: CFTypeRef?
    guard
      axResult(
        readAXMetadata(.selectedTextRange, from: target, value: &object),
        .contextRangeRead)
    else { return nil }
    guard let object else {
      condition(false, .contextRangeRead, .missingValue)
      return nil
    }
    guard condition(CFGetTypeID(object) == AXValueGetTypeID(), .contextRangeRead, .unexpectedType)
    else { return nil }
    // SAFETY: the dynamic CF type has just been checked.
    let value = unsafeBitCast(object, to: AXValue.self)
    guard condition(AXValueGetType(value) == .cfRange, .contextRangeRead, .unexpectedType) else {
      return nil
    }
    var range = CFRange(location: 0, length: 0)
    guard condition(AXValueGetValue(value, .cfRange, &range), .contextRangeRead, .rejectedValue),
      condition(range.location >= 0 && range.length >= 0, .contextRangeRead, .invalidRange)
    else { return nil }
    if terminalElement.map({ CFEqual($0, target) }) == true {
      guard
        let anchor = readTerminalAnchor(
          target, selection: range, captureScreenCount: captureTerminalCount),
        condition(
          terminalAnchor == nil || terminalAnchor == anchor, .contextCaretChanged, .caretChanged)
      else { return nil }
      terminalAnchor = anchor
    }
    return range
  }

  private func isVerifiedTerminal(pid: pid_t) -> Bool {
    if let application = terminalApplication, application.processIdentifier == pid,
      !application.isTerminated
    {
      return true
    }
    terminalApplication = verifiedAppleTerminal(pid: pid)
    return terminalApplication != nil
  }

  private func useTerminal(_ target: AXUIElement?) {
    if let target, let terminalElement, CFEqual(target, terminalElement) { return }
    terminalAnchor = nil
    terminalProgress = TerminalInputProgress()
    terminalScreenCount = nil
    terminalElement = target
  }

  private func readTerminalAnchor(
    _ target: AXUIElement, selection: CFRange, captureScreenCount: Bool
  ) -> TerminalLineAnchor? {
    guard let line = integerAttribute(target, .insertionPointLine) else {
      return nil
    }
    var object: CFTypeRef?
    guard
      axResult(
        readAXLineRange(line, from: target, value: &object),
        .contextRangeRead), let object,
      condition(CFGetTypeID(object) == AXValueGetTypeID(), .contextRangeRead, .unexpectedType)
    else { return nil }
    // SAFETY: checked AXValue type and its range payload before using bounds.
    let value = unsafeBitCast(object, to: AXValue.self)
    var lineRange = CFRange(location: -1, length: -1)
    guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &lineRange),
      let insertion = terminalInsertionAnchor(
        selection: selection, lineNumber: line, lineRange: lineRange)
    else {
      condition(false, .contextRangeRead, .invalidRange)
      return nil
    }
    // Ordinary tracking reads insertion metadata only. Replacement additionally
    // samples the numeric screen count; neither path reads the line contents.
    if !captureScreenCount { return insertion }
    guard let count = integerAttribute(target, .characterCount),
      let anchor = terminalLineAnchor(
        selection: selection, characterCount: count, lineNumber: line, lineRange: lineRange)
    else {
      condition(false, .contextRangeRead, .invalidRange)
      return nil
    }
    terminalScreenCount = count
    return anchor
  }

  private func safeElement(_ target: AXUIElement) -> Bool {
    var pid: pid_t = 0
    guard axResult(AXUIElementGetPid(target, &pid), .contextElementIdentity),
      condition(pid > 0 && pid != getpid(), .contextElementIdentity, .rejectedValue)
    else { return false }
    var role: CFTypeRef?
    guard
      axResult(
        readAXMetadata(.role, from: target, value: &role),
        .contextElementRole)
    else { return false }
    guard let role else {
      condition(false, .contextElementRole, .missingValue)
      return false
    }
    guard
      condition(
        CFGetTypeID(role) == CFStringGetTypeID()
          && (CFEqual(role, kAXTextFieldRole as CFString)
            || CFEqual(role, kAXTextAreaRole as CFString)),
        .contextElementRole, .rejectedValue)
    else { return false }
    var subrole: CFTypeRef?
    let subroleError = readAXMetadata(.subrole, from: target, value: &subrole)
    let optionalSubrole = subroleError == .noValue || subroleError == .attributeUnsupported
    let subroleSafe =
      optionalSubrole
      || (subroleError == .success
        && subrole.map {
          CFGetTypeID($0) == CFStringGetTypeID()
            && !CFEqual($0, kAXSecureTextFieldSubrole as CFString)
        } == true)
    guard
      condition(
        subroleSafe, .contextElementSubrole,
        detail: subroleError == .success
          ? RuntimeReason.rejectedValue.rawValue : subroleError.rawValue)
    else { return false }
    for (attribute, stage) in [
      (AXMetadataAttribute.focused, DiagnosticStage.contextFocusedFlag),
      (AXMetadataAttribute.enabled, DiagnosticStage.contextEnabledFlag),
    ] {
      var value: CFTypeRef?
      let error = readAXMetadata(attribute, from: target, value: &value)
      let accepted = contextFlagAccepted(
        attribute: attribute.name, isTextArea: CFEqual(role, kAXTextAreaRole as CFString),
        error: error,
        value: value)
      guard
        condition(
          accepted, stage,
          detail: error == .success ? RuntimeReason.rejectedValue.rawValue : error.rawValue)
      else { return false }
    }
    var protected: CFTypeRef?
    let protectionError = readAXMetadata(.protectedContent, from: target, value: &protected)
    let protectedSafe =
      protectionError == .attributeUnsupported || protectionError == .noValue
      || (protectionError == .success
        && protected.map {
          CFGetTypeID($0) == CFBooleanGetTypeID() && CFEqual($0, kCFBooleanFalse)
        } == true)
    guard
      condition(
        protectedSafe, .contextProtectedContent,
        detail: protectionError == .success
          ? RuntimeReason.rejectedValue.rawValue : protectionError.rawValue)
    else { return false }
    var ranges: CFTypeRef?
    let rangesError = readAXMetadata(.selectedTextRanges, from: target, value: &ranges)
    var rangesSafe = rangesError == .attributeUnsupported || rangesError == .noValue
    if rangesError == .success, let ranges, CFGetTypeID(ranges) == CFArrayGetTypeID() {
      // SAFETY: checked CFArray type; only inspect its count.
      rangesSafe = CFArrayGetCount(unsafeBitCast(ranges, to: CFArray.self)) == 1
    }
    guard
      condition(
        rangesSafe, .contextSelectionCount,
        detail: rangesError == .success
          ? RuntimeReason.rejectedValue.rawValue : rangesError.rawValue)
    else { return false }
    var editable = DarwinBoolean(false)
    let editableError = AXUIElementIsAttributeSettable(
      target, kAXValueAttribute as CFString, &editable)
    if editableError == .success && editable.boolValue {
      useTerminal(nil)
      return true
    }
    if editableError != .success && editableError != .attributeUnsupported
      && editableError != .noValue
    {
      return axResult(editableError, .contextEditable)
    }
    editable = false
    guard
      axResult(
        AXUIElementIsAttributeSettable(target, kAXSelectedTextAttribute as CFString, &editable),
        .contextEditable)
    else { return false }
    let terminal =
      editableError == .success && !editable.boolValue
      && CFEqual(role, kAXTextAreaRole as CFString) && isVerifiedTerminal(pid: pid)
    guard
      condition(
        keyboardContextEditable(hasWritableText: editable.boolValue, isVerifiedTerminal: terminal),
        .contextEditable, .rejectedValue)
    else { return false }
    useTerminal(terminal ? target : nil)
    return true
  }

  func refresh(captureTerminalCount: Bool = true) -> (selection: CFRange, data: Data)? {
    guard condition(runtime.isListening, .contextUnavailable, .notListening),
      condition(
        !runtime.paused.boolValue && runtime.replacementFailure == 0, .contextUnavailable, .paused),
      condition(!runtime.recording.boolValue, .contextUnavailable, .recording),
      condition(runtime.sessionActive.boolValue, .contextUnavailable, .inactiveSession),
      condition(!runtime.sleeping.boolValue, .contextUnavailable, .sleeping),
      condition(AXIsProcessTrusted(), .contextUnavailable, .notTrusted),
      condition(runtime.secureInputOff(), .contextUnavailable, .secureInputUnsafe)
    else {
      reset()
      return nil
    }
    var object: CFTypeRef?
    guard
      axResult(
        readAXMetadata(.focusedElement, from: system, value: &object),
        .contextFocusedElement)
    else { return nil }
    guard let object else {
      condition(false, .contextFocusedElement, .missingValue)
      return nil
    }
    guard
      condition(
        CFGetTypeID(object) == AXUIElementGetTypeID(), .contextFocusedElement, .unexpectedType)
    else {
      reset()
      return nil
    }
    // SAFETY: checked AXUIElement dynamic type. ARC retains it independently.
    let focused = unsafeBitCast(object, to: AXUIElement.self)
    guard axResult(AXUIElementSetMessagingTimeout(focused, 0.025), .contextFocusedElement),
      safeElement(focused),
      let selection = copyRange(focused, captureTerminalCount: captureTerminalCount),
      condition(selection.length == 0, .contextRangeRead, .selectionNotCaret)
    else {
      reset()
      return nil
    }
    let snapshot = runtime.layoutSnapshot.withLock { $0 }
    guard let newLayout = snapshot.layout, let data = snapshot.data else {
      condition(false, .contextLayoutUnsupported, .missingValue)
      reset()
      return nil
    }
    if element == nil || element.map({ !CFEqual($0, focused) }) == true || layout != newLayout {
      let terminal = terminalElement
      let anchor = terminalAnchor
      let screenCount = terminalScreenCount
      let verifiedApplication = terminalApplication
      let progress =
        element.map({ CFEqual($0, focused) }) == true
        ? terminalProgress : TerminalInputProgress()
      reset()
      terminalProgress = progress
      terminalElement = terminal
      terminalAnchor = anchor
      terminalScreenCount = screenCount
      terminalApplication = verifiedApplication
      element = focused
      layout = newLayout
      var pid: pid_t = 0
      if AXUIElementGetPid(focused, &pid) == .success, pid > 0 {
        runtime.observeContext(processIdentifier: pid, element: focused)
      }
    }
    return (selection, data)
  }

  func primeTerminal(generation: UInt64) {
    guard runtime.inputGeneration.value == generation,
      let refreshed = refresh(captureTerminalCount: false), terminalElement != nil,
      runtime.inputGeneration.value == generation
    else { return }
    terminalProgress.prime(caret: refreshed.selection.location)
    if let terminalElement {
      runtime.armTerminalAnchor(element: terminalElement, generation: generation)
    }
  }

  func read(
    _ input: InputMetadata, preInputAnchor: TerminalPreInputSnapshot? = nil
  ) -> ContextSnapshot? {
    if input.kind == .key { candidateConfirmed = false }
    if preInputAnchor != nil { reset() }
    guard let refreshed = refresh(captureTerminalCount: false), let layout else { return nil }
    if let preInputAnchor {
      guard let terminalElement, let terminalAnchor,
        condition(
          CFEqual(terminalElement, preInputAnchor.element), .contextFocusedElement, .focusChanged),
        condition(
          preInputAnchor.anchor.caret >= terminalAnchor.location
            && preInputAnchor.anchor.caret <= refreshed.selection.location,
          .contextCaretChanged, .boundaryUnconfirmed)
      else { return nil }
      terminalProgress.prime(caret: preInputAnchor.anchor.caret)
    }
    if input.kind == .contextChanged {
      guard runtime.inputGeneration.value == input.generation else { return nil }
      if terminalElement != nil { terminalProgress.prime(caret: refreshed.selection.location) }
    }
    if candidateConfirmed
      && !condition(
        refreshed.selection.location == candidateCaret, .contextCaretChanged, .caretChanged)
    {
      reset()
      return nil
    }
    var text: [UInt16] = []
    var translated = true
    if input.kind == .key
      && input.flags
        & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
          | CGEventFlags.maskAlternate.rawValue) == 0
    {
      if let output = KeyboardLayouts.translate(
        data: refreshed.data, keycode: input.keycode,
        flags: input.flags, keyboardType: UInt32(input.keyboardType)), output.count <= 8
      {
        text = output
      } else {
        translated = false
        condition(false, .contextKeyTranslation, .translationLength)
      }
    }
    if input.kind == .key && (input.keycode == 36 || input.keycode == 76) {
      text = [10]
      translated = true
    }
    if terminalElement != nil, input.kind == .key {
      terminalProgress.observe(units: text.count, backspace: input.keycode == 51)
    }
    if translated { DiagnosticLogger.shared.setContextStatus(.contextReady, 0) }
    return ContextSnapshot(focus: focus, layout: layout, text: text)
  }

  func characterCount() -> Int? {
    guard let element,
      let count = integerAttribute(element, .characterCount)
    else { return nil }
    guard terminalElement != nil else { return count }
    guard let selection = copyRange(),
      condition(terminalScreenCount == count, .contextCharacterCount, .characterCountChanged)
    else { return nil }
    // Terminal's AX count includes the screen/scrollback and retained blank
    // cells, not the editable input length. The validated cursor is the end of
    // the current input; preserve the raw count separately for the executor.
    return selection.location
  }

  private func integerAttribute(_ target: AXUIElement, _ attribute: AXMetadataAttribute) -> Int? {
    var object: CFTypeRef?
    guard
      axResult(
        readAXMetadata(attribute, from: target, value: &object),
        .contextCharacterCount)
    else { return nil }
    guard let object else {
      condition(false, .contextCharacterCount, .missingValue)
      return nil
    }
    guard
      condition(CFGetTypeID(object) == CFNumberGetTypeID(), .contextCharacterCount, .unexpectedType)
    else { return nil }
    // SAFETY: checked CFNumber dynamic type; reject fractional/out-of-range values.
    let number = unsafeBitCast(object, to: CFNumber.self)
    var count: Int64 = -1
    guard
      condition(
        CFNumberGetValue(number, .sInt64Type, &count) && count >= 0 && count <= Int64(Int.max),
        .contextCharacterCount, .invalidRange)
    else { return nil }
    return Int(count)
  }

  func replacementRangeAvailable(_ range: CFRange, total: Int) -> Bool {
    condition(
      range.location >= 0 && range.length >= 0 && range.location <= total
        && range.length <= total - range.location
        && (terminalAnchor.map({ range.location >= $0.location }) ?? true),
      .contextRangeRead, .invalidRange)
  }

  func sameFocus(generation: UInt64) -> Bool {
    guard
      condition(
        runtime.inputGeneration.value == generation, .contextUnavailable, .generationChanged),
      condition(runtime.secureInputOff(), .contextUnavailable, .secureInputUnsafe),
      condition(AXIsProcessTrusted(), .contextUnavailable, .notTrusted),
      condition(!runtime.paused.boolValue, .contextUnavailable, .paused), let element
    else { return false }
    var focused: CFTypeRef?
    return axResult(
      readAXMetadata(.focusedElement, from: system, value: &focused),
      .contextFocusedElement) && condition(focused != nil, .contextFocusedElement, .missingValue)
      && condition(
        focused.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, element) } == true,
        .contextFocusedElement, .focusChanged)
      && safeElement(element)
      && condition(
        runtime.inputGeneration.value == generation, .contextUnavailable, .generationChanged)
      && condition(runtime.secureInputOff(), .contextUnavailable, .secureInputUnsafe)
  }

  func confirm(length: Int, focus: UInt64, generation: UInt64) -> Int32 {
    guard condition(focus == self.focus, .contextFocusedElement, .focusChanged),
      condition(length > 0 && length <= 128, .contextRangeRead, .invalidArgument),
      condition(
        runtime.inputGeneration.value == generation, .contextUnavailable, .generationChanged)
    else { return 0 }
    let previouslyConfirmed = candidateConfirmed
    guard let selection = copyRange(),
      condition(selection.length == 0, .contextRangeRead, .selectionNotCaret),
      condition(selection.location >= length, .contextRangeRead, .invalidRange),
      condition(
        terminalElement == nil || terminalProgress.confirms(caret: selection.location),
        .contextCaretChanged, .anchorUnconfirmed),
      condition(
        terminalAnchor.map({ selection.location - length >= $0.location }) ?? true,
        .contextRangeRead, .boundaryUnconfirmed),
      !previouslyConfirmed
        || condition(selection.location == candidateCaret, .contextCaretChanged, .caretChanged)
    else {
      candidateConfirmed = false
      return previouslyConfirmed ? -1 : 0
    }
    candidateConfirmed = sameFocus(generation: generation)
    guard candidateConfirmed else { return previouslyConfirmed ? -1 : 0 }
    candidateCaret = selection.location
    candidateGeneration = generation
    return 1
  }
}
