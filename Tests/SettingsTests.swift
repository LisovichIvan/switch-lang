import AppKit
import Carbon
import Foundation

// Synthetic property-list values and injected closures only: no application,
// defaults, permission requests/checks, event taps, or posted keyboard events.
func runSettingsTests() throws -> Int {
  var assertions = 0
  func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    try requireTest(condition(), name)
    assertions += 1
  }

  let initial = ApplicationSettings()
  let command = UInt64(NSEvent.ModifierFlags.command.rawValue)
  let control = UInt64(NSEvent.ModifierFlags.control.rawValue)
  let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
  let shift = UInt64(NSEvent.ModifierFlags.shift.rawValue)
  let caps = UInt16(kVK_CapsLock)
  let letter = UInt16(kVK_ANSI_A)
  let sentinel = ApplicationSettings(automatic: true, bound: true, keycode: 12, modifiers: command)

  try check(parseSettings(nil) == initial, "settings: absent domain is manual and unbound")
  try check(parseSettings([:]) == initial, "settings: empty domain is manual and unbound")
  let bound: [String: Any] = [
    SettingsKey.automatic: true, SettingsKey.hotkeyCode: NSNumber(value: 0),
    SettingsKey.hotkeyModifiers: NSNumber(value: allowedHotkeyModifiers),
  ]
  try check(
    parseSettings(bound)
      == ApplicationSettings(
        automatic: true, bound: true, keycode: 0,
        modifiers: allowedHotkeyModifiers),
    "settings: all supported modifiers and physical code zero")
  try check(
    parseSettings([SettingsKey.hotkeyCode: NSNumber(value: 127)])
      == ApplicationSettings(automatic: false, bound: true, keycode: 127, modifiers: 0),
    "settings: maximum supported code and missing mode/modifiers")
  try check(
    parseSettings([SettingsKey.automatic: false, SettingsKey.hotkeyModifiers: NSNumber(value: 0)])
      == initial,
    "settings: explicit manual and zero modifiers without binding")
  let invalidSettings: [Any] = [
    "not a dictionary",
    [SettingsKey.automatic: "true"], [SettingsKey.automatic: NSNumber(value: 1)],
    [SettingsKey.automatic: NSNumber(value: 2)], [SettingsKey.automatic: NSNull()],
    [SettingsKey.hotkeyCode: true], [SettingsKey.hotkeyCode: "12"],
    [SettingsKey.hotkeyCode: NSNumber(value: 1.5)], [SettingsKey.hotkeyCode: NSNumber(value: 1.0)],
    [SettingsKey.hotkeyCode: NSNumber(value: -1)], [SettingsKey.hotkeyCode: NSNumber(value: 128)],
    [SettingsKey.hotkeyCode: NSNumber(value: UInt64.max)],
    [SettingsKey.hotkeyCode: NSNumber(value: kVK_Shift)],
    [SettingsKey.hotkeyCode: NSNumber(value: 0), SettingsKey.hotkeyModifiers: true],
    [SettingsKey.hotkeyCode: NSNumber(value: 0), SettingsKey.hotkeyModifiers: "0"],
    [
      SettingsKey.hotkeyCode: NSNumber(value: 0), SettingsKey.hotkeyModifiers: NSNumber(value: 0.5),
    ],
    [SettingsKey.hotkeyCode: NSNumber(value: 0), SettingsKey.hotkeyModifiers: NSNumber(value: -1)],
    [
      SettingsKey.hotkeyCode: NSNumber(value: 0),
      SettingsKey.hotkeyModifiers: NSNumber(value: NSEvent.ModifierFlags.capsLock.rawValue),
    ],
    [
      SettingsKey.hotkeyCode: NSNumber(value: 0),
      SettingsKey.hotkeyModifiers: NSNumber(value: NSEvent.ModifierFlags.function.rawValue),
    ],
    [
      SettingsKey.hotkeyCode: NSNumber(value: 0),
      SettingsKey.hotkeyModifiers: NSNumber(value: UInt64.max),
    ],
    [SettingsKey.hotkeyModifiers: NSNumber(value: command)],
  ]
  for (index, values) in invalidSettings.enumerated() {
    var retained = sentinel
    if let parsed = parseSettings(values) { retained = parsed }
    try check(
      parseSettings(values) == nil && retained == sentinel,
      "settings: reject invalid value without replacing existing settings \(index)")
  }
  try check(hotkeyDescription(initial) == "Не назначена", "settings: unbound description")
  try check(
    hotkeyDescription(
      ApplicationSettings(
        automatic: false, bound: true, keycode: 0,
        modifiers: allowedHotkeyModifiers)) == "⌃⌥⇧⌘Код клавиши 0",
    "settings: ordered physical-key description")

  // Original printable/modifier and Caps-binding cases, without NSEvent objects.
  for code in [
    kVK_ANSI_A, kVK_Space, kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply,
    kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadMinus,
    kVK_ANSI_KeypadEquals, kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2,
    kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6,
    kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
    kVK_JIS_Yen, kVK_JIS_Underscore, kVK_JIS_KeypadComma,
  ] {
    try check(isPrintableKey(UInt16(code)), "hotkey: printable physical code \(code)")
    try check(
      requiresPrintableKeyConfirmation(code: UInt16(code), modifiers: 0),
      "hotkey: printable key needs confirmation \(code)")
    try check(
      requiresPrintableKeyConfirmation(code: UInt16(code), modifiers: shift),
      "hotkey: Shift-only printable key needs confirmation \(code)")
    for modifier in [command, control, option] {
      try check(
        !requiresPrintableKeyConfirmation(code: UInt16(code), modifiers: modifier),
        "hotkey: command modifier avoids printable-only warning \(code)/\(modifier)")
    }
  }
  for code in [kVK_Return, kVK_Tab, kVK_LeftArrow] {
    try check(!isPrintableKey(UInt16(code)), "hotkey: nonprintable physical code \(code)")
  }
  try check(!isModifierKey(letter), "hotkey: letter is not a modifier")
  try check(isModifierKey(UInt16(kVK_RightCommand)), "hotkey: right Command is a modifier")
  try check(isModifierKey(UInt16(kVK_Function)), "hotkey: Fn is a modifier")
  let capsSettings = ApplicationSettings(automatic: false, bound: true, keycode: caps, modifiers: 0)
  try check(
    parseSettings([SettingsKey.hotkeyCode: NSNumber(value: caps)]) == capsSettings,
    "Caps: single unmodified binding parses")
  try check(hotkeyDescription(capsSettings) == "Caps Lock", "Caps: binding description")
  for modifier in [shift, command, control, option] {
    try check(
      parseSettings([
        SettingsKey.hotkeyCode: NSNumber(value: caps),
        SettingsKey.hotkeyModifiers: NSNumber(value: modifier),
      ]) == nil,
      "Caps: reject modified binding \(modifier)")
  }
  for code in kVK_RightCommand...kVK_Function where code != kVK_CapsLock {
    try check(
      parseSettings([SettingsKey.hotkeyCode: NSNumber(value: code)]) == nil,
      "hotkey: reject modifier binding \(code)")
  }
  try check(
    canRecordHotkey(code: caps, flags: UInt64(NSEvent.ModifierFlags.capsLock.rawValue)),
    "Caps: accept Caps state bit while recording")
  try check(
    !canRecordHotkey(code: caps, flags: UInt64(NSEvent.ModifierFlags.function.rawValue)),
    "Caps: reject Fn while recording")
  try check(
    !canRecordHotkey(code: caps, flags: UInt64(NSEvent.ModifierFlags.help.rawValue)),
    "Caps: reject Help while recording")
  for modifier in [shift, command, control, option] {
    try check(
      !canRecordHotkey(code: caps, flags: modifier), "Caps: recording rejects modifier \(modifier)")
  }
  try check(
    hotkeyRecordingMask.contains(.flagsChanged), "Caps: recording mask includes flagsChanged")
  try check(hotkeyRecordingMask.contains(.keyDown), "hotkey: recording mask includes keyDown")
  try check(acceptsRecordingEvent(type: .flagsChanged, code: caps), "Caps: accepts flagsChanged")
  try check(
    !acceptsRecordingEvent(type: .flagsChanged, code: UInt16(kVK_Shift)),
    "hotkey: ignores other flagsChanged")
  try check(!acceptsRecordingEvent(type: .keyUp, code: caps), "Caps: ignores keyUp")
  try check(acceptsRecordingEvent(type: .keyDown, code: letter), "hotkey: accepts letter keyDown")
  for recording in [false, true] {
    for ownedWindow in [false, true] {
      try check(
        shouldCaptureRecordingEvent(
          recording: recording, ownedSettingsWindowIsKey: ownedWindow,
          type: .flagsChanged, code: caps) == (recording && ownedWindow),
        "Caps: capture only while recording in owned key settings window")
    }
  }

  // Strict per-service marker types. Legacy true/false does not affect mode.
  let invalidMarkerValues: [Any] = [
    "true", NSNumber(value: 1), NSNumber(value: 0),
    NSNumber(value: 1.0), NSNull(), [String: Any](), [Any](),
  ]
  for key in SettingsKey.permissionMarkers {
    for values in [[String: Any](), [key: false], [key: true]] {
      try check(parseSettings(values) == initial, "permissions: optional Boolean marker \(key)")
    }
    for (index, invalid) in invalidMarkerValues.enumerated() {
      var retained = sentinel
      if let parsed = parseSettings([key: invalid]) { retained = parsed }
      try check(
        parseSettings([key: invalid]) == nil && retained == sentinel,
        "permissions: malformed marker blocks settings \(key)/\(index)")
    }
  }
  let partial: [String: Any] = [SettingsKey.accessibilityRegistrationAttempted: true]
  try check(
    permissionRegistrationAction(
      values: partial, settingsValid: true,
      service: .accessibility, granted: false) == .none,
    "permissions: attempted service never repeats")
  try check(
    permissionRegistrationAction(
      values: partial, settingsValid: true,
      service: .inputMonitoring, granted: false) == .request,
    "permissions: unattempted missing second service is eligible")
  try check(
    permissionRegistrationAction(
      values: partial, settingsValid: true,
      service: .inputMonitoring, granted: true) == .remember,
    "permissions: granted second service is remembered without request")
  try check(
    permissionRegistrationAction(
      values: [:], settingsValid: false,
      service: .accessibility, granted: false) == .none,
    "permissions: invalid settings forbid startup requests")
  try check(
    permissionRegistrationAction(
      values: [:], settingsValid: true,
      service: .none, granted: false) == .none,
    "permissions: no-service action is inert")
  var calls = 0
  performPermissionRegistration(
    .none,
    canContinue: {
      calls += 1
      return true
    },
    remember: { calls += 1 }, request: { calls += 1 })
  performPermissionRegistration(
    .request, canContinue: { false },
    remember: { calls += 1 }, request: { calls += 1 })
  performPermissionRegistration(
    .request, canContinue: { calls == 0 },
    remember: { calls += 1 }, request: { calls += 1 })
  try check(
    calls == 1, "permissions: no effects for none/stopped; recheck lifecycle after persistence")

  let services = PermissionService.startupServices
  let legacyDomains: [[String: Any]] = [
    [:], [SettingsKey.permissionIntroductionHandled: false],
    [SettingsKey.permissionIntroductionHandled: true],
  ]
  for (legacyIndex, legacy) in legacyDomains.enumerated() {
    for grants in 0..<4 {
      var values = legacy
      values[SettingsKey.automatic] = true
      values[SettingsKey.hotkeyCode] = NSNumber(value: letter)
      values[SettingsKey.hotkeyModifiers] = NSNumber(value: command)
      values[SettingsKey.diagnosticLogging] = true
      values["unrelated"] = "preserved"
      let original = values
      var remembered = 0
      var requested = 0
      var openings = 0
      var requestedMask = 0
      var correctOrder = true
      // Restart/revocation cannot rearm either request, and an OS refusal
      // cannot prevent the other independent service's registration.
      for pass in 0..<2 {
        for (index, service) in services.enumerated() {
          let granted = pass == 0 && grants & (1 << index) != 0
          let action = permissionRegistrationAction(
            values: values, settingsValid: true,
            service: service, granted: granted)
          performPermissionRegistration(
            action, canContinue: { true },
            remember: {
              remembered += 1
              values = rememberingPermission(service, preserving: values)
            },
            request: {
              if let key = service.registrationKey {
                correctOrder = correctOrder && (values[key] as? Bool == true)
              } else {
                correctOrder = false
              }
              _ = runPermissionRequest(
                showSettings: false, hasAccess: { granted },
                requestAccess: {
                  requested += 1
                  requestedMask |= 1 << index
                  return false
                },
                openSettings: {
                  openings += 1
                  return true
                })
            })
        }
      }
      let expectedMask = (~grants) & 3
      let expectedRequests = (expectedMask & 1 != 0 ? 1 : 0) + (expectedMask & 2 != 0 ? 1 : 0)
      try check(
        correctOrder && remembered == 2 && openings == 0 && requestedMask == expectedMask
          && requested == expectedRequests,
        "permissions: migration/grant/restart matrix \(legacyIndex)/\(grants)")
      for key in [
        SettingsKey.automatic, SettingsKey.hotkeyCode, SettingsKey.hotkeyModifiers,
        SettingsKey.diagnosticLogging, "unrelated",
      ] {
        try check(
          NSDictionary(dictionary: [key: values[key] as Any])
            == NSDictionary(dictionary: [key: original[key] as Any]),
          "permissions: startup preserves unrelated choice \(key)")
      }
      try check(
        parseSettings(values) == parseSettings(original),
        "permissions: registration preserves parsed mode and hotkey")
    }
  }

  // Quit during the first dialog: the unstarted service remains eligible on
  // the next launch, but the first (possibly refused) request cannot repeat.
  var interrupted: [String: Any] = [:]
  var active = true
  var requests = 0
  for service in services {
    let action = permissionRegistrationAction(
      values: interrupted, settingsValid: true,
      service: service, granted: false)
    performPermissionRegistration(
      action, canContinue: { active },
      remember: {
        interrupted = rememberingPermission(service, preserving: interrupted)
      },
      request: {
        requests += 1
        active = false
      })
  }
  try check(
    requests == 1 && interrupted[SettingsKey.accessibilityRegistrationAttempted] as? Bool == true
      && interrupted[SettingsKey.inputMonitoringRegistrationAttempted] == nil,
    "permissions: interrupted startup persists only first attempt")
  active = true
  for service in services {
    let action = permissionRegistrationAction(
      values: interrupted, settingsValid: true,
      service: service, granted: false)
    performPermissionRegistration(
      action, canContinue: { active },
      remember: {
        interrupted = rememberingPermission(service, preserving: interrupted)
      }, request: { requests += 1 })
  }
  try check(requests == 2, "permissions: next launch requests only unstarted second service")

  let expectedURLs = [
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
  ]
  for (index, service) in services.enumerated() {
    try check(
      service.settingsURLString == expectedURLs[index],
      "permissions: exact own settings URL \(index)")
    try check(
      service.settingsURLString.flatMap(URL.init(string:))?.scheme == "x-apple.systempreferences",
      "permissions: valid settings URL \(index)")
    // The old Input Monitoring fallback scenarios apply independently to
    // each service: opening always follows the check and optional request.
    for scenario in 0..<16 {
      let granted = scenario & 1 != 0
      let requestGranted = scenario & 2 != 0
      let settingsOpened = scenario & 4 != 0
      let showSettings = scenario & 8 != 0
      var checks = 0
      var requestCount = 0
      var openingCount = 0
      var correctOrder = true
      let handled = runPermissionRequest(
        showSettings: showSettings,
        hasAccess: {
          correctOrder = correctOrder && checks == 0 && requestCount == 0 && openingCount == 0
          checks += 1
          return granted
        },
        requestAccess: {
          correctOrder = correctOrder && checks == 1 && requestCount == 0 && openingCount == 0
          requestCount += 1
          return requestGranted
        },
        openSettings: {
          correctOrder =
            correctOrder && checks == 1 && requestCount == (granted ? 0 : 1) && openingCount == 0
          openingCount += 1
          return settingsOpened
        })
      try check(
        correctOrder && checks == 1 && requestCount == (granted ? 0 : 1)
          && openingCount == (showSettings ? 1 : 0) && handled == (!showSettings || settingsOpened),
        "permissions: own-service manual/opening policy \(index)/\(scenario)")
    }
  }
  try check(PermissionService.none.settingsURLString == nil, "permissions: no URL for no service")

  // Logging is validated independently from mode, hotkey, and markers.
  let loggingOff = DiagnosticLoggingPreference(isValid: true, enabled: false)
  try check(parseDiagnosticLogging(nil) == loggingOff, "logging: absent domain is off")
  try check(parseDiagnosticLogging([:]) == loggingOff, "logging: absent key is off")
  try check(
    parseDiagnosticLogging([SettingsKey.diagnosticLogging: true])
      == DiagnosticLoggingPreference(isValid: true, enabled: true), "logging: Boolean true")
  try check(
    parseDiagnosticLogging([SettingsKey.diagnosticLogging: false]) == loggingOff,
    "logging: Boolean false")
  for (index, invalid) in invalidMarkerValues.enumerated() {
    let values: [String: Any] = [
      SettingsKey.diagnosticLogging: invalid,
      SettingsKey.hotkeyCode: NSNumber(value: caps),
    ]
    try check(
      parseDiagnosticLogging(values) == DiagnosticLoggingPreference(isValid: false, enabled: false),
      "logging: malformed preference disables logging \(index)")
    try check(
      parseSettings(values) == capsSettings,
      "logging: malformed preference does not block correction \(index)")
  }
  var logValues: [String: Any] = [
    SettingsKey.automatic: true, SettingsKey.hotkeyCode: NSNumber(value: caps),
    SettingsKey.hotkeyModifiers: NSNumber(value: 0),
    SettingsKey.permissionIntroductionHandled: true, "unrelated": "preserved",
  ]
  let originalLogValues = logValues
  let expectedLogSettings = parseSettings(logValues)
  for choice in [true, false, true] {
    logValues[SettingsKey.diagnosticLogging] = choice
    try check(
      parseDiagnosticLogging(logValues)
        == DiagnosticLoggingPreference(isValid: true, enabled: choice)
        && parseSettings(logValues) == expectedLogSettings,
      "logging: toggling preserves mode/key/markers")
  }
  logValues.removeValue(forKey: SettingsKey.diagnosticLogging)
  try check(
    NSDictionary(dictionary: logValues) == NSDictionary(dictionary: originalLogValues)
      && parseDiagnosticLogging(logValues) == loggingOff,
    "logging: removing preference preserves other keys")
  try check(
    parseDiagnosticLogging([Any]()) == DiagnosticLoggingPreference(isValid: false, enabled: false),
    "logging: reject nondictionary domain independently")

  // Writes preserve unknown values. Reset repairs all three markers without
  // rearming either service, and neither operation mutates its input snapshot.
  let unknown: [String: Any] = [
    "futureSetting": ["nested": "preserved"],
    SettingsKey.permissionIntroductionHandled: false,
    SettingsKey.accessibilityRegistrationAttempted: true,
    SettingsKey.inputMonitoringRegistrationAttempted: false,
    SettingsKey.diagnosticLogging: true,
  ]
  let unknownSnapshot = NSDictionary(dictionary: unknown)
  let saved = storingSettings(sentinel, preserving: unknown)
  try check(
    parseSettings(saved) == sentinel,
    "settings: stored values round-trip with integer/Boolean types")
  for key in unknown.keys {
    try check(
      NSDictionary(dictionary: [key: saved[key] as Any])
        == NSDictionary(dictionary: [key: unknown[key] as Any]),
      "settings: save preserves existing key \(key)")
  }
  let cleared = storingSettings(initial, preserving: saved)
  try check(
    parseSettings(cleared) == initial && cleared[SettingsKey.hotkeyCode] == nil
      && cleared[SettingsKey.hotkeyModifiers] == nil,
    "settings: clearing removes both binding fields")
  var damaged = saved
  damaged[SettingsKey.accessibilityRegistrationAttempted] = "malformed"
  damaged[SettingsKey.diagnosticLogging] = NSNumber(value: 1)
  let reset = resettingSettings(preserving: damaged)
  try check(
    parseSettings(reset) == initial && parseDiagnosticLogging(reset) == loggingOff,
    "settings: reset restores manual/unbound and disables logging")
  try check(
    NSDictionary(dictionary: unknown) == unknownSnapshot,
    "settings: persistence policies leave input unchanged")
  try check(
    NSDictionary(dictionary: reset["futureSetting"] as? [String: String] ?? [:])
      == NSDictionary(dictionary: ["nested": "preserved"]),
    "settings: reset preserves unknown nested setting")
  for key in SettingsKey.permissionMarkers {
    try check(reset[key] as? Bool == true, "settings: reset sets marker true \(key)")
  }
  for service in services {
    try check(
      permissionRegistrationAction(
        values: reset, settingsValid: true,
        service: service, granted: false) == .none,
      "permissions: reset cannot repeat automatic request")
  }
  return assertions
}
