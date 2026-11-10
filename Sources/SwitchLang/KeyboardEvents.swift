import CoreGraphics
import Foundation

// Error values are consumed by the runtime's fixed numeric diagnostics.
enum KeyboardPlanError: Int32, Error {
  case invalid = 1
  case unsupported = 2
  case allocation = 3
}

// The injection boundary exercises fallible CoreGraphics allocation without
// global hooks. Production always uses the public private-source factories.
struct KeyboardEventAllocation {
  var source: () -> CGEventSource? = { CGEventSource(stateID: .privateState) }
  var event: (CGEventSource, UInt16, Bool) -> CGEvent? = {
    CGEvent(keyboardEventSource: $0, virtualKey: $1, keyDown: $2)
  }
}

final class KeyboardEventPlan {
  let events: [CGEvent]
  let deletionEnd: Int
  // Keep the private state table alive independently of CGEvent ownership.
  let source: CGEventSource
  static let eventTag: Int64 = 0x534c_4b45_5950_4c4e
  static let capacity = 768

  private static let englishKeys = Array(
    "\\qwertyuiop[]asdfghjkl;'zxcvbnm,.|QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>".utf16)
  private static let russianKeys = Array(
    "ёйцукенгшщзхъфывапролджэячсмитьбюЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ".utf16)

  private struct Stroke {
    let character: UInt16
    let keycode: UInt16
    let shifted: Bool
  }

  convenience init(
    original: [UInt16], replacement: [UInt16], layoutData: Data, keyboardType: UInt32
  ) throws {
    try self.init(
      original: original, replacement: replacement, layoutData: layoutData,
      keyboardType: keyboardType, allocation: KeyboardEventAllocation())
  }

  init(
    original: [UInt16], replacement: [UInt16], layoutData: Data, keyboardType: UInt32,
    allocation: KeyboardEventAllocation
  ) throws {
    guard Self.validPair(original, replacement) else { throw KeyboardPlanError.invalid }
    let layout = try ValidatedKeyboardLayout(data: layoutData, keyboardType: keyboardType)
    var mappings: [Stroke] = []
    mappings.reserveCapacity(102)
    // Prefer unshifted keys when multiple physical keys produce an output.
    for shifted in [false, true] {
      for keycode: UInt16 in 0...50 where keycode != 10 && keycode != 36 && keycode != 48 {
        guard
          let text = layout.translate(
            keycode: keycode, modifiers: shifted ? 2 : 0,
            capacity: 1), text.count == 1,
          Self.singletonPrintable(text[0])
        else { continue }
        mappings.append(Stroke(character: text[0], keycode: keycode, shifted: shifted))
      }
    }
    var strokes: [Stroke] = []
    strokes.reserveCapacity(replacement.count)
    for character in replacement {
      guard let stroke = mappings.first(where: { $0.character == character }) else {
        throw KeyboardPlanError.unsupported
      }
      strokes.append(stroke)
    }
    // Validate the WHOLE replacement before creating even one deletion
    // event. ARC releases every partial event and source if allocation fails.
    guard let source = allocation.source() else { throw KeyboardPlanError.allocation }
    source.keyboardType = keyboardType
    source.userData = Self.eventTag
    source.localEventsSuppressionInterval = 0
    // Filter masks PERMIT hardware input; an empty mask would suppress it.
    let permitAll: CGEventFilterMask = [
      .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents,
    ]
    source.setLocalEventsFilterDuringSuppressionState(
      permitAll, state: .eventSuppressionStateSuppressionInterval)
    source.setLocalEventsFilterDuringSuppressionState(
      permitAll, state: .eventSuppressionStateRemoteMouseDrag)
    var events: [CGEvent] = []
    events.reserveCapacity(min(Self.capacity, original.count * 6))
    func append(_ keycode: UInt16, down: Bool, shifted: Bool) throws {
      guard events.count < Self.capacity, let event = allocation.event(source, keycode, down) else {
        throw KeyboardPlanError.allocation
      }
      event.flags = shifted ? .maskShift : []
      if keycode == 56 { event.type = .flagsChanged }
      event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
      event.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(keyboardType))
      event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
      events.append(event)
    }
    for _ in original {
      try append(51, down: true, shifted: false)
      try append(51, down: false, shifted: false)
    }
    deletionEnd = events.count
    var shiftDown = false
    for stroke in strokes {
      if stroke.shifted != shiftDown {
        shiftDown = stroke.shifted
        try append(56, down: shiftDown, shifted: shiftDown)
      }
      try append(stroke.keycode, down: true, shifted: shiftDown)
      try append(stroke.keycode, down: false, shifted: shiftDown)
    }
    if shiftDown { try append(56, down: false, shifted: false) }
    self.events = events
    self.source = source
  }

  private static func alphabet(_ character: UInt16) -> Int {
    if (65...90).contains(character) || (97...122).contains(character) { return 1 }
    if (0x410...0x44f).contains(character) || character == 0x401 || character == 0x451 { return 2 }
    return 0
  }

  private static func delimiter(_ character: UInt16) -> Bool {
    character == 32 || (33...47).contains(character) || (58...64).contains(character)
      || (91...96).contains(character) || (123...126).contains(character)
  }

  private static func singletonPrintable(_ character: UInt16) -> Bool {
    alphabet(character) != 0 || (32...126).contains(character)
  }

  private static func validPair(_ original: [UInt16], _ replacement: [UInt16]) -> Bool {
    guard !original.isEmpty, original.count <= 128, original.count == replacement.count else {
      return false
    }
    let sourceAlphabet = alphabet(original[0])
    guard sourceAlphabet != 0 else { return false }
    let wordLength = original.prefix(while: { alphabet($0) == sourceAlphabet }).count
    guard wordLength <= 64, original.count - wordLength <= 16 else { return false }
    let sourceKeys = sourceAlphabet == 1 ? englishKeys : russianKeys
    let targetKeys = sourceAlphabet == 1 ? russianKeys : englishKeys
    for index in 0..<wordLength {
      guard let pair = sourceKeys.firstIndex(of: original[index]),
        targetKeys[pair] == replacement[index]
      else { return false }
    }
    for index in wordLength..<original.count {
      guard delimiter(original[index]), original[index] == replacement[index] else { return false }
    }
    return true
  }
}

// Production supplies posting to the verified PID; tests observe this exact
// loop. Cancellation never strands our key-down or our explicit Shift-down.
func emitKeyboardRange(
  _ plan: KeyboardEventPlan, begin: Int, end: Int,
  post: (CGEvent) -> Void, mayContinue: () -> Bool
) -> Bool {
  guard begin >= 0, begin <= end, end <= plan.events.count,
    plan.events.count <= KeyboardEventPlan.capacity,
    plan.deletionEnd <= plan.events.count
  else { return false }
  // Reject a split pair/Shift run before posting anything. Runtime uses the
  // two complete phases, but malformed caller ranges must not strand Shift.
  var validationIndex = begin
  var validationShift = false
  while validationIndex < end {
    let event = plan.events[validationIndex]
    if event.type == .flagsChanged {
      validationShift = event.flags.contains(.maskShift)
    } else {
      guard event.type == .keyDown, event.flags.contains(.maskShift) == validationShift,
        validationIndex + 1 < end
      else { return false }
      let up = plan.events[validationIndex + 1]
      guard up.type == .keyUp, up.flags == event.flags,
        up.getIntegerValueField(.keyboardEventKeycode)
          == event.getIntegerValueField(.keyboardEventKeycode)
      else { return false }
      validationIndex += 1
    }
    validationIndex += 1
  }
  guard !validationShift else { return false }
  var shiftDown = false
  let shiftUp = plan.events[plan.deletionEnd...].last {
    $0.type == .flagsChanged && !$0.flags.contains(.maskShift)
  }
  var index = begin
  while index < end {
    guard mayContinue() else {
      if shiftDown, let shiftUp { post(shiftUp) }
      return false
    }
    let event = plan.events[index]
    if event.type == .keyDown {
      guard index + 1 < end, plan.events[index + 1].type == .keyUp,
        event.getIntegerValueField(.keyboardEventKeycode)
          == plan.events[index + 1].getIntegerValueField(.keyboardEventKeycode)
      else { return false }
    }
    post(event)
    if event.type == .flagsChanged {
      shiftDown = event.flags.contains(.maskShift)
    } else if event.type == .keyDown {
      index += 1
      post(plan.events[index])
    }
    index += 1
  }
  return true
}
