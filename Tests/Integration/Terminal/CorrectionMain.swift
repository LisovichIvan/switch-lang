import AppKit
import ApplicationServices
import Carbon
import IOKit
import IOKit.hidsystem

private let commandName = Notification.Name("local.switch-lang.terminal-fixture.command")
private let stateName = Notification.Name("local.switch-lang.terminal-fixture.state")
private let driverTag: Int64 = 0x5357_4C54_4553_5431

private struct Scenario {
  let name: String
  let layout: Layout
  let keys: [UInt16]
  let expected: Int
  var automatic = false
  var action: UInt16? = nil
  var shift = false
  var caps = false
}

private let scenarios = [
  Scenario(
    name: "terminal-first-prompt-en-ru", layout: .english, keys: [5, 4, 11, 2, 17, 45], expected: 2),
  Scenario(
    name: "terminal-following-prompt-ru-en", layout: .russian, keys: [4, 14, 37, 37, 31],
    expected: 4),
]

private final class Driver: NSObject, NSApplicationDelegate {
  let runtime: KeyboardRuntime
  let worker: CorrectionWorker
  let session: String
  let terminalPID: pid_t
  let directory = TerminalIntegrationConfiguration.directory
  private var launcher: TerminalLaunch?
  private var observer: NSObjectProtocol?
  private var activationObserver: NSObjectProtocol?
  private var deadline: DispatchWorkItem?
  private var source: CGEventSource?
  private var originalSource: TISInputSource?
  private var pendingUp: CGEvent?
  private var cleanup: DispatchSourceProcess?
  private var adapter: ScopedInputAdapter?
  private var rawCaps: io_connect_t = 0
  private var fixturePID: pid_t = 0
  private var results: [[String: Any]] = []
  private var state: [String: Any] = [:]
  private var stage = "launch"
  private var finished = false
  private var workerStarted = false
  private var scenarioIndex = -1
  private var request = 0
  private var keyIndex = 0
  private var keyAwaiting = false
  private var success = false

  init(session: String, terminalPID: pid_t) throws {
    self.session = session
    self.terminalPID = terminalPID
    let queue = InputQueue()
    runtime = try KeyboardRuntime(submitInput: { queue.trySubmit($0) })
    worker = CorrectionWorker(queue: queue, runtime: runtime)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightListenEventAccess(),
      !IsSecureEventInputEnabled(), let source = CGEventSource(stateID: .privateState)
    else {
      finish("effective-access-unavailable")
      return
    }
    self.source = source
    source.userData = driverTag
    source.localEventsSuppressionInterval = 0
    originalSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    _ = DiagnosticLogger.shared.setEnabled(true, path: directory + "/correction/runtime.log")
    runtime.onReport = { [weak self] code in
      guard let self, !self.finished else { return }
      if code == 0 {
        self.success = true
        self.checkProgress()
      }
      if [UInt32(1), 3, 4, 7, 10].contains(code) { self.finish("runtime-report-\(code)") }
    }
    observer = DistributedNotificationCenter.default().addObserver(
      forName: stateName, object: session, queue: .main
    ) { [weak self] notification in self?.receive(notification) }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self, !self.finished, self.fixturePID > 0,
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        application.processIdentifier != self.terminalPID, application.processIdentifier != getpid()
      else { return }
      self.finish("foreign-focus-interruption")
    }
    armDeadline("fixture-startup-timeout", seconds: 15)
    do { launcher = try TerminalLaunch(pid: terminalPID) } catch {
      finish("launcher-unavailable")
      return
    }
    guard NSRunningApplication(processIdentifier: terminalPID)?.activate(options: []) == true,
      launcher?.openNewCommand() == true
    else {
      finish("new-command-unavailable")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
      guard !finished else { return }
      guard launcher?.runFixture(session: session, directory: directory) == true else {
        finish("new-command-dialog-unconfirmed")
        return
      }
    }
  }

  private func command(_ name: String) {
    request += 1
    DistributedNotificationCenter.default().postNotificationName(
      commandName, object: session,
      userInfo: ["command": name, "request": request], deliverImmediately: true)
  }

  private func number(_ key: String) -> Int { (state[key] as? NSNumber)?.intValue ?? -1 }

  private func receive(_ notification: Notification) {
    guard !finished, let received = notification.userInfo as? [String: Any],
      let pid = received["pid"] as? NSNumber, pid.int32Value > 0
    else { return }
    if fixturePID == 0 {
      guard stage == "launch" else { return }
      stage = "fixture-identification"
      guard NSRunningApplication(processIdentifier: terminalPID)?.activate(options: []) == true
      else {
        finish("fixture-activation-unavailable")
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
        guard !finished else { return }
        guard launcher?.identifyFixtureWindow() != nil, launcher?.focusedFixtureElement() != nil
        else {
          finish("fixture-window-unconfirmed")
          return
        }
        fixturePID = pid.int32Value
        state = received
        worker.start()
        workerStarted = true
        runtime.setHotkey(code: 97, modifiers: 0, bound: true)
        runtime.setAutomatic(false)
        guard runtime.begin() else {
          finish("runtime-start-failed")
          return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
          guard !finished, runtime.isListening else {
            finish("listener-start-unconfirmed")
            return
          }
          do {
            let adapter = try ScopedInputAdapter(runtime: runtime, fixturePID: terminalPID) {
              [weak self] in self?.finish("adapter-failed")
            }
            self.adapter = adapter
            adapter.start { [weak self] ready in
              guard let self, !self.finished else { return }
              guard ready,
                NSRunningApplication(processIdentifier: self.terminalPID)?.activate(options: [])
                  == true
              else {
                self.finish("adapter-or-activation-unavailable")
                return
              }
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if !self.finished { self.nextScenario() }
              }
            }
          } catch { finish("adapter-initialization-failed") }
        }
      }
      return
    }
    guard fixturePID == pid.int32Value else {
      finish("fixture-pid-changed")
      return
    }
    state = received
    if stage == "reset", number("request") == request, number("match") == 0 {
      configureScenario()
    } else if stage == "awaiting-following-prompt", number("match") == 0, number("returns") == 1 {
      guard !keyAwaiting,
        KeyboardLayouts.sourceLayout(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())
          == .russian
      else {
        finish("following-prompt-unconfirmed")
        return
      }
      // No test reset, explicit runtime invalidation, reconfiguration or source
      // selection between prompts. This is one continuous Terminal input session.
      scenarioIndex = 1
      success = false
      keyIndex = 0
      stage = "typing"
      sendNext()
    } else {
      checkProgress()
    }
  }

  private func nextScenario() {
    scenarioIndex += 1
    if scenarioIndex == scenarios.count {
      finish("completed")
      return
    }
    guard launcher?.focusedFixtureElement() != nil else {
      finish("fixture-focus-lost")
      return
    }
    stage = "reset"
    success = false
    runtime.invalidate()
    armDeadline("scenario-timeout", seconds: 5)
    command("reset")
  }

  private func configureScenario() {
    stage = "configuring"
    let scenario = scenarios[scenarioIndex]
    runtime.setAutomatic(scenario.automatic)
    runtime.setHotkey(code: scenario.caps ? 57 : 97, modifiers: 0, bound: true)
    guard launcher?.focusedFixtureElement() != nil,
      let target = KeyboardLayouts.copyTargetSource(scenario.layout),
      TISSelectInputSource(target) == noErr
    else {
      finish("layout-unavailable")
      return
    }
    // Test pacing only, not part of runtime and not a latency benchmark.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
      guard !finished,
        KeyboardLayouts.sourceLayout(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())
          == scenario.layout,
        !scenario.caps || runtime.capsLockReady.boolValue
      else {
        finish("scenario-configuration-unconfirmed")
        return
      }
      stage = "typing"
      keyIndex = 0
      sendNext()
    }
  }

  private func sendNext() {
    guard !finished, !keyAwaiting, scenarioIndex >= 0, scenarioIndex < scenarios.count else {
      return
    }
    let scenario = scenarios[scenarioIndex]
    if keyIndex == scenario.keys.count {
      stage = "typed"
      let index = scenarioIndex
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
        guard !finished, scenarioIndex == index, stage == "typed" else { return }
        if scenario.automatic && scenario.action == nil {
          checkProgress()
          return
        }
        if scenario.automatic && runtime.actionCandidate.value == 0 {
          finish("action-candidate-unavailable")
          return
        }
        stage = "correcting"
        if scenario.caps {
          postCaps()
        } else {
          postKey(scenario.action ?? 97, shift: false, continuation: {})
        }
      }
      return
    }
    postKey(scenario.keys[keyIndex], shift: scenario.shift && keyIndex == 0) { [self] in
      keyIndex += 1
      sendNext()
    }
  }

  private func postKey(_ key: UInt16, shift: Bool, continuation: @escaping () -> Void) {
    guard let source, launcher?.focusedFixtureElement() != nil, !IsSecureEventInputEnabled(),
      let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    else {
      finish("fixture-input-unconfirmed")
      return
    }
    down.flags = shift ? .maskShift : []
    up.flags = down.flags
    down.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(LMGetKbdType()))
    up.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(LMGetKbdType()))
    keyAwaiting = true
    pendingUp = up
    down.postToPid(terminalPID)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [self] in
      pendingUp?.postToPid(terminalPID)
      pendingUp = nil
      keyAwaiting = false
      if !finished {
        continuation()
        checkProgress()
      }
    }
  }

  private func postCaps() {
    let service = IOServiceGetMatchingService(mach_port_t(0), IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else {
      finish("caps-service-unavailable")
      return
    }
    defer { IOObjectRelease(service) }
    guard
      IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &rawCaps)
        == KERN_SUCCESS,
      rawCaps != 0
    else {
      finish("caps-connection-unavailable")
      return
    }
    var locked = false
    guard IOHIDGetModifierLockState(rawCaps, Int32(kIOHIDCapsLockState), &locked) == KERN_SUCCESS,
      !locked, launcher?.focusedFixtureElement() != nil,
      IOHIDSetModifierLockState(rawCaps, Int32(kIOHIDCapsLockState), true) == KERN_SUCCESS,
      let source, let event = CGEvent(keyboardEventSource: source, virtualKey: 57, keyDown: true)
    else {
      finish("caps-initial-state-unconfirmed")
      return
    }
    event.type = .flagsChanged
    event.flags = .maskAlphaShift
    event.postToPid(terminalPID)
  }

  private func checkProgress() {
    guard !finished, scenarioIndex >= 0, scenarioIndex < scenarios.count,
      ["typed", "correcting"].contains(stage), success, !keyAwaiting
    else { return }
    let scenario = scenarios[scenarioIndex]
    let returns = scenarioIndex == 1 ? 1 : 0
    let tabs = scenario.action == 48 ? 1 : 0
    guard number("match") == scenario.expected, number("returns") == returns,
      number("tabs") == tabs,
      scenario.action == nil || number("actionMatch") == scenario.expected,
      runtime.replacementFailure == 0,
      KeyboardLayouts.sourceLayout(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())
        == scenario.layout.opposite
    else { return }
    if scenario.caps {
      var locked = true
      guard IOHIDGetModifierLockState(rawCaps, Int32(kIOHIDCapsLockState), &locked) == KERN_SUCCESS,
        !locked
      else {
        finish("caps-not-cleared")
        return
      }
    }
    results.append(["scenario": scenario.name, "passed": true, "returns": returns, "tabs": tabs])
    if scenarioIndex == 0 {
      stage = "awaiting-following-prompt"
      success = false
      postKey(36, shift: false, continuation: {})
    } else {
      stage = "completed-scenario"
      nextScenario()
    }
  }

  private func armDeadline(_ reason: String, seconds: Double) {
    deadline?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.finish(reason) }
    deadline = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  private func finish(_ reason: String) {
    guard !finished else { return }
    finished = true
    deadline?.cancel()
    pendingUp?.postToPid(terminalPID)
    pendingUp = nil
    adapter?.stopAcceptingInput()
    runtime.stop()
    runtime.waitUntilStopped()
    if workerStarted { worker.stopAndWait() }
    adapter?.stopAndWait()
    DiagnosticLogger.shared.shutdown()
    if let originalSource, launcher?.focusedFixtureElement() != nil {
      _ = TISSelectInputSource(originalSource)
    }
    if rawCaps != 0 {
      _ = IOHIDSetModifierLockState(rawCaps, Int32(kIOHIDCapsLockState), false)
      IOServiceClose(rawCaps)
      rawCaps = 0
    }
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
    let result: [String: Any] = [
      "reason": reason, "session": session, "pid": getpid(),
      "fixturePID": fixturePID, "terminalPID": terminalPID, "planned": scenarios.count,
      "results": results, "stage": stage, "scenarioIndex": scenarioIndex,
      "fixtureMatch": number("match"), "fixtureDeletions": number("deletions"),
      "failureLatch": runtime.replacementFailure,
      "targetFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == terminalPID,
      "probeFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
      "scope":
        "original handler body, worker, AX and executor; targeted diagnostic adapter, not physical/session input",
      "userCommandsRead": false, "userCommandsExecuted": false,
      "setupStage": launcher?.setupStage ?? "none", "setupCounts": launcher?.setupCounts ?? [:],
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(
        to: URL(fileURLWithPath: directory + "/correction/result.json"), options: .atomic)
    }
    if fixturePID > 0 {
      let cleanup = DispatchSource.makeProcessSource(
        identifier: fixturePID, eventMask: .exit, queue: .main)
      self.cleanup = cleanup
      cleanup.setEventHandler { [self] in
        self.cleanup?.cancel()
        self.cleanup = nil
        launcher?.closeOwnedUI()
        NSApp.terminate(nil)
      }
      cleanup.resume()
      command("quit")
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
    } else {
      launcher?.closeOwnedUI()
      NSApp.terminate(nil)
    }
  }
}

@main
private struct Main {
  static func main() {
    let args = CommandLine.arguments
    if args.count == 2, args[1] == "--self-test" {
      do {
        _ =
          try runCoreTests() + runSettingsTests() + runCapsLockTests() + runKeyboardEventsTests()
          + runRuntimeTests() + runWorkerTests() + runAtomicTests()
      } catch { exit(1) }
      return
    }
    guard args.count == 5, args[1] == "--session", UUID(uuidString: args[2]) != nil,
      args[3] == "--target-pid", let pid = Int32(args[4]), pid > 0
    else { exit(2) }
    do {
      let application = NSApplication.shared
      application.setActivationPolicy(.accessory)
      let delegate = try Driver(session: args[2], terminalPID: pid)
      application.delegate = delegate
      withExtendedLifetime(delegate) { application.run() }
      application.delegate = nil
    } catch { exit(1) }
  }
}
