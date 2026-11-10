import AppKit
import ApplicationServices
import Security

struct TerminalPreInputAnchor {
  let caret: Int
  let generation: UInt64
  let finishedNS: UInt64

  func precedes(_ input: InputMetadata, processedGeneration: UInt64) -> Bool {
    input.kind == .key && !invalidatesKeyTracking(input) && caret >= 0
      && generation == processedGeneration && generation < UInt64.max
      && input.generation == generation + 1 && finishedNS > 0
      && finishedNS < input.timestampNS
  }
}

struct TerminalPreInputSnapshot {
  let element: AXUIElement
  let anchor: TerminalPreInputAnchor
}

struct TerminalAnchorCapture {
  let element: AXUIElement
  let generation: UInt64
  var anchor: TerminalPreInputAnchor?
}

struct TerminalInputProgress {
  private var expectedCaret: Int?
  private var initialCaret: Int?
  private var hasInput = false

  mutating func prime(caret: Int) {
    guard !hasInput, caret >= 0 else { return }
    expectedCaret = caret
    initialCaret = caret
  }

  mutating func observe(units: Int, backspace: Bool) {
    hasInput = true
    guard let expectedCaret, units >= 0, units <= 8 else {
      self.expectedCaret = nil
      return
    }
    if backspace {
      self.expectedCaret =
        initialCaret.map({ expectedCaret > $0 }) == true ? expectedCaret - 1 : nil
    } else {
      self.expectedCaret = units <= Int.max - expectedCaret ? expectedCaret + units : nil
    }
  }

  func confirms(caret: Int) -> Bool {
    hasInput && expectedCaret == caret
  }
}

struct TerminalLineAnchor: Equatable {
  let number: Int
  let location: Int
}

func terminalInsertionAnchor(
  selection: CFRange, lineNumber: Int, lineRange: CFRange
) -> TerminalLineAnchor? {
  guard selection.location >= 0, selection.length == 0, lineNumber >= 0,
    lineRange.location >= 0, lineRange.length >= 0,
    selection.location >= lineRange.location,
    selection.location - lineRange.location <= lineRange.length
  else { return nil }
  return TerminalLineAnchor(number: lineNumber, location: lineRange.location)
}

func terminalLineAnchor(
  selection: CFRange, characterCount: Int, lineNumber: Int, lineRange: CFRange
) -> TerminalLineAnchor? {
  guard
    let anchor = terminalInsertionAnchor(
      selection: selection, lineNumber: lineNumber, lineRange: lineRange),
    characterCount >= 0, selection.location <= characterCount,
    lineRange.location <= characterCount,
    lineRange.length <= characterCount - lineRange.location
  else { return nil }
  return anchor
}

func terminalScreenCountMatches(actual: Int?, original: Int?, removed: Int) -> Bool {
  guard let original else { return actual == nil }
  guard let actual, original >= 0, removed >= 0, removed <= original else { return false }
  // Terminal can retain erased cells as spaces or trim them from its AX text.
  // Other screen-size changes are not treated as our deletion.
  return actual == original || actual == original - removed
}

func verifiedAppleTerminal(pid: pid_t) -> NSRunningApplication? {
  guard pid > 0, let application = NSRunningApplication(processIdentifier: pid),
    !application.isTerminated, application.bundleIdentifier == "com.apple.Terminal"
  else { return nil }
  var code: SecCode?
  let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
  guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
    let code
  else { return nil }
  var requirement: SecRequirement?
  guard
    SecRequirementCreateWithString(
      "anchor apple and identifier \"com.apple.Terminal\"" as CFString, [], &requirement
    ) == errSecSuccess, let requirement,
    SecCodeCheckValidity(code, [], requirement) == errSecSuccess
  else { return nil }
  return application
}
