import CoreGraphics

func runCapsLockTests() throws -> Int {
  var tests = 0
  // Initially off/on, read/set/verification failures, and a setter that
  // reports success without changing state. No test opens real IOKit.
  for scenario in 0..<6 {
    var locked = scenario != 0
    var reads = 0
    var sets = 0
    var closes = 0
    do {
      let controller = CapsLockController(
        read: {
          reads += 1
          if scenario == 2 || (scenario == 4 && reads > 1) { return nil }
          return locked
        },
        set: {
          sets += 1
          if scenario == 3 { return false }
          if scenario != 5 { locked = false }
          return true
        }, close: { closes += 1 })
      let result = controller.reset()
      try requireTest(
        result.success == (scenario < 2) && result.wasLocked == (scenario == 1),
        "Caps transition classification \(scenario)")
      try requireTest(
        sets == ((scenario != 0 && scenario != 2) ? 1 : 0)
          && reads == ([0, 2, 3].contains(scenario) ? 1 : 2), "Caps operation counts \(scenario)")
      if scenario == 1 {
        let released = controller.reset()
        try requireTest(
          released.success && !released.wasLocked && sets == 1,
          "Caps off notification is not another command")
        locked = true
        let pressedAgain = controller.reset()
        try requireTest(
          pressedAgain.success && pressedAgain.wasLocked && sets == 2,
          "Caps next activation is a new transition")
      }
      try requireTest(closes == 0, "Caps connection retained during use")
    }
    try requireTest(closes == 1, "Caps connection closed exactly once")
    tests += 1
  }
  guard let source = CGEventSource(stateID: .privateState),
    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
  else {
    throw TestFailure(description: "Caps normalization event allocation")
  }
  let modifiers: CGEventFlags = [
    .maskShift, .maskControl, .maskAlternate, .maskCommand,
    .maskSecondaryFn, .maskHelp, .maskNumericPad,
  ]
  event.flags = modifiers.union(.maskAlphaShift)
  event.timestamp = 1234
  event.setIntegerValueField(.eventSourceUserData, value: 9876)
  CapsLockController.normalize(event)
  try requireTest(
    event.flags == modifiers && event.timestamp == 1234 && event.type == .keyDown
      && event.getIntegerValueField(.keyboardEventKeycode) == 0
      && event.getIntegerValueField(.eventSourceUserData) == 9876,
    "Caps normalization changes only alphaShift")
  CapsLockController.normalize(event)
  try requireTest(event.flags == modifiers, "Caps normalization is idempotent")
  event.flags = .maskAlphaShift
  CapsLockController.normalize(event)
  try requireTest(event.flags.isEmpty, "Caps normalization removes lone flag")
  return tests + 3
}
