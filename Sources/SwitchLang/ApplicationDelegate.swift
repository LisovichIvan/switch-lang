import AppKit
import Carbon
import Foundation

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
  private let runtime: ApplicationRuntime
  private let defaults: UserDefaults
  private let domainName: String
  private var storedDomain: [String: Any]
  private var settings: ApplicationSettings
  private var settingsValid: Bool
  private var diagnosticLogging: Bool
  private var diagnosticSettingsValid: Bool
  private let diagnosticLogPath: String?
  private var paused = false
  private var recording = false
  private var workerFailed = false
  private var tapFailed = false
  private var partialFailure = false
  private var actionSuppressed = false
  private var capsLockFailure = false
  private var automaticWarningAccepted = false
  private var startRequested = false
  private var terminating = false
  private var notice: String?
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?
  private var mainMenu: NSMenu?
  private var statusLine: NSMenuItem?
  private var accessLine: NSMenuItem?
  private var accessibilityPermissionItem: NSMenuItem?
  private var inputMonitoringPermissionItem: NSMenuItem?
  private var manualItem: NSMenuItem?
  private var automaticItem: NSMenuItem?
  private var pauseItem: NSMenuItem?
  private var resetItem: NSMenuItem?
  private var settingsWindow: NSWindow?
  private var modePicker: NSPopUpButton?
  private var hotkeyLabel: NSTextField?
  private var settingsStatus: NSTextField?
  private var recordButton: NSButton?
  private var clearButton: NSButton?
  private var resetButton: NSButton?
  private var accessibilityPermissionButton: NSButton?
  private var inputMonitoringPermissionButton: NSButton?
  private var diagnosticLoggingButton: NSButton?
  private var showDiagnosticLogButton: NSButton?
  private var diagnosticLogStatus: NSTextField?
  private var localMonitor: Any?

  init(runtime: ApplicationRuntime) {
    self.runtime = runtime
    // Read only once at application construction, never on the input path.
    let defaults = UserDefaults.standard
    let domainName = Bundle.main.bundleIdentifier ?? ""
    let stored = domainName.isEmpty ? nil : defaults.persistentDomain(forName: domainName)
    self.defaults = defaults
    self.domainName = domainName
    storedDomain = stored ?? [:]
    let parsed = parseSettings(stored)
    settings = parsed ?? ApplicationSettings()
    settingsValid = !domainName.isEmpty && parsed != nil
    let logging = parseDiagnosticLogging(stored)
    diagnosticSettingsValid = logging.isValid
    diagnosticLogging = logging.enabled
    let bundle = Bundle.main.bundleURL
    diagnosticLogPath =
      bundle.pathExtension.lowercased() == "app"
      ? bundle.deletingLastPathComponent().appendingPathComponent("switch-lang.log").path : nil
    super.init()
    // The runtime delivers reports on the main thread; do not retain the UI.
    runtime.onReport = { [weak self] status in self?.handleReport(status) }
    DiagnosticLogger.shared.onError = { [weak self] in
      DispatchQueue.main.async { [weak self] in self?.handleReport(9) }
    }
  }

  private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
    menuItem.target = self
    return menuItem
  }

  private func label(_ text: String, frame: NSRect) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.frame = frame
    field.isSelectable = false
    return field
  }

  private func button(_ title: String, frame: NSRect, action: Selector) -> NSButton {
    let control = NSButton(title: title, target: self, action: action)
    control.frame = frame
    control.bezelStyle = .rounded
    return control
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let menu = NSMenu(title: "switch-lang")
    menu.autoenablesItems = false
    menu.delegate = self
    statusMenu = menu
    let status = item("")
    let access = item("")
    status.isEnabled = false
    access.isEnabled = false
    statusLine = status
    accessLine = access
    menu.addItem(status)
    menu.addItem(access)
    menu.addItem(.separator())
    let manual = item("Ручной режим", action: #selector(selectManual(_:)))
    let automatic = item(
      "Автоматический (экспериментальный)", action: #selector(selectAutomatic(_:)))
    manualItem = manual
    automaticItem = automatic
    menu.addItem(manual)
    menu.addItem(automatic)
    menu.addItem(item("Настройки…", action: #selector(showSettings(_:))))
    menu.addItem(.separator())
    menu.addItem(item("Проверить доступ", action: #selector(checkAccess(_:))))
    let accessibility = item(
      "Универсальный доступ…", action: #selector(requestAccessibilityPermission(_:)))
    let inputMonitoring = item(
      "Мониторинг ввода…", action: #selector(requestInputMonitoringPermission(_:)))
    accessibilityPermissionItem = accessibility
    inputMonitoringPermissionItem = inputMonitoring
    menu.addItem(accessibility)
    menu.addItem(inputMonitoring)
    let reset = item("Сбросить настройки…", action: #selector(resetSettings(_:)))
    resetItem = reset
    menu.addItem(reset)
    let pause = item("Пауза", action: #selector(togglePause(_:)))
    pauseItem = pause
    menu.addItem(pause)
    menu.addItem(.separator())
    menu.addItem(item("Завершить switch-lang", action: #selector(quit(_:))))
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.statusItem = statusItem
    statusItem.button?.title = "RU⇄EN"
    statusItem.menu = menu

    let main = NSMenu(title: "switch-lang")
    mainMenu = main
    let applicationItem = item("switch-lang")
    let applicationMenu = NSMenu(title: "switch-lang")
    let settingsItem = item("Настройки…", action: #selector(showSettings(_:)))
    settingsItem.keyEquivalent = ","
    applicationMenu.addItem(settingsItem)
    let quitItem = item("Завершить switch-lang", action: #selector(quit(_:)))
    quitItem.keyEquivalent = "q"
    applicationMenu.addItem(quitItem)
    applicationItem.submenu = applicationMenu
    main.addItem(applicationItem)
    NSApp.mainMenu = main

    applyDiagnosticLogging()
    runtime.setHotkey(
      code: settings.keycode, modifiers: settings.modifiers,
      bound: settingsValid && settings.bound)
    refreshStatus()
    // AX requests have no completion callback; dispatch does not claim to
    // serialize system dialogs, only to finish our application launch first.
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.registerPermissionsOnLaunch()
      if !self.terminating { self.startPlatform() }
    }
  }

  private func persistDomain() {
    defaults.setPersistentDomain(storedDomain, forName: domainName)
  }

  private func registerPermissionsOnLaunch() {
    guard !terminating, settingsValid else { return }
    for service in PermissionService.startupServices {
      if terminating { return }
      let action = permissionRegistrationAction(
        values: storedDomain, settingsValid: settingsValid,
        service: service, granted: hasPermission(service))
      performPermissionRegistration(
        action, canContinue: { !self.terminating },
        remember: {
          self.storedDomain = rememberingPermission(service, preserving: self.storedDomain)
          self.persistDomain()
        },
        request: {
          self.requestPermission(service, showSettings: false)
        })
    }
  }

  // Startup and the explicit access check are the only paths that start a tap.
  private func startPlatform() {
    refreshStatus()
    if settingsValid && !workerFailed && !tapFailed && !terminating {
      startRequested = runtime.begin()
    }
    refreshStatus()
  }

  private func refreshStatus() {
    guard !terminating else { return }
    let accessibility = hasPermission(.accessibility)
    let listeningAccess = hasPermission(.inputMonitoring)
    let replacementFailure = runtime.replacementFailure
    if replacementFailure != 0 {
      partialFailure = true
      actionSuppressed = replacementFailure == 4
      paused = true
    }
    let needsInput = settingsValid && (settings.automatic || settings.bound)
    let blocked =
      !settingsValid || !accessibility || !listeningAccess || paused || workerFailed || tapFailed
      || !needsInput
    runtime.setPaused(blocked)
    runtime.setAutomatic(!blocked && !recording && settings.automatic)
    if !accessibility || !listeningAccess || !settingsValid || workerFailed || tapFailed {
      startRequested = false
      runtime.stop()
    }

    let status: String
    if domainName.isEmpty {
      status = "Неактивно: запустите приложение из .app с bundle identifier"
    } else if !settingsValid {
      status = "Неактивно: настройки повреждены. Нужен явный сброс"
    } else if partialFailure && paused {
      status =
        actionSuppressed
        ? "Пауза: замена не подтверждена, Enter/Tab не передан. Проверьте текст"
        : "Пауза: клавиатурная замена не подтверждена. Проверьте текст перед снятием паузы"
    } else if workerFailed {
      status = "Неактивно: не удалось запустить обработчик. Перезапустите приложение"
    } else if tapFailed {
      status = "Неактивно: системный обработчик отключён. Нажмите «Проверить доступ»"
    } else if capsLockFailure && paused {
      status =
        "Пауза: не удалось отключить Caps Lock. Выберите другую клавишу или проверьте доступ и снимите паузу"
    } else if paused {
      status = "Приостановлено пользователем"
    } else if recording {
      status = "Приостановлено: запись клавиши"
    } else if !needsInput {
      status = "Ручной режим: назначьте клавишу в настройках"
    } else if !accessibility || !listeningAccess {
      status = "Неактивно: не предоставлены необходимые разрешения"
    } else if !runtime.isListening {
      status =
        startRequested
        ? "Запуск системного обработчика…"
        : "Неактивно: нажмите «Проверить доступ» для запуска обработчика"
    } else if let notice = notice {
      status = notice
    } else {
      status =
        settings.automatic
        ? "Активно: автоматический режим (экспериментальный)" : "Активно: ручной режим"
    }
    statusLine?.title = status
    statusItem?.button?.toolTip = status
    let accessStatus =
      "Доступ: Accessibility — \(accessibility ? "да" : "нет"); Input Monitoring — \(listeningAccess ? "да" : "нет")"
    accessLine?.title = accessStatus
    let canOpenPermissionSettings = !domainName.isEmpty
    accessibilityPermissionItem?.isEnabled = canOpenPermissionSettings
    inputMonitoringPermissionItem?.isEnabled = canOpenPermissionSettings
    accessibilityPermissionButton?.isEnabled = canOpenPermissionSettings
    inputMonitoringPermissionButton?.isEnabled = canOpenPermissionSettings
    let accessibilityTip =
      "Для проверки поля и эмуляции исправления. Открыть «Универсальный доступ» в macOS; при необходимости повторить его запрос."
    let inputTip =
      "Для событий клавиатуры, без сохранения текста. Открыть «Мониторинг ввода» в macOS; при необходимости повторить его запрос."
    accessibilityPermissionItem?.toolTip = accessibilityTip
    inputMonitoringPermissionItem?.toolTip = inputTip
    accessibilityPermissionButton?.toolTip = accessibilityTip
    inputMonitoringPermissionButton?.toolTip = inputTip
    manualItem?.isEnabled = settingsValid
    automaticItem?.isEnabled = settingsValid
    manualItem?.state = settingsValid && !settings.automatic ? .on : .off
    automaticItem?.state = settingsValid && settings.automatic ? .on : .off
    pauseItem?.isEnabled = settingsValid
    pauseItem?.title = paused ? "Снять паузу" : "Пауза"
    pauseItem?.state = paused ? .on : .off
    let canReset =
      !domainName.isEmpty
      && ([
        SettingsKey.automatic, SettingsKey.hotkeyCode, SettingsKey.hotkeyModifiers,
        SettingsKey.diagnosticLogging,
      ].contains { storedDomain[$0] != nil } || !settingsValid || !diagnosticSettingsValid)
    resetItem?.isEnabled = canReset
    resetButton?.isEnabled = canReset
    settingsStatus?.stringValue = "\(status)\n\(accessStatus)"
    modePicker?.isEnabled = settingsValid
    if settingsValid {
      modePicker?.selectItem(at: settings.automatic ? 1 : 0)
    } else {
      modePicker?.select(nil)
    }
    recordButton?.isEnabled = settingsValid
    recordButton?.title = recording ? "Отменить запись" : "Записать клавишу…"
    clearButton?.isEnabled = settingsValid && settings.bound && !recording
    hotkeyLabel?.stringValue =
      recording
      ? "Нажмите клавишу (Esc — отмена)"
      : (settingsValid ? hotkeyDescription(settings) : "Настройки недействительны")
    refreshDiagnosticControls()
  }

  private func refreshDiagnosticControls() {
    diagnosticLoggingButton?.isEnabled = !domainName.isEmpty
    diagnosticLoggingButton?.state = diagnosticLogging ? .on : .off
    let logger = DiagnosticLogger.shared
    let status: String
    if !diagnosticSettingsValid {
      status = "Настройка журнала повреждена; запись выключена"
    } else if logger.lastError != 0 {
      status = "Ошибка журнала (код \(logger.lastError)); исправление не отключено"
    } else if logger.isEnabled {
      status = "Запись включена: только технические этапы, без текста набора"
    } else {
      status = "Запись выключена; существующие файлы сохраняются"
    }
    diagnosticLogStatus?.stringValue =
      "\(status)\n\(diagnosticLogPath ?? "Путь недоступен вне .app")\nДо 1 МиБ + одна резервная копия; обычные клавиши не записываются"
    showDiagnosticLogButton?.isEnabled =
      diagnosticLogPath.map {
        FileManager.default.fileExists(atPath: $0)
      } ?? false
  }

  private func applyDiagnosticLogging() {
    _ = DiagnosticLogger.shared.setEnabled(
      diagnosticSettingsValid && diagnosticLogging,
      path: diagnosticLogPath)
    refreshDiagnosticControls()
  }

  @objc func toggleDiagnosticLogging(_ sender: Any?) {
    guard !terminating, !domainName.isEmpty else { return }
    diagnosticLogging = diagnosticLoggingButton?.state == .on
    diagnosticSettingsValid = true
    storedDomain[SettingsKey.diagnosticLogging] = diagnosticLogging
    persistDomain()
    resetItem?.isEnabled = true
    resetButton?.isEnabled = true
    applyDiagnosticLogging()
  }

  @objc func showDiagnosticLog(_ sender: Any?) {
    if let path = diagnosticLogPath, FileManager.default.fileExists(atPath: path) {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    finishRecording()
    refreshStatus()
  }

  private func saveSettings(_ updated: ApplicationSettings) {
    guard settingsValid, settings != updated else {
      refreshStatus()
      return
    }
    settings = updated
    if !updated.bound || updated.keycode != kVK_CapsLock { capsLockFailure = false }
    storedDomain = storingSettings(updated, preserving: storedDomain)
    persistDomain()
    runtime.setHotkey(code: updated.keycode, modifiers: updated.modifiers, bound: updated.bound)
    runtime.invalidate()
    refreshStatus()
  }

  @objc private func selectManual(_ sender: Any?) {
    finishRecording()
    var updated = settings
    updated.automatic = false
    saveSettings(updated)
  }

  @objc private func selectAutomatic(_ sender: Any?) {
    finishRecording()
    guard settingsValid else {
      refreshStatus()
      return
    }
    if !settings.automatic && !automaticWarningAccepted {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Автоматический режим — экспериментальный"
      alert.informativeText =
        "Возможны ложные исправления: словарь пока мал, а системная замена "
        + "неатомарна. Enter/Tab могут ненадолго задерживаться программно: сначала исправление, "
        + "затем действие клавиши. При неподтверждённом частичном изменении включается пауза, "
        + "а отложенный Enter/Tab не передаётся. Работа в реальных приложениях ещё не проверена. "
        + "Сначала используйте несекретный тестовый текст."
      alert.addButton(withTitle: "Включить")
      alert.addButton(withTitle: "Отмена")
      NSApp.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertFirstButtonReturn else {
        refreshStatus()
        return
      }
      automaticWarningAccepted = true
    }
    var updated = settings
    updated.automatic = true
    saveSettings(updated)
  }

  @objc private func modeChanged(_ sender: Any?) {
    if modePicker?.indexOfSelectedItem == 1 { selectAutomatic(nil) } else { selectManual(nil) }
  }

  @objc private func togglePause(_ sender: Any?) {
    finishRecording()
    paused.toggle()
    if !paused {
      runtime.acknowledgeReplacementFailure()
      partialFailure = false
      actionSuppressed = false
    }
    runtime.invalidate()
    refreshStatus()
  }

  @objc private func checkAccess(_ sender: Any?) {
    finishRecording()
    tapFailed = false
    startPlatform()
  }

  @objc func requestAccessibilityPermission(_ sender: Any?) {
    requestPermission(.accessibility, showSettings: true)
  }

  @objc func requestInputMonitoringPermission(_ sender: Any?) {
    requestPermission(.inputMonitoring, showSettings: true)
  }

  private func requestPermission(_ service: PermissionService, showSettings: Bool) {
    guard !terminating, !domainName.isEmpty, let string = service.settingsURLString else { return }
    finishRecording()
    let handled = runPermissionRequest(
      showSettings: showSettings,
      hasAccess: {
        hasPermission(service)
      },
      requestAccess: {
        guard !self.terminating else { return false }
        return requestSystemPermission(service)
      },
      openSettings: {
        guard !self.terminating, let url = URL(string: string) else { return false }
        return NSWorkspace.shared.open(url)
      })
    guard !terminating else { return }
    if !handled {
      let section = service.sectionTitle
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Не удалось открыть «\(section)»"
      alert.informativeText =
        "Откройте настройки конфиденциальности macOS, выберите раздел «\(section)» и разрешите Switch Lang. "
        + "Затем нажмите «Проверить доступ» в приложении; macOS может потребовать перезапуск."
      alert.addButton(withTitle: "Понятно")
      NSApp.activate(ignoringOtherApps: true)
      alert.runModal()
    }
    refreshStatus()
  }

  @objc private func resetSettings(_ sender: Any?) {
    finishRecording()
    guard !domainName.isEmpty else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Сбросить настройки switch-lang?"
    alert.informativeText =
      "Будет выбран ручной режим без назначенной клавиши. "
      + "Журнал будет выключен, его файлы сохранятся. Разрешения macOS не изменятся."
    alert.addButton(withTitle: "Сбросить")
    alert.addButton(withTitle: "Отмена")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else {
      refreshStatus()
      return
    }
    let storedSettings =
      ([
        SettingsKey.automatic, SettingsKey.hotkeyCode,
        SettingsKey.hotkeyModifiers, SettingsKey.diagnosticLogging,
      ] + SettingsKey.permissionMarkers)
      .contains { storedDomain[$0] != nil }
    storedDomain = resettingSettings(preserving: storedDomain)
    if storedSettings { persistDomain() }
    settings = ApplicationSettings()
    diagnosticLogging = false
    diagnosticSettingsValid = true
    applyDiagnosticLogging()
    capsLockFailure = false
    settingsValid = true
    runtime.setHotkey(code: 0, modifiers: 0, bound: false)
    runtime.invalidate()
    refreshStatus()
  }

  @objc private func showSettings(_ sender: Any?) {
    if settingsWindow == nil { createSettingsWindow() }
    refreshStatus()
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  private func createSettingsWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 490),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    settingsWindow = window
    window.title = "Настройки switch-lang"
    window.isReleasedWhenClosed = false
    window.delegate = self
    guard let content = window.contentView else { return }
    content.addSubview(label("Режим", frame: NSRect(x: 20, y: 440, width: 115, height: 24)))
    let mode = NSPopUpButton(
      frame: NSRect(x: 145, y: 436, width: 375, height: 30), pullsDown: false)
    modePicker = mode
    mode.addItems(withTitles: ["Ручной", "Автоматический (экспериментальный)"])
    mode.target = self
    mode.action = #selector(modeChanged(_:))
    content.addSubview(mode)
    content.addSubview(
      label("Исправить слово", frame: NSRect(x: 20, y: 395, width: 125, height: 26)))
    let hotkey = label("", frame: NSRect(x: 145, y: 392, width: 375, height: 30))
    hotkeyLabel = hotkey
    content.addSubview(hotkey)
    let record = button(
      "Записать клавишу…", frame: NSRect(x: 140, y: 347, width: 220, height: 32),
      action: #selector(recordHotkey(_:)))
    recordButton = record
    let clear = button(
      "Убрать", frame: NSRect(x: 375, y: 347, width: 145, height: 32),
      action: #selector(clearHotkey(_:)))
    clearButton = clear
    content.addSubview(record)
    content.addSubview(clear)
    content.addSubview(
      label(
        "Экспериментальный автоматический режим проверяет все разделители. "
          + "Клавиша хранится по физическому коду. Конфликты с другими сочетаниями не проверяются.",
        frame: NSRect(x: 20, y: 280, width: 500, height: 60)))
    let status = label("", frame: NSRect(x: 20, y: 205, width: 500, height: 70))
    settingsStatus = status
    status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    content.addSubview(status)
    let logging = NSButton(
      checkboxWithTitle: "Диагностический лог в файл", target: self,
      action: #selector(toggleDiagnosticLogging(_:)))
    diagnosticLoggingButton = logging
    logging.frame = NSRect(x: 20, y: 165, width: 330, height: 28)
    logging.toolTip =
      "Без текста, названий окон и обычных клавиш. Ошибка записи не останавливает исправление."
    content.addSubview(logging)
    let showLog = button(
      "Показать файл", frame: NSRect(x: 355, y: 162, width: 165, height: 32),
      action: #selector(showDiagnosticLog(_:)))
    showDiagnosticLogButton = showLog
    content.addSubview(showLog)
    let logStatus = label("", frame: NSRect(x: 20, y: 90, width: 500, height: 70))
    diagnosticLogStatus = logStatus
    logStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    logStatus.isSelectable = true
    content.addSubview(logStatus)
    let accessibility = button(
      "Универсальный доступ…", frame: NSRect(x: 20, y: 50, width: 245, height: 32),
      action: #selector(requestAccessibilityPermission(_:)))
    accessibilityPermissionButton = accessibility
    let input = button(
      "Мониторинг ввода…", frame: NSRect(x: 275, y: 50, width: 245, height: 32),
      action: #selector(requestInputMonitoringPermission(_:)))
    inputMonitoringPermissionButton = input
    content.addSubview(accessibility)
    content.addSubview(input)
    content.addSubview(
      button(
        "Проверить доступ", frame: NSRect(x: 275, y: 10, width: 245, height: 32),
        action: #selector(checkAccess(_:))))
    let reset = button(
      "Сбросить настройки…", frame: NSRect(x: 15, y: 10, width: 235, height: 32),
      action: #selector(resetSettings(_:)))
    resetButton = reset
    content.addSubview(reset)
    window.center()
  }

  @objc private func recordHotkey(_ sender: Any?) {
    if recording {
      finishRecording()
      refreshStatus()
      return
    }
    guard settingsValid else { return }
    recording = true
    runtime.setRecording(true)
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: hotkeyRecordingMask) {
      [weak self] event in
      guard let self = self, let window = self.settingsWindow,
        shouldCaptureRecordingEvent(
          recording: self.recording,
          ownedSettingsWindowIsKey: NSApp.keyWindow === window,
          type: event.type, code: event.keyCode)
      else { return event }
      self.captureHotkey(event)
      return nil
    }
    if localMonitor == nil {
      finishRecording()
      notice = "Не удалось начать запись клавиши"
    }
    refreshStatus()
  }

  private func captureHotkey(_ event: NSEvent) {
    if event.keyCode == kVK_Escape {
      finishRecording()
      refreshStatus()
      return
    }
    // isARepeat is undefined for flagsChanged, including Caps Lock.
    if event.type == .keyDown && event.isARepeat { return }
    let flags = UInt64(event.modifierFlags.rawValue)
    guard canRecordHotkey(code: event.keyCode, flags: flags) else {
      hotkeyLabel?.stringValue = "Клавиша не поддерживается; Esc — отмена"
      return
    }
    var updated = settings
    updated.bound = true
    updated.keycode = event.keyCode
    updated.modifiers = flags & allowedHotkeyModifiers
    // A modal alert's Return/Escape must not recursively record a binding.
    removeRecordingMonitor()
    var confirmed = true
    if updated.keycode == kVK_CapsLock {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Caps Lock — только исправление слова"
      alert.informativeText =
        "При активной работе Caps Lock будет выключаться. В настройках клавиатуры macOS "
        + "отключите системное переключение источников ввода клавишей Caps Lock: приложение не меняет эту настройку. "
        + "На паузе, при защищённом вводе и после выхода действует обычное поведение Caps Lock."
      alert.addButton(withTitle: "Назначить")
      alert.addButton(withTitle: "Отмена")
      confirmed = alert.runModal() == .alertFirstButtonReturn
    } else if requiresPrintableKeyConfirmation(code: updated.keycode, modifiers: updated.modifiers)
    {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Эта клавиша будет перехватываться глобально"
      alert.informativeText =
        "Обычный ввод этой печатной клавиши (также с выбранным Shift) "
        + "станет командой исправления. Конфликты с другими приложениями не проверяются."
      alert.addButton(withTitle: "Назначить")
      alert.addButton(withTitle: "Отмена")
      confirmed = alert.runModal() == .alertFirstButtonReturn
    }
    finishRecording()
    if confirmed { saveSettings(updated) } else { refreshStatus() }
  }

  private func removeRecordingMonitor() {
    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
      localMonitor = nil
    }
  }

  private func finishRecording() {
    removeRecordingMonitor()
    if recording {
      recording = false
      runtime.setRecording(false)
    }
  }

  @objc private func clearHotkey(_ sender: Any?) {
    finishRecording()
    var updated = settings
    updated.bound = false
    updated.keycode = 0
    updated.modifiers = 0
    saveSettings(updated)
  }

  func windowWillClose(_ notification: Notification) {
    finishRecording()
    refreshStatus()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    // Refresh on return from system settings, without polling or tap restart.
    refreshStatus()
  }

  func windowDidResignKey(_ notification: Notification) {
    finishRecording()
    refreshStatus()
  }

  func applicationDidResignActive(_ notification: Notification) {
    finishRecording()
    refreshStatus()
  }

  private func handleReport(_ status: UInt32) {
    guard !terminating else { return }
    switch status {
    case 0, 6:
      notice = nil
    case 1:
      workerFailed = true
    case 2:
      notice = "Текст изменён, но раскладка не переключена"
    case 3:
      tapFailed = true
    case 10, 4:
      let failure = runtime.replacementFailure
      if failure != 0 {
        actionSuppressed = failure == 4
        partialFailure = true
        paused = true
        runtime.setPaused(true)
        runtime.invalidate()
      }
    case 5:
      notice = "Enter/Tab без исправления: служебное пробуждение недоступно"
    case 7:
      // A late report from a former Caps binding cannot pause a new one.
      if settings.bound && settings.keycode == kVK_CapsLock {
        capsLockFailure = true
        paused = true
        runtime.setPaused(true)
      }
    case 8:
      capsLockFailure = false
    case 9:
      // Logging failure never pauses or invalidates correction.
      refreshDiagnosticControls()
      return
    default:
      workerFailed = true
    }
    refreshStatus()
  }

  func shutdown() {
    guard !terminating else { return }
    terminating = true
    finishRecording()
    runtime.setAutomatic(false)
    runtime.setPaused(true)
    runtime.stop()
    runtime.onReport = nil
    DiagnosticLogger.shared.onError = nil
    statusMenu?.delegate = nil
    settingsWindow?.delegate = nil
    settingsWindow?.close()
    if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
  }

  @objc private func quit(_ sender: Any?) {
    shutdown()
    // terminate exits the process. Stop/wake so main can join its worker.
    if NSApp.modalWindow != nil { NSApp.stopModal(withCode: .abort) }
    NSApp.stop(nil)
    if let wake = NSEvent.otherEvent(
      with: .applicationDefined, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, subtype: 0, data1: 0, data2: 0)
    {
      NSApp.postEvent(wake, atStart: true)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    quit(nil)
    return .terminateCancel
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) { shutdown() }
}
