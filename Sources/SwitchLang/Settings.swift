import AppKit
import Carbon
import Foundation

// These strings and their property-list types are the existing defaults contract.
enum SettingsKey {
  static let automatic = "automatic"
  static let hotkeyCode = "hotkeyCode"
  static let hotkeyModifiers = "hotkeyModifiers"
  static let permissionIntroductionHandled = "permissionIntroductionHandled"
  static let accessibilityRegistrationAttempted = "accessibilityRegistrationAttempted"
  static let inputMonitoringRegistrationAttempted = "inputMonitoringRegistrationAttempted"
  static let diagnosticLogging = "diagnosticLogging"
  static let permissionMarkers = [
    permissionIntroductionHandled,
    accessibilityRegistrationAttempted,
    inputMonitoringRegistrationAttempted,
  ]
}

struct ApplicationSettings: Equatable {
  var automatic = false
  var bound = false
  var keycode: UInt16 = 0
  var modifiers: UInt64 = 0
}

struct DiagnosticLoggingPreference: Equatable {
  let isValid: Bool
  let enabled: Bool
}

let allowedHotkeyModifiers = UInt64(
  NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.control.rawValue
    | NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.shift.rawValue)
let hotkeyRecordingMask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]

func isModifierKey(_ keycode: UInt16) -> Bool {
  (UInt16(kVK_RightCommand)...UInt16(kVK_Function)).contains(keycode)
}

func canBindHotkey(code: UInt16, modifiers: UInt64) -> Bool {
  if code == kVK_CapsLock { return modifiers == 0 }
  return code <= 127 && !isModifierKey(code)
}

func canRecordHotkey(code: UInt16, flags: UInt64) -> Bool {
  let unsupportedCapsFlags = UInt64(
    NSEvent.ModifierFlags.function.rawValue | NSEvent.ModifierFlags.help.rawValue)
  if code == kVK_CapsLock && flags & unsupportedCapsFlags != 0 { return false }
  return canBindHotkey(code: code, modifiers: flags & allowedHotkeyModifiers)
}

func acceptsRecordingEvent(type: NSEvent.EventType, code: UInt16) -> Bool {
  type == .keyDown || (type == .flagsChanged && code == kVK_CapsLock)
}

func shouldCaptureRecordingEvent(
  recording: Bool, ownedSettingsWindowIsKey: Bool,
  type: NSEvent.EventType, code: UInt16
) -> Bool {
  recording && ownedSettingsWindowIsKey && acceptsRecordingEvent(type: type, code: code)
}

func isPrintableKey(_ keycode: UInt16) -> Bool {
  if keycode <= kVK_ANSI_Grave && keycode != kVK_Return && keycode != kVK_Tab {
    return true
  }
  switch Int(keycode) {
  case kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus,
    kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals,
    kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3,
    kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7,
    kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_JIS_Yen, kVK_JIS_Underscore,
    kVK_JIS_KeypadComma:
    return true
  default:
    return false
  }
}

func requiresPrintableKeyConfirmation(code: UInt16, modifiers: UInt64) -> Bool {
  let commandModifiers = UInt64(
    NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.control.rawValue
      | NSEvent.ModifierFlags.option.rawValue)
  return isPrintableKey(code) && modifiers & commandModifiers == 0
}

private func strictBoolean(_ value: Any) -> Bool? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) == CFBooleanGetTypeID()
  else { return nil }
  return number.boolValue
}

private func unsignedInteger(_ value: Any, maximum: UInt64) -> UInt64? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  let type = String(cString: number.objCType)
  guard type.count == 1, "cCsSiIlLqQ".contains(type), number.int64Value >= 0 else {
    return nil
  }
  let integer = number.uint64Value
  return integer <= maximum ? integer : nil
}

// No defaults, permission APIs, AppKit objects, or global mutations. A failed
// parse returns no settings, leaving the caller's existing value unchanged.
func parseSettings(_ storedValues: Any?) -> ApplicationSettings? {
  guard storedValues == nil || storedValues is NSDictionary else { return nil }
  let values = storedValues as? NSDictionary ?? NSDictionary()
  var settings = ApplicationSettings()
  for key in SettingsKey.permissionMarkers {
    if let marker = values[key], strictBoolean(marker) == nil { return nil }
  }
  if let value = values[SettingsKey.automatic] {
    guard let automatic = strictBoolean(value) else { return nil }
    settings.automatic = automatic
  }
  if let value = values[SettingsKey.hotkeyModifiers] {
    guard let modifiers = unsignedInteger(value, maximum: UInt64.max),
      modifiers & ~allowedHotkeyModifiers == 0
    else { return nil }
    settings.modifiers = modifiers
  }
  if let value = values[SettingsKey.hotkeyCode] {
    guard let keycode = unsignedInteger(value, maximum: 127),
      canBindHotkey(code: UInt16(keycode), modifiers: settings.modifiers)
    else {
      return nil
    }
    settings.bound = true
    settings.keycode = UInt16(keycode)
  } else if settings.modifiers != 0 {
    return nil
  }
  return settings
}

// An invalid optional log preference disables only logging, not correction.
func parseDiagnosticLogging(_ storedValues: Any?) -> DiagnosticLoggingPreference {
  guard storedValues == nil || storedValues is NSDictionary else {
    return DiagnosticLoggingPreference(isValid: false, enabled: false)
  }
  guard let value = (storedValues as? NSDictionary)?[SettingsKey.diagnosticLogging] else {
    return DiagnosticLoggingPreference(isValid: true, enabled: false)
  }
  guard let enabled = strictBoolean(value) else {
    return DiagnosticLoggingPreference(isValid: false, enabled: false)
  }
  return DiagnosticLoggingPreference(isValid: true, enabled: enabled)
}

func storingSettings(_ settings: ApplicationSettings, preserving values: [String: Any]) -> [String:
  Any]
{
  var updated = values
  updated[SettingsKey.automatic] = settings.automatic
  if settings.bound {
    updated[SettingsKey.hotkeyCode] = NSNumber(value: settings.keycode)
    updated[SettingsKey.hotkeyModifiers] = NSNumber(value: settings.modifiers)
  } else {
    updated.removeValue(forKey: SettingsKey.hotkeyCode)
    updated.removeValue(forKey: SettingsKey.hotkeyModifiers)
  }
  return updated
}

func resettingSettings(preserving values: [String: Any]) -> [String: Any] {
  var updated = values
  for key in [
    SettingsKey.automatic, SettingsKey.hotkeyCode,
    SettingsKey.hotkeyModifiers, SettingsKey.diagnosticLogging,
  ] {
    updated.removeValue(forKey: key)
  }
  // A reset repairs malformed markers but never rearms startup requests.
  for key in SettingsKey.permissionMarkers { updated[key] = true }
  return updated
}

func hotkeyDescription(_ settings: ApplicationSettings) -> String {
  guard settings.bound else { return "Не назначена" }
  if settings.keycode == kVK_CapsLock { return "Caps Lock" }
  var description = ""
  for (flag, symbol) in [
    (NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"),
    (.shift, "⇧"), (.command, "⌘"),
  ] {
    if settings.modifiers & UInt64(flag.rawValue) != 0 { description += symbol }
  }
  return description + "Код клавиши \(settings.keycode)"
}
