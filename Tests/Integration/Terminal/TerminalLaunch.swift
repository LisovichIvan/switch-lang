import AppKit
import ApplicationServices

private let terminalWindowCreated: AXObserverCallback = { _, element, _, pointer in
  guard let pointer else { return }
  // SAFETY: launcher removes its observer source before its lifetime ends.
  Unmanaged<TerminalLaunch>.fromOpaque(pointer).takeUnretainedValue().receivedWindow(element)
}

// Test setup only, never compiled into Switch Lang. AX writes are confined to
// a newly opened New Command dialog, never a terminal screen or shell buffer.
final class TerminalLaunch {
  let pid: pid_t
  private let application: AXUIElement
  private let systemWide = AXUIElementCreateSystemWide()
  private var lastReadError = AXError.success
  private var observer: AXObserver?
  private var expectingFixtureWindow = false
  private var createdWindows: [AXUIElement] = []
  private var previousWindows: [AXUIElement] = []
  private var previousFocusedWindow: AXUIElement?
  private var dialogPending = false
  private(set) var dialog: AXUIElement?
  private(set) var window: AXUIElement?
  private(set) var setupStage = "initial"
  private(set) var setupCounts: [String: Int] = [:]

  init(pid: pid_t) throws {
    guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.Terminal"
    else {
      throw TestFailure(description: "Terminal identity unavailable")
    }
    self.pid = pid
    application = AXUIElementCreateApplication(pid)
    guard AXUIElementSetMessagingTimeout(application, 0.250) == .success,
      AXUIElementSetMessagingTimeout(systemWide, 0.250) == .success
    else {
      throw TestFailure(description: "Terminal AX timeout unavailable")
    }
    var created: AXObserver?
    guard AXObserverCreate(pid, terminalWindowCreated, &created) == .success, let created else {
      throw TestFailure(description: "Terminal window observer unavailable")
    }
    guard
      AXObserverAddNotification(
        created, application, kAXWindowCreatedNotification as CFString,
        Unmanaged.passUnretained(self).toOpaque()) == .success
    else {
      throw TestFailure(description: "Terminal window creation notification unavailable")
    }
    observer = created
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
  }

  deinit { stopWindowObservation() }

  private func stopWindowObservation() {
    if let observer {
      _ = AXObserverRemoveNotification(
        observer, application, kAXWindowCreatedNotification as CFString)
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
      self.observer = nil
    }
    expectingFixtureWindow = false
  }

  fileprivate func receivedWindow(_ element: AXUIElement) {
    guard expectingFixtureWindow, createdWindows.count < 4 else { return }
    if !createdWindows.contains(where: { CFEqual($0, element) }) { createdWindows.append(element) }
  }

  func value(_ target: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    lastReadError = AXUIElementCopyAttributeValue(target, attribute as CFString, &value)
    return lastReadError == .success ? value : nil
  }

  func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    // SAFETY: AXUIElement dynamic type was checked.
    return unsafeBitCast(value, to: AXUIElement.self)
  }

  private func checkedElements(_ target: AXUIElement, _ attribute: String, maximum: Int = 64)
    -> [AXUIElement]?
  {
    guard let value = value(target, attribute), CFGetTypeID(value) == CFArrayGetTypeID() else {
      return nil
    }
    // SAFETY: CFArray dynamic type was checked; each element is checked too.
    let array = unsafeBitCast(value, to: CFArray.self)
    guard CFArrayGetCount(array) <= maximum else { return nil }
    var result: [AXUIElement] = []
    for index in 0..<CFArrayGetCount(array) {
      guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
      let object = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
      guard let element = element(object) else { return nil }
      result.append(element)
    }
    return result
  }

  func elements(_ target: AXUIElement, _ attribute: String, maximum: Int = 64) -> [AXUIElement] {
    checkedElements(target, attribute, maximum: maximum) ?? []
  }

  func matches(_ target: AXUIElement, _ attribute: String, _ expected: String) -> Bool {
    guard let value = value(target, attribute), CFGetTypeID(value) == CFStringGetTypeID() else {
      return false
    }
    return CFEqual(value, expected as CFString)
  }

  private func menuModifiers(_ target: AXUIElement) -> Int64? {
    guard let value = value(target, kAXMenuItemCmdModifiersAttribute),
      CFGetTypeID(value) == CFNumberGetTypeID()
    else { return nil }
    // SAFETY: CFNumber dynamic type checked; conversion rejects other types.
    let number = unsafeBitCast(value, to: CFNumber.self)
    var result: Int64 = -1
    return CFNumberGetValue(number, .sInt64Type, &result) ? result : nil
  }

  private func windows() -> [AXUIElement]? {
    if let windows = checkedElements(application, kAXWindowsAttribute) { return windows }
    setupCounts["windowsError"] = Int(lastReadError.rawValue)
    return lastReadError == .noValue ? [] : nil
  }

  private func focusedElement() -> AXUIElement? {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      let focused = element(value(systemWide, kAXFocusedUIElementAttribute))
    else { return nil }
    var focusedPID: pid_t = 0
    guard AXUIElementGetPid(focused, &focusedPID) == .success, focusedPID == pid,
      AXUIElementSetMessagingTimeout(focused, 0.250) == .success
    else { return nil }
    return focused
  }

  private func focusedWindow() -> AXUIElement? {
    guard let focused = focusedElement() else { return nil }
    if matches(focused, kAXRoleAttribute, kAXWindowRole) { return focused }
    return element(value(focused, kAXWindowAttribute))
  }

  func openNewCommand() -> Bool {
    setupStage = "baseline-windows"
    guard let windows = windows() else { return false }
    previousWindows = windows
    previousFocusedWindow = focusedWindow()
    setupCounts["baselineWindows"] = windows.count
    setupCounts["baselineFocusedWindow"] = previousFocusedWindow == nil ? 0 : 1
    if let focused = previousFocusedWindow,
      !previousWindows.contains(where: { CFEqual($0, focused) })
    {
      previousWindows.append(focused)
    }
    setupStage = "new-command-menu"
    // Never interact with an already open command dialog or sheet.
    guard
      !previousWindows.contains(where: {
        matches($0, kAXSubroleAttribute, kAXDialogSubrole)
          || elements($0, kAXChildrenAttribute).contains {
            matches($0, kAXRoleAttribute, kAXSheetRole)
          }
      }), let bar = element(value(application, kAXMenuBarAttribute))
    else { return false }
    for top in elements(bar, kAXChildrenAttribute, maximum: 16) {
      for menu in elements(top, kAXChildrenAttribute, maximum: 4) {
        for item in elements(menu, kAXChildrenAttribute, maximum: 128) {
          if matches(item, kAXMenuItemCmdCharAttribute, "N")
            || matches(item, kAXMenuItemCmdCharAttribute, "n"),
            menuModifiers(item) == Int64(AXMenuItemModifiers.shift.rawValue),
            matches(item, kAXRoleAttribute, kAXMenuItemRole)
          {
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
          }
        }
      }
    }
    return false
  }

  private func descendants(_ target: AXUIElement) -> [AXUIElement] {
    var pending = [target]
    var result: [AXUIElement] = []
    while !pending.isEmpty, result.count < 64 {
      let next = pending.removeFirst()
      result.append(next)
      pending.append(contentsOf: elements(next, kAXChildrenAttribute))
      guard pending.count <= 64 else { return [] }
    }
    return pending.isEmpty ? result : []
  }

  func runFixture(session: String, directory: String) -> Bool {
    guard let windows = windows() else { return false }
    let fresh = windows.filter { current in
      !previousWindows.contains { CFEqual(current, $0) }
    }
    setupStage = "new-window-count"
    setupCounts["previousWindows"] = previousWindows.count
    setupCounts["freshWindows"] = fresh.count
    guard let dialog = focusedWindow() else { return false }
    guard
      previousFocusedWindow.map({ !CFEqual($0, dialog) })
        ?? fresh.contains(where: { CFEqual($0, dialog) })
    else { return false }
    self.dialog = dialog
    dialogPending = true
    setupStage = "new-dialog-role"
    setupCounts["windowRole"] = matches(dialog, kAXRoleAttribute, kAXWindowRole) ? 1 : 0
    setupCounts["dialogSubrole"] = matches(dialog, kAXSubroleAttribute, kAXDialogSubrole) ? 1 : 0
    guard matches(dialog, kAXRoleAttribute, kAXWindowRole) else { return false }
    let controls = descendants(dialog)
    let textFields = controls.filter { matches($0, kAXRoleAttribute, kAXTextFieldRole) }
    let fields =
      textFields.isEmpty
      ? controls.filter { matches($0, kAXRoleAttribute, kAXComboBoxRole) } : textFields
    let checkboxes = controls.filter { matches($0, kAXRoleAttribute, kAXCheckBoxRole) }
    let buttons = controls.filter {
      matches($0, kAXRoleAttribute, kAXButtonRole)
        && (matches($0, kAXTitleAttribute, "Run") || matches($0, kAXTitleAttribute, "Выполнить")
          || matches($0, kAXTitleAttribute, "Запустить"))
    }
    setupStage = "dialog-controls"
    setupCounts["controls"] = controls.count
    setupCounts["fields"] = fields.count
    setupCounts["checkboxes"] = checkboxes.count
    setupCounts["runButtons"] = buttons.count
    guard fields.count == 1, checkboxes.count == 1, buttons.count == 1,
      let field = fields.first, let checkbox = checkboxes.first, let run = buttons.first
    else { return false }
    let command = directory + "/tty-fixture " + session + " " + directory
    setupStage = "synthetic-command-field"
    guard command.utf16.count < 512,
      AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, command as CFString)
        == .success,
      matches(field, kAXValueAttribute, command)
    else { return false }
    func checkboxValue() -> Int64? {
      guard let value = value(checkbox, kAXValueAttribute) else { return nil }
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return CFEqual(value, kCFBooleanTrue) ? 1 : 0
      }
      guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
      // SAFETY: checked dynamic CFNumber type before conversion.
      let number = unsafeBitCast(value, to: CFNumber.self)
      var result: Int64 = -1
      return CFNumberGetValue(number, .sInt64Type, &result) ? result : nil
    }
    setupStage = "shell-checkbox"
    guard let checked = checkboxValue(), checked == 0 || checked == 1 else { return false }
    if checked == 1 {
      guard AXUIElementPerformAction(checkbox, kAXPressAction as CFString) == .success else {
        return false
      }
    }
    guard checkboxValue() == 0, matches(field, kAXValueAttribute, command) else { return false }
    setupStage = "run-fixture"
    createdWindows.removeAll()
    expectingFixtureWindow = true
    let started = AXUIElementPerformAction(run, kAXPressAction as CFString) == .success
    if started { dialogPending = false }
    return started
  }

  func identifyFixtureWindow() -> AXUIElement? {
    let fresh = createdWindows.filter { current in
      !previousWindows.contains { CFEqual(current, $0) }
        && (dialog.map { !CFEqual(current, $0) } ?? true)
    }
    setupCounts["createdFixtureWindows"] = fresh.count
    guard fresh.count == 1, let window = fresh.first,
      let focused = focusedWindow(), CFEqual(window, focused),
      matches(window, kAXRoleAttribute, kAXWindowRole),
      !matches(window, kAXSubroleAttribute, kAXDialogSubrole)
    else { return nil }
    self.window = window
    stopWindowObservation()
    return window
  }

  func focusedFixtureElement() -> AXUIElement? {
    guard let window,
      let focusedWindow = focusedWindow(), CFEqual(window, focusedWindow),
      let focused = focusedElement(),
      matches(focused, kAXRoleAttribute, kAXTextAreaRole)
    else { return nil }
    return focused
  }

  func closeOwnedUI() {
    if dialogPending, let dialog {
      let cancel = descendants(dialog).first {
        matches($0, kAXRoleAttribute, kAXButtonRole)
          && (matches($0, kAXTitleAttribute, "Cancel")
            || matches($0, kAXTitleAttribute, "Отменить"))
      }
      if let cancel { _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString) }
      dialogPending = false
    }
    if let window, !previousWindows.contains(where: { CFEqual(window, $0) }),
      let close = element(value(window, kAXCloseButtonAttribute))
    {
      _ = AXUIElementPerformAction(close, kAXPressAction as CFString)
    }
  }
}
