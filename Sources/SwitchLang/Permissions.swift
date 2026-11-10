import ApplicationServices
import CoreGraphics
import Foundation

enum PermissionService: CaseIterable {
  case none
  case accessibility
  case inputMonitoring

  static let startupServices: [PermissionService] = [.accessibility, .inputMonitoring]

  var registrationKey: String? {
    switch self {
    case .none: return nil
    case .accessibility: return SettingsKey.accessibilityRegistrationAttempted
    case .inputMonitoring: return SettingsKey.inputMonitoringRegistrationAttempted
    }
  }

  var settingsURLString: String? {
    switch self {
    case .none: return nil
    case .accessibility:
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case .inputMonitoring:
      return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    }
  }

  var sectionTitle: String {
    switch self {
    case .none: return ""
    case .accessibility: return "Универсальный доступ"
    case .inputMonitoring: return "Мониторинг ввода"
    }
  }
}

enum PermissionRegistrationAction {
  case none
  case remember
  case request
}

// The old introduction marker intentionally does not suppress migration.
func permissionRegistrationAction(
  values: [String: Any], settingsValid: Bool,
  service: PermissionService, granted: Bool
) -> PermissionRegistrationAction {
  guard settingsValid, let key = service.registrationKey else { return .none }
  // Parsing settings validates each marker's exact Boolean type first.
  if (values[key] as? NSNumber)?.boolValue == true { return .none }
  return granted ? .remember : .request
}

func rememberingPermission(
  _ service: PermissionService,
  preserving values: [String: Any]
) -> [String: Any] {
  guard let key = service.registrationKey else { return values }
  var updated = values
  updated[key] = true
  updated[SettingsKey.permissionIntroductionHandled] = true
  return updated
}

// Persist before the public request. Both persistence and OS UI may reenter the
// application lifecycle; a stopped launch must not begin another request.
func performPermissionRegistration(
  _ action: PermissionRegistrationAction,
  canContinue: () -> Bool, remember: () -> Void,
  request: () -> Void
) {
  guard action != .none, canContinue() else { return }
  remember()
  if action == .request && canContinue() { request() }
}

// Requests are not grants (AX prompts are asynchronous). Manual actions always
// open their own panel, even when access was already granted or the request fails.
func runPermissionRequest(
  showSettings: Bool, hasAccess: () -> Bool,
  requestAccess: () -> Bool, openSettings: () -> Bool
) -> Bool {
  if !hasAccess() { _ = requestAccess() }
  return !showSettings || openSettings()
}

// Public API boundary. Pure policy tests never call these functions.
func hasPermission(_ service: PermissionService) -> Bool {
  switch service {
  case .none: return false
  case .accessibility: return AXIsProcessTrusted()
  case .inputMonitoring: return CGPreflightListenEventAccess()
  }
}

func requestSystemPermission(_ service: PermissionService) -> Bool {
  switch service {
  case .none: return false
  case .accessibility:
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
  case .inputMonitoring:
    return CGRequestListenEventAccess()
  }
}
