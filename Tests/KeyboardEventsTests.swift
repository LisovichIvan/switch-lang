import Carbon
import CoreGraphics
import Foundation

// A minimal real uchr resource: tests exercise public UCKeyTranslate, not a
// mocked translator, without TIS access, permissions or posting events.
private struct KeyboardFixture {
  static let modifiers = 40
  static let index = 52
  static let outputs = 68
  static let states = 580
  static let record = 588
  static let sequences = 596
  static let length = 612
  static let english = Array(
    "\\qwertyuiop[]asdfghjkl;'zxcvbnm,.|QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>".utf16)
  static let russian = Array(
    "ёйцукенгшщзхъфывапролджэячсмитьбюЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ".utf16)
  static let keycodes: [UInt16] = [
    42, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30,
    0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 6, 7, 8, 9, 11, 45, 46, 43, 47,
  ]
  var data = Data(repeating: 0, count: length)

  init(russian: Bool) {
    put16(0, 0x1002)
    put16(2, 0x0100)
    put32(8, 1)
    put32(20, Self.modifiers)
    put32(24, Self.index)
    put16(Self.modifiers, 0x3001)
    put32(Self.modifiers + 4, 4)
    data[Self.modifiers + 10] = 1
    data[Self.modifiers + 11] = 1
    put16(Self.index, 0x4001)
    put16(Self.index + 2, 128)
    put32(Self.index + 4, 2)
    put32(Self.index + 8, Self.outputs)
    put32(Self.index + 12, Self.outputs + 256)
    for shifted in 0...1 {
      for keycode in 0..<128 { output(shifted, keycode, 0xffff) }
      output(shifted, 36, 13)
      output(shifted, 48, 9)
      output(shifted, 49, 32)
      output(shifted, 18, shifted == 0 ? 49 : 33)
      output(shifted, 44, shifted == 0 ? 47 : 63)
      output(shifted, 50, shifted == 0 ? 96 : 126)
    }
    for index in 0..<66 {
      output(
        index / 33, Int(Self.keycodes[index % 33]),
        russian ? Self.russian[index] : Self.english[index])
    }
    if russian {
      output(0, 44, 46)
      output(1, 44, 44)
      output(1, 26, 63)
    }
  }

  mutating func put16(_ offset: Int, _ value: UInt16) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
  }
  mutating func put32(_ offset: Int, _ value: Int) {
    put16(offset, UInt16(truncatingIfNeeded: value))
    put16(offset + 2, UInt16(truncatingIfNeeded: value >> 16))
  }
  mutating func output(_ shifted: Int, _ keycode: Int, _ character: UInt16) {
    put16(Self.outputs + shifted * 256 + keycode * 2, character)
  }
  mutating func indirect() {
    output(0, 14, 0x4000)
    put32(28, Self.states)
    put16(Self.states, 0x5001)
    put16(Self.states + 2, 1)
    put32(Self.states + 4, Self.record)
    put16(Self.record, 101)
    put16(Self.record + 6, 1)
    put32(36, Self.sequences)
    put16(Self.sequences, 0x7001)
    put16(Self.sequences + 2, 2)
    put16(Self.sequences + 4, 10)
    put16(Self.sequences + 6, 12)
    put16(Self.sequences + 8, 16)
    put16(Self.sequences + 10, 101)
    put16(Self.sequences + 12, 101)
    put16(Self.sequences + 14, 0x308)
  }
}

private func requireKeyboardError(
  _ original: [UInt16], _ replacement: [UInt16], _ data: Data,
  _ expected: KeyboardPlanError, _ name: String
) throws {
  do {
    _ = try KeyboardEventPlan(
      original: original, replacement: replacement, layoutData: data, keyboardType: 40)
    throw TestFailure(description: "\(name): unexpected plan")
  } catch let error as KeyboardPlanError {
    try requireTest(error == expected, "\(name): wrong error \(error)")
  }
}

private func requireKeyboardSequence(_ plan: KeyboardEventPlan, _ keys: [UInt16], _ shifts: [Bool])
  throws
{
  try requireTest(
    keys.count == shifts.count && plan.events.count <= 768 && plan.deletionEnd == keys.count * 2,
    "plan bounds and deletion length")
  var expected: [(UInt16, CGEventType, Bool)] = []
  for _ in keys { expected += [(51, .keyDown, false), (51, .keyUp, false)] }
  var shifted = false
  for index in keys.indices {
    if shifts[index] != shifted {
      shifted = shifts[index]
      expected.append((56, .flagsChanged, shifted))
    }
    expected += [(keys[index], .keyDown, shifted), (keys[index], .keyUp, shifted)]
  }
  if shifted { expected.append((56, .flagsChanged, false)) }
  try requireTest(plan.events.count == expected.count, "event count")
  for (event, stroke) in zip(plan.events, expected) {
    let state = event.getIntegerValueField(.eventSourceStateID)
    try requireTest(
      state != Int64(CGEventSourceStateID.combinedSessionState.rawValue)
        && state != Int64(CGEventSourceStateID.hidSystemState.rawValue), "private event source")
    try requireTest(
      event.type == stroke.1 && event.getIntegerValueField(.keyboardEventKeycode) == Int64(stroke.0)
        && event.flags == (stroke.2 ? .maskShift : [])
        && event.getIntegerValueField(.eventSourceUserData) == KeyboardEventPlan.eventTag
        && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        && event.getIntegerValueField(.keyboardEventKeyboardType) == 40,
      "physical event metadata/order")
  }
}

private final class KeyboardWeakEvent {
  weak var value: CGEvent?
  init(_ value: CGEvent) { self.value = value }
}
private final class KeyboardWeakSource {
  weak var value: CGEventSource?
  init(_ value: CGEventSource) { self.value = value }
}

func runKeyboardEventsTests() throws -> Int {
  let english = KeyboardFixture(russian: false).data
  let russian = KeyboardFixture(russian: true).data
  var tests = 0
  func sequence(
    _ original: String, _ replacement: String, _ data: Data, _ keys: [UInt16], _ shifts: [Bool]
  ) throws {
    let plan = try KeyboardEventPlan(
      original: Array(original.utf16), replacement: Array(replacement.utf16),
      layoutData: data, keyboardType: 40)
    try requireKeyboardSequence(plan, keys, shifts)
    tests += 1
  }
  try sequence(
    "gHbDtN!? ", "пРиВеТ!? ", russian, [5, 4, 11, 2, 17, 45, 18, 26, 49],
    [false, true, false, true, false, true, true, true, false])
  try sequence(
    "ЁжЪэБю, ", "|;}'<., ", english, [42, 41, 30, 39, 43, 47, 43, 49],
    [true, false, true, false, true, false, false, false])
  for index in 0..<66 {
    let original = [KeyboardFixture.russian[index]]
    let replacement = [KeyboardFixture.english[index]]
    let plan = try KeyboardEventPlan(
      original: original, replacement: replacement, layoutData: english, keyboardType: 40)
    try requireKeyboardSequence(plan, [KeyboardFixture.keycodes[index % 33]], [index >= 33])
    if (65...90).contains(replacement[0]) || (97...122).contains(replacement[0]) {
      let inverse = try KeyboardEventPlan(
        original: replacement, replacement: original, layoutData: russian, keyboardType: 40)
      try requireKeyboardSequence(inverse, [KeyboardFixture.keycodes[index % 33]], [index >= 33])
    } else {
      try requireKeyboardError(
        replacement, original, russian, .invalid, "punctuation is not original word")
    }
    tests += 2
  }
  let invalidPairs = [
    ("", ""), ("f", ""), ("f", "А"), ("f", "f"), ("я", "я"), ("fя", "ая"),
    ("яf", "zf"), (" f", " а"), ("f a", "а ф"), ("f1", "а1"), ("f!", "а?"), ("f", "ё"), ("[", "х"),
    ("é", "а"),
  ]
  for pair in invalidPairs {
    try requireKeyboardError(
      Array(pair.0.utf16), Array(pair.1.utf16), russian, .invalid, "invalid text pair")
    tests += 1
  }
  let unsupportedUnits: [UInt16] =
    Array(0..<32) + [
      0x7f, 0x85, 0xa0, 0x308, 0x200d, 0x202e, 0x456,
      0xd800, 0xdc00, 0xdfff, 0xfe0f,
    ]
  for unit in unsupportedUnits {
    try requireKeyboardError([102, unit], [0x430, unit], russian, .invalid, "invalid suffix")
    try requireKeyboardError([102, 33], [0x430, unit], russian, .invalid, "invalid target suffix")
    try requireKeyboardError([unit], [0x430], russian, .invalid, "invalid original singleton")
    try requireKeyboardError([102], [unit], russian, .invalid, "invalid target singleton")
    tests += 4
  }
  let alternating = String(repeating: "Ff", count: 32)
  let converted = String(repeating: "Аа", count: 32)
  let keys = [UInt16](repeating: 3, count: 64)
  let shifts = (0..<64).map { $0 % 2 == 0 }
  try sequence(alternating, converted, russian, keys, shifts)
  try sequence(
    alternating + String(repeating: " ", count: 16), converted + String(repeating: " ", count: 16),
    russian, keys + [UInt16](repeating: 49, count: 16), shifts + [Bool](repeating: false, count: 16)
  )
  try sequence(
    "f" + String(repeating: " ", count: 16), "а" + String(repeating: " ", count: 16), russian,
    [3] + [UInt16](repeating: 49, count: 16), [Bool](repeating: false, count: 17))
  for length in [65, 129] {
    try requireKeyboardError(
      [UInt16](repeating: 102, count: length), [UInt16](repeating: 0x430, count: length),
      russian, .invalid, "word length")
    tests += 1
  }
  for suffix in [17, 64] {
    try requireKeyboardError(
      Array((alternating + String(repeating: " ", count: suffix)).utf16),
      Array((converted + String(repeating: " ", count: suffix)).utf16), russian, .invalid,
      "suffix length")
    tests += 1
  }
  for delimiter in " !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".utf16 {
    var fixture = KeyboardFixture(russian: true)
    fixture.output(0, 19, delimiter)
    let plan = try KeyboardEventPlan(
      original: [102, delimiter], replacement: [0x430, delimiter],
      layoutData: fixture.data, keyboardType: 40)
    try requireKeyboardSequence(plan, [3, 19], [false, false])
    tests += 1
  }
  for scenario in 0..<15 {
    var fixture = KeyboardFixture(russian: true)
    switch scenario {
    case 0: fixture.data = Data()
    case 1: fixture.data = Data(fixture.data.prefix(39))
    case 2: fixture.put16(0, 0)
    case 3: fixture.put32(8, Int(UInt32.max))
    case 4: fixture.put32(20, Int(UInt32.max))
    case 5: fixture.put32(KeyboardFixture.modifiers + 4, Int(UInt32.max))
    case 6: fixture.put32(KeyboardFixture.index + 4, Int(UInt32.max))
    case 7: fixture.put32(KeyboardFixture.index + 8, KeyboardFixture.length)
    case 8: fixture.data[KeyboardFixture.modifiers + 10] = 2
    case 9: fixture.put32(KeyboardFixture.index + 12, KeyboardFixture.outputs + 257)
    case 10: fixture.output(0, 3, 0xffff)
    case 11:
      fixture.output(0, 3, 13)
      fixture.output(0, 36, 0x430)
    case 12:
      fixture.output(0, 3, 0x4000)
      fixture.output(0, 48, 0x430)
    case 13:
      fixture.output(0, 3, 0xd800)
      fixture.output(0, 10, 0x430)
    default:
      fixture.output(0, 3, 0x308)
      fixture.output(0, 51, 0x430)
    }
    var allocations = 0
    let allocation = KeyboardEventAllocation(
      source: {
        allocations += 1
        return CGEventSource(stateID: .privateState)
      },
      event: { source, keycode, down in
        allocations += 1
        return CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: down)
      })
    do {
      _ = try KeyboardEventPlan(
        original: Array((scenario == 14 ? "gHbDtNf" : "f").utf16),
        replacement: Array((scenario == 14 ? "пРиВеТа" : "а").utf16), layoutData: fixture.data,
        keyboardType: 40, allocation: allocation)
      throw TestFailure(description: "malformed/unsupported table accepted")
    } catch let error as KeyboardPlanError {
      try requireTest(
        error == (scenario < 10 ? .invalid : .unsupported) && allocations == 0,
        "prevalidate entire target before event/source allocation")
    }
    tests += 1
  }
  for scenario in 0..<15 {
    var fixture = KeyboardFixture(russian: false)
    fixture.indirect()
    switch scenario {
    case 0: break
    case 1: fixture.put16(KeyboardFixture.record + 2, 1)
    case 2: fixture.output(0, 14, 0x8000)
    case 3: fixture.put16(KeyboardFixture.record, 0x8000)
    case 4: fixture.output(0, 14, 0x8001)
    case 5: fixture.put16(KeyboardFixture.record, 0x8001)
    case 6: fixture.put16(KeyboardFixture.record, 13)
    case 7: fixture.put16(KeyboardFixture.record, 0xd800)
    case 8: fixture.put16(KeyboardFixture.sequences + 8, UInt16.max)
    case 9: fixture.put32(KeyboardFixture.states + 4, Int(UInt32.max))
    case 10:
      fixture.put16(KeyboardFixture.record + 4, 1)
      fixture.put16(KeyboardFixture.record + 6, 0)
    case 11: fixture.put32(32, Int(UInt32.max))
    case 12: fixture.put16(KeyboardFixture.sequences + 2, UInt16.max)
    case 13: fixture.put16(KeyboardFixture.sequences + 6, 8)
    default: fixture.put16(KeyboardFixture.states + 2, UInt16.max)
    }
    if scenario < 4 {
      try sequence("у", "e", fixture.data, [14], [false])
    } else {
      try requireKeyboardError(
        Array("у".utf16), [101], fixture.data, scenario < 8 ? .unsupported : .invalid,
        "indirect output")
      tests += 1
    }
  }
  // Every truncated extent of an indirect resource must be rejected before
  // the unchecked-length C API is entered, including nested sequence bytes.
  var complete = KeyboardFixture(russian: false)
  complete.indirect()
  for length in 0..<complete.data.count {
    try requireKeyboardError(
      Array("у".utf16), [101], Data(complete.data.prefix(length)), .invalid,
      "truncated resource at \(length)")
    tests += 1
  }
  var prefixed = Data([0])
  prefixed.append(russian)
  let sliced = prefixed.dropFirst()
  let slicedPlan = try KeyboardEventPlan(
    original: [102], replacement: [0x430], layoutData: sliced, keyboardType: 40)
  try requireKeyboardSequence(slicedPlan, [3], [false])
  tests += 1
  var data = russian
  var original: [UInt16] = [102, 33]
  var replacement: [UInt16] = [0x430, 33]
  let immutable = try KeyboardEventPlan(
    original: original, replacement: replacement, layoutData: data, keyboardType: 40)
  try requireTest(
    original == [102, 33] && replacement == [0x430, 33] && data == russian, "input immutability")
  data.resetBytes(in: 0..<data.count)
  original[0] = 13
  replacement[0] = 9
  try requireKeyboardSequence(immutable, [3, 18], [false, true])
  try requireTest(
    immutable.source.userData == KeyboardEventPlan.eventTag
      && immutable.source.localEventsSuppressionInterval == 0,
    "private source metadata")
  let permitted: CGEventFilterMask = [
    .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents,
  ]
  try requireTest(
    immutable.source.getLocalEventsFilterDuringSuppressionState(
      .eventSuppressionStateSuppressionInterval) == permitted
      && immutable.source.getLocalEventsFilterDuringSuppressionState(
        .eventSuppressionStateRemoteMouseDrag) == permitted,
    "never suppress physical input")
  tests += 2

  // Every source/event allocation can fail. Weak observations prove that ARC
  // releases all partial allocations without retaining a global test probe.
  let sample = try KeyboardEventPlan(
    original: Array("gHbDtN!? ".utf16), replacement: Array("пРиВеТ!? ".utf16),
    layoutData: russian, keyboardType: 40)
  for failAt in 0...(sample.events.count + 1) {
    var allocations = 0
    var events: [KeyboardWeakEvent] = []
    var source: KeyboardWeakSource?
    let allocation = KeyboardEventAllocation(
      source: {
        defer { allocations += 1 }
        guard allocations != failAt, let created = CGEventSource(stateID: .privateState) else {
          return nil
        }
        source = KeyboardWeakSource(created)
        return created
      },
      event: { source, keycode, down in
        defer { allocations += 1 }
        guard allocations != failAt,
          let created = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: down)
        else { return nil }
        events.append(KeyboardWeakEvent(created))
        return created
      })
    do {
      let plan = try KeyboardEventPlan(
        original: Array("gHbDtN!? ".utf16), replacement: Array("пРиВеТ!? ".utf16),
        layoutData: russian, keyboardType: 40, allocation: allocation)
      try requireTest(
        failAt == sample.events.count + 1 && plan.events.count == sample.events.count,
        "complete allocation sequence")
    } catch let error as KeyboardPlanError {
      try requireTest(
        error == .allocation && allocations == failAt + 1, "allocation failure classification")
    }
    try requireTest(
      events.allSatisfy { $0.value == nil } && source?.value == nil, "partial allocation cleanup")
    tests += 1
  }
  // Each possible interruption includes cancellation immediately after a
  // key-down. Its key-up is unconditional; active Shift gets exactly one up.
  for (begin, end) in [
    (0, sample.events.count), (0, sample.deletionEnd), (sample.deletionEnd, sample.events.count),
  ] {
    let range = Array(sample.events[begin..<end])
    for cutoff in 0...range.count {
      var trace: [CGEvent] = []
      let emitted = emitKeyboardRange(
        sample, begin: begin, end: end, post: { trace.append($0) },
        mayContinue: { trace.count < cutoff })
      var expected: [CGEvent] = []
      var index = 0
      var shifted = false
      while index < range.count && expected.count < cutoff {
        let event = range[index]
        expected.append(event)
        if event.type == .keyDown {
          index += 1
          expected.append(range[index])
        } else if event.type == .flagsChanged {
          shifted = event.flags.contains(.maskShift)
        }
        index += 1
      }
      let completed = index == range.count
      if !completed && shifted,
        let up = sample.events.last(where: {
          $0.type == .flagsChanged && !$0.flags.contains(.maskShift)
        })
      {
        expected.append(up)
      }
      try requireTest(
        emitted == completed && trace.count == expected.count
          && zip(trace, expected).allSatisfy { $0 === $1 },
        "cancellation preserves down/up and Shift cleanup")
      tests += 1
    }
  }
  for (begin, end) in [
    (-1, 0), (1, 0), (0, 1), (0, sample.events.count + 1),
    (sample.deletionEnd, sample.deletionEnd + 3), (sample.deletionEnd, sample.deletionEnd + 4),
    (sample.deletionEnd + 4, sample.events.count),
  ] {
    var posts = 0
    try requireTest(
      !emitKeyboardRange(
        sample, begin: begin, end: end, post: { _ in posts += 1 }, mayContinue: { true })
        && posts == 0,
      "invalid range posts nothing")
    tests += 1
  }
  try requireTest(
    emitKeyboardRange(sample, begin: 0, end: 0, post: { _ in }, mayContinue: { false }),
    "empty range")
  try requireTest(
    KeyboardLayouts.translate(data: russian, keycode: 3, flags: 0, keyboardType: 40) == [0x430]
      && KeyboardLayouts.translate(
        data: russian, keycode: 3, flags: CGEventFlags.maskShift.rawValue, keyboardType: 40) == [
          0x410
        ]
      && KeyboardLayouts.translate(
        data: russian, keycode: 3, flags: CGEventFlags.maskAlternate.rawValue, keyboardType: 40)
        == nil
      && KeyboardLayouts.translate(data: Data(), keycode: 3, flags: 0, keyboardType: 40) == nil,
    "validated context translation")
  return tests + 2
}
