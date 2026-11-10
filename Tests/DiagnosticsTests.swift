import Darwin
import Dispatch
import Foundation

// Independent wire expectations from native/diagnostics.h/.m, including gaps.
private let diagnosticStageExpectations: [(DiagnosticStage, UInt32, String)] = [
  (.loggingStarted, 1, "logging.started"), (.loggingStopped, 2, "logging.stopped"),
  (.capsObservedOn, 10, "caps.observed_on"), (.capsObservedOff, 11, "caps.observed_off"),
  (.capsBlocked, 12, "caps.blocked"), (.capsConfigurationReady, 13, "caps.configuration_ready"),
  (.capsConfigurationBlocked, 14, "caps.configuration_blocked"),
  (.capsResetQueued, 15, "caps.reset_queued"), (.capsResetCoalesced, 16, "caps.reset_coalesced"),
  (.capsControllerOpen, 17, "caps.controller_open"), (.capsRead, 18, "caps.read"),
  (.capsClear, 19, "caps.clear"), (.capsResetFailed, 20, "caps.reset_failed"),
  (.capsResetVerified, 21, "caps.reset_verified"), (.capsNoTransition, 22, "caps.no_transition"),
  (.capsModifiersRejected, 23, "caps.modifiers_rejected"),
  (.capsGenerationChanged, 24, "caps.generation_changed"),
  (.capsCommandQueued, 25, "caps.command_queued"),
  (.capsCommandQueueFull, 26, "caps.command_queue_full"),
  (.manualReceived, 40, "manual.received"), (.manualExpired, 41, "manual.expired"),
  (.manualGenerationGap, 42, "manual.generation_gap"),
  (.manualFocusLayoutChanged, 43, "manual.focus_layout_changed"),
  (.manualContextRefused, 44, "manual.context_refused"),
  (.manualNoCandidate, 45, "manual.no_candidate"),
  (.manualReplacementResult, 46, "manual.replacement_result"),
  (.contextUnavailable, 60, "context.unavailable"),
  (.contextFocusedElement, 61, "context.focused_element"),
  (.contextElementIdentity, 62, "context.element_identity"),
  (.contextElementRole, 63, "context.element_role"),
  (.contextElementSubrole, 64, "context.element_subrole"),
  (.contextFocusedFlag, 65, "context.focused_flag"),
  (.contextEnabledFlag, 66, "context.enabled_flag"),
  (.contextProtectedContent, 67, "context.protected_content"),
  (.contextSelectionCount, 68, "context.selection_count"),
  (.contextRangeWritable, 69, "context.range_writable"),
  (.contextTextWritable, 70, "context.text_writable"),
  (.contextRangeRead, 71, "context.range_read"),
  (.contextLayoutUnsupported, 72, "context.layout_unsupported"),
  (.contextCaretChanged, 73, "context.caret_changed"),
  (.contextKeyTranslation, 74, "context.key_translation"), (.contextReady, 75, "context.ready"),
  (.contextEditable, 76, "context.editable"),
  (.contextCharacterCount, 77, "context.character_count"),
  (.replacementRefused, 90, "replacement.refused"),
  (.replacementRangeRead, 91, "replacement.range_read"),
  (.replacementSelectionWrite, 92, "replacement.selection_write"),
  (.replacementSelectionVerification, 93, "replacement.selection_verification"),
  (.replacementTextWrite, 94, "replacement.text_write"),
  (.replacementPositionVerification, 95, "replacement.position_verification"),
  (.replacementLayoutSwitch, 96, "replacement.layout_switch"),
  (.replacementKeyboardPlan, 97, "replacement.keyboard_plan"),
  (.replacementKeyboardDelete, 98, "replacement.keyboard_delete"),
  (.replacementKeyboardTyped, 99, "replacement.keyboard_typed"),
  (.replacementActionSuppressed, 100, "replacement.action_suppressed"),
]

private struct DiagnosticTestRecord {
  let stage: String
  let detail: Int32
}

private struct DiagnosticTestContents {
  var records: [DiagnosticTestRecord] = []
  var dropped: UInt64 = 0
}

private func diagnosticTestRead(_ path: String) throws -> DiagnosticTestContents {
  let text = try String(contentsOfFile: path, encoding: .utf8)
  try requireTest(text.hasSuffix("\n"), "diagnostics: complete final line")
  try requireTest(
    text.utf8.allSatisfy { $0 == 10 || (32...126).contains($0) }, "diagnostics: ASCII-only format")
  let names = Set(diagnosticStageExpectations.map { $0.2 })
  var result = DiagnosticTestContents()
  var previousTimestamp: UInt64 = 0
  for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
    if line.hasPrefix("dropped=") {
      guard let lost = UInt64(line.dropFirst(8)) else {
        throw TestFailure(description: "diagnostics: numeric drops")
      }
      let sum = result.dropped.addingReportingOverflow(lost)
      try requireTest(
        !sum.overflow && line == "dropped=\(lost)" && line.utf8.count < 64,
        "diagnostics: bounded canonical drop count")
      result.dropped = sum.partialValue
      continue
    }
    let fields = line.split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0].hasPrefix("ns="), fields[1].hasPrefix("stage="),
      fields[2].hasPrefix("code="), let timestamp = UInt64(fields[0].dropFirst(3)),
      let detail = Int32(fields[2].dropFirst(5))
    else {
      throw TestFailure(description: "diagnostics: fixed numeric record format")
    }
    let stage = String(fields[1].dropFirst(6))
    try requireTest(
      names.contains(stage) && timestamp >= previousTimestamp && line.utf8.count < 160
        && line == "ns=\(timestamp) stage=\(stage) code=\(detail)",
      "diagnostics: recognized stage, ordered timestamp, canonical bounded record")
    previousTimestamp = timestamp
    result.records.append(DiagnosticTestRecord(stage: stage, detail: detail))
  }
  return result
}

private func diagnosticTestState(_ path: String) throws -> stat {
  var state = stat()
  try requireTest(lstat(path, &state) == 0, "diagnostics: inspect isolated file")
  return state
}

private func diagnosticTestWrite(_ descriptor: Int32, _ text: String) throws {
  let success = text.withCString { bytes -> Bool in
    var position = 0
    let length = text.utf8.count
    while position < length {
      let written = Darwin.write(descriptor, bytes.advanced(by: position), length - position)
      if written < 0 {
        if errno == EINTR { continue }
        return false
      }
      if written == 0 { return false }
      position += written
    }
    return true
  }
  try requireTest(success, "diagnostics: write synthetic fixture")
}

private func diagnosticTestCreate(_ path: String, mode: mode_t = 0o600) throws {
  let descriptor = Darwin.open(
    path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode)
  try requireTest(descriptor >= 0, "diagnostics: create isolated fixture")
  var closed = false
  defer { if !closed { _ = Darwin.close(descriptor) } }
  // Make unsafe-mode fixtures independent of the caller's normal umask.
  try requireTest(fchmod(descriptor, mode) == 0, "diagnostics: synthetic fixture mode")
  let result = Darwin.close(descriptor)
  closed = true
  try requireTest(result == 0, "diagnostics: synthetic fixture closed")
}

private func diagnosticTestFill(_ descriptor: Int32, existing: Int64) throws -> Int64 {
  let line = "ns=1 stage=manual.received code=0\n"
  let remaining = (1024 * 1024 - Int(existing)) / line.utf8.count
  try requireTest(remaining >= 0, "diagnostics: fixture within file limit")
  try diagnosticTestWrite(descriptor, String(repeating: line, count: remaining))
  return existing + Int64(remaining * line.utf8.count)
}

private func diagnosticTestPumpMain(until condition: () -> Bool) -> Bool {
  let deadline = Date(timeIntervalSinceNow: 5)
  while !condition() && Date() < deadline {
    _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
  }
  return condition()
}

// No singleton, defaults, GUI, TCC, keychain, user-log path, or global writes.
// All fixtures are synthetic and confined to this invocation's workspace .tools.
func runDiagnosticsTests() throws -> Int {
  try requireTest(Thread.isMainThread, "diagnostics: control tests run on main")
  let tools = Darwin.open(".tools", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
  try requireTest(tools >= 0, "diagnostics: real workspace .tools directory")
  defer { _ = Darwin.close(tools) }
  let directoryName = "diagnostics-swift-" + UUID().uuidString
  let root = FileManager.default.currentDirectoryPath + "/.tools/" + directoryName
  try requireTest(
    mkdirat(tools, directoryName, 0o700) == 0, "diagnostics: private workspace directory")
  var removed = false
  defer { if !removed { try? FileManager.default.removeItem(atPath: root) } }
  let path = root + "/events.log"
  let logger = DiagnosticLogger()
  defer { logger.shutdown() }
  var assertions = 0
  func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    try requireTest(condition(), "diagnostics: " + name)
    assertions += 1
  }

  try check(DiagnosticStage.none.rawValue == 0, "none numeric value")
  for (stage, value, _) in diagnosticStageExpectations {
    try check(stage.rawValue == value, "stage numeric value")
  }
  try check(!logger.isEnabled && logger.lastError == 0 && logger.onError == nil, "default disabled")
  logger.shutdown()
  logger.setContextStatus(.contextTextWritable, -1234)
  logger.recordContextStatus()
  logger.record(.manualReceived)
  try check(
    logger.setEnabled(false, path: path) && logger.writerQueue == nil, "off stays uninitialized")
  try check(access(path, F_OK) != 0 && errno == ENOENT, "off creates no file")

  try check(logger.setEnabled(true, path: path) && logger.isEnabled, "enable")
  try check(logger.setEnabled(true, path: nil), "already-enabled ignores path")
  guard let queue = logger.writerQueue, let originalSource = logger.source else {
    throw TestFailure(description: "diagnostics: initialized writer")
  }
  queue.sync {
    logger.recordContextStatus()
    logger.setContextStatus(.none, Int32.max)
    logger.recordContextStatus()
    logger.record(.none, 123)
    logger.record(.manualReplacementResult, Int32.min)
    logger.record(.replacementPositionVerification, Int32.max)
  }
  try check(logger.setEnabled(false, path: nil) && !logger.isEnabled, "disable drains and closes")
  let initial = try diagnosticTestRead(path)
  try check(
    initial.dropped == 0 && initial.records.count == 6, "accepted records and lifecycle only")
  try check(
    initial.records[1].stage == "context.text_writable" && initial.records[1].detail == -1234,
    "context updated while off is retained")
  try check(
    initial.records[2].stage == "context.unavailable" && initial.records[2].detail == 0,
    "invalid context is unavailable without stale code")
  try check(
    initial.records[3].detail == Int32.min && initial.records[4].detail == Int32.max,
    "signed detail bounds")
  let initialState = try diagnosticTestState(path)
  try check(
    initialState.st_uid == geteuid() && initialState.st_nlink == 1
      && initialState.st_mode & 0o7777 == 0o600
      && initialState.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
    "regular single-link owned 0600 file")
  logger.record(.manualReceived, 91)
  logger.recordContextStatus()
  logger.setContextStatus(.contextReady, 1)
  try check(logger.setEnabled(false, path: nil), "repeated off")
  queue.sync {}
  let offState = try diagnosticTestState(path)
  try check(
    initialState.st_size == offState.st_size
      && initialState.st_mtimespec.tv_sec == offState.st_mtimespec.tv_sec
      && initialState.st_mtimespec.tv_nsec == offState.st_mtimespec.tv_nsec, "off does not write")

  // All fixed names, including the keyboard replacement stages, are tested
  // independently of the production name switch. Consumer is held, not ring.
  try check(logger.setEnabled(true, path: path), "wire mapping session")
  queue.sync { for (stage, _, _) in diagnosticStageExpectations { logger.record(stage, -7) } }
  try check(logger.setEnabled(false, path: nil), "wire mapping drained")
  let allStages = try diagnosticTestRead(path)
  let wireRecords = allStages.records.dropFirst(initial.records.count + 1).dropLast()
  try check(
    wireRecords.map { $0.stage } == diagnosticStageExpectations.map { $0.2 }, "all fixed wire names"
  )
  try check(
    wireRecords.allSatisfy { $0.detail == -7 } && allStages.dropped == 0, "all wire numeric details"
  )

  try check(logger.setEnabled(true, path: path), "bounded queue session")
  try check(logger.source === originalSource, "source retained across toggles")
  var exactDrops = false
  var accepted = 0
  queue.sync {
    for _ in 0..<(128 + 17) { logger.record(.manualReceived, 2) }
    logger.ringLock.lock()
    logger.record(.capsRead, -1)  // Must return, not wait for this lock.
    let full = logger.count == 128
    logger.ringLock.unlock()
    exactDrops = full && logger.drain()
    DispatchQueue.concurrentPerform(iterations: 4) { producer in
      for _ in 0..<256 { logger.record(.capsRead, Int32(producer)) }
    }
    accepted = logger.count
  }
  try check(exactDrops && accepted > 0 && accepted <= 128, "fixed ring and forced try-lock drop")
  try check(logger.setEnabled(false, path: nil), "bounded queue drained")
  let bounded = try diagnosticTestRead(path)
  try check(
    bounded.dropped == UInt64(18 + 1024 - accepted), "exact capacity and parallel-contention drops")
  try check(
    bounded.records.count == allStages.records.count + 2 + 128 + accepted, "bounded accepted count")

  // Parallel context updates must remain one numeric pair, never a torn
  // stage/detail. Losing overlapping setters may be superseded, not queued.
  let contextLogger = DiagnosticLogger()
  defer { contextLogger.shutdown() }
  let contextPath = root + "/context.log"
  try check(contextLogger.setEnabled(true, path: contextPath), "parallel context session")
  guard let contextQueue = contextLogger.writerQueue else {
    throw TestFailure(description: "diagnostics: context writer")
  }
  let contextCases: [(DiagnosticStage, Int32)] = [
    (.contextTextWritable, -1234), (.contextReady, Int32.min),
    (.contextProtectedContent, Int32.max), (.capsRead, 123),
  ]
  contextQueue.sync {
    DispatchQueue.concurrentPerform(iterations: contextCases.count) { producer in
      for _ in 0..<256 {
        contextLogger.setContextStatus(contextCases[producer].0, contextCases[producer].1)
        contextLogger.recordContextStatus()
      }
    }
  }
  try check(contextLogger.setEnabled(false, path: nil), "parallel context drained")
  let concurrentContext = try diagnosticTestRead(contextPath)
  let contextRecords = concurrentContext.records.dropFirst().dropLast()
  try check(
    !contextRecords.isEmpty && UInt64(contextRecords.count) + concurrentContext.dropped == 1024,
    "parallel context records bounded and drops accounted")
  try check(
    contextRecords.allSatisfy {
      ($0.stage == "context.text_writable" && $0.detail == -1234)
        || ($0.stage == "context.ready" && $0.detail == Int32.min)
        || ($0.stage == "context.protected_content" && $0.detail == Int32.max)
        || ($0.stage == "context.unavailable" && $0.detail == 0)
    }, "concurrent context snapshot never torn")
  contextLogger.shutdown()

  // Writer is held until disable has closed admission, so the sentinel must
  // be drained by off, not by an earlier event handler. Producers remain live
  // through repeated toggles and off-state stability checks.
  try check(logger.setEnabled(true, path: path), "concurrent-disable session")
  let blocked = DispatchSemaphore(value: 0)
  let releaseWriter = DispatchSemaphore(value: 0)
  let ready = DispatchSemaphore(value: 0)
  let workers = DispatchGroup()
  let releaser = DispatchGroup()
  let running = SharedValue(true)
  let observedDisabled = SharedValue(false)
  queue.async {
    blocked.signal()
    releaseWriter.wait()
  }
  let writerBlocked = blocked.wait(timeout: .now() + 5) == .success
  if !writerBlocked { releaseWriter.signal() }
  try check(writerBlocked, "writer test barrier")
  logger.record(.manualReplacementResult, -2025)
  for producer in 0..<4 {
    workers.enter()
    DispatchQueue.global().async {
      defer { workers.leave() }
      ready.signal()
      while running.withLock({ $0 }) {
        for _ in 0..<64 { logger.record(.capsRead, Int32(producer)) }
      }
    }
  }
  // Always join workers before throwing, including failures in this block.
  do {
    for _ in 0..<4 {
      try check(ready.wait(timeout: .now() + 5) == .success, "parallel producer ready")
    }
    releaser.enter()
    DispatchQueue.global().async {
      defer {
        releaser.leave()
        releaseWriter.signal()
      }
      let deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 5_000_000_000
      while logger.isEnabled && clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < deadline {
        sched_yield()
      }
      observedDisabled.withLock { $0 = !logger.isEnabled }
    }
    let disabled = logger.setEnabled(false, path: nil)
    let released = releaser.wait(timeout: .now() + 10) == .success
    try check(
      disabled && released && observedDisabled.withLock { $0 },
      "off closes admission before writer barrier")
    let concurrent = try diagnosticTestRead(path)
    try check(
      concurrent.records.contains { $0.stage == "manual.replacement_result" && $0.detail == -2025 },
      "accepted pending sentinel survives disable")
    for _ in 0..<16 {
      try check(
        logger.setEnabled(true, path: path) && logger.setEnabled(false, path: nil),
        "live-producer toggle")
      let before = try diagnosticTestState(path)
      DispatchQueue.concurrentPerform(iterations: 512) { logger.record(.capsRead, Int32($0)) }
      queue.sync {}
      let after = try diagnosticTestState(path)
      try check(
        before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
          && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
        "post-disable concurrent no-write")
    }
  } catch {
    running.withLock { $0 = false }
    releaseWriter.signal()
    workers.wait()
    releaser.wait()
    throw error
  }
  running.withLock { $0 = false }
  workers.wait()
  releaser.wait()
  try check(
    !logger.isEnabled && logger.source === originalSource,
    "concurrent producers joined, source stable")
  let toggled = try diagnosticTestRead(path)
  // The earlier wire-name test intentionally emits lifecycle stages. Only
  // inspect sessions created after that test for stale-session writes.
  var insideSession = false
  var validLifecycle = true
  var validAdmission = true
  var stoppedSessions = 0
  for record in toggled.records.dropFirst(bounded.records.count) {
    if record.stage == "logging.started" {
      validLifecycle = validLifecycle && !insideSession
      insideSession = true
    } else if record.stage == "logging.stopped" {
      validLifecycle = validLifecycle && insideSession
      insideSession = false
      stoppedSessions += 1
    } else {
      validAdmission = validAdmission && insideSession
    }
  }
  try check(
    validLifecycle && stoppedSessions == 17 && !insideSession,
    "one closed lifecycle per concurrent session")
  try check(validAdmission, "no stale record outside enabled session")

  // Two real boundary rotations replace .1, never create .2, and never
  // exceed 1 MiB. Fixture contents are numeric synthetic records only.
  for _ in 0..<2 {
    let fixture = Darwin.open(path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    try check(fixture >= 0, "rotation fixture open")
    let seeded: Int64
    do { seeded = try diagnosticTestFill(fixture, existing: 0) } catch {
      _ = Darwin.close(fixture)
      throw error
    }
    try check(Darwin.close(fixture) == 0, "rotation fixture closed")
    let before = try diagnosticTestState(path)
    try check(
      logger.setEnabled(true, path: path) && logger.setEnabled(false, path: nil),
      "boundary rotation")
    let current = try diagnosticTestState(path)
    let backup = try diagnosticTestState(path + ".1")
    try check(
      current.st_size > 0 && current.st_size < seeded && current.st_size <= 1024 * 1024
        && backup.st_size == seeded && backup.st_size <= 1024 * 1024
        && backup.st_ino == before.st_ino,
      "bounded current and replaced backup identity")
    try check(
      current.st_mode & 0o7777 == 0o600 && backup.st_mode & 0o7777 == 0o600, "rotated modes")
  }
  try check(access(path + ".2", F_OK) != 0 && errno == ENOENT, "only one backup")

  try check(symlink("events.log", root + "/link.log") == 0, "leaf-symlink fixture")
  try check(mkdir(root + "/directory.log", 0o700) == 0, "directory fixture")
  try check(mkfifo(root + "/fifo.log", 0o600) == 0, "FIFO fixture")
  try check(symlink(".", root + "/linked-directory") == 0, "ancestor-symlink fixture")
  try diagnosticTestCreate(root + "/readonly.log", mode: 0o400)
  try diagnosticTestCreate(root + "/public.log", mode: 0o644)
  try diagnosticTestCreate(root + "/oversized.log")
  let oversized = Darwin.open(root + "/oversized.log", O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
  try check(oversized >= 0, "oversized fixture open")
  let oversizedResult = ftruncate(oversized, 1024 * 1024 + 1)
  let oversizedClose = Darwin.close(oversized)
  try check(oversizedResult == 0 && oversizedClose == 0, "oversized fixture created")
  let rejected: [(String?, Int32?)] = [
    (root + "/link.log", ELOOP), (root + "/directory.log", EINVAL),
    (root + "/fifo.log", EINVAL), (root + "/readonly.log", EACCES), (root + "/public.log", EACCES),
    (root + "/oversized.log", EFBIG), (root + "/linked-directory/unused.log", nil),
    (root + "/missing-directory/unused.log", ENOENT), (nil, EINVAL), ("", EINVAL),
    (root + "/.", EINVAL), (root + "/..", EINVAL), (root + "/", EINVAL),
    (root + "/" + String(repeating: "a", count: Int(NAME_MAX) - 1), ENAMETOOLONG),
    (String(repeating: "a", count: Int(PATH_MAX)), ENAMETOOLONG), (root + "/bad\0suffix", EINVAL),
  ]
  for (rejectedPath, expectedError) in rejected {
    let success = logger.setEnabled(true, path: rejectedPath)
    let reportedErrno = errno
    try check(
      !success && !logger.isEnabled && logger.lastError != 0 && reportedErrno == logger.lastError
        && (expectedError == nil || logger.lastError == expectedError),
      "unsafe path fails closed with original errno")
    try check(logger.setEnabled(false, path: nil), "off after refused enable")
  }
  try check(
    access(root + "/unused.log", F_OK) != 0 && errno == ENOENT,
    "ancestor rejection creates no target")
  try check(link(path, root + "/hardlink.log") == 0, "hardlink fixture")
  let beforeHardlink = try diagnosticTestState(path)
  try check(
    !logger.setEnabled(true, path: path) && logger.lastError == EACCES, "current hardlink rejected")
  let afterHardlink = try diagnosticTestState(path)
  try check(beforeHardlink.st_size == afterHardlink.st_size, "rejected hardlink not changed")
  try check(unlink(root + "/hardlink.log") == 0, "remove isolated hardlink")

  // Backup is validated before opening/changing current, not just on rotation.
  try check(
    unlink(path + ".1") == 0 && symlink("events.log", path + ".1") == 0, "unsafe backup fixture")
  let beforeBackup = try diagnosticTestState(path)
  try check(
    !logger.setEnabled(true, path: path) && logger.lastError == ELOOP,
    "backup symlink rejected before append")
  let afterBackup = try diagnosticTestState(path)
  try check(
    beforeBackup.st_size == afterBackup.st_size && unlink(path + ".1") == 0,
    "backup rejection preserves current")
  try diagnosticTestCreate(path + ".1", mode: 0o644)
  try check(
    !logger.setEnabled(true, path: path) && logger.lastError == EACCES,
    "unsafe backup mode rejected")
  try check(unlink(path + ".1") == 0 && link(path, path + ".1") == 0, "hardlinked backup fixture")
  try check(
    !logger.setEnabled(true, path: path) && logger.lastError == EACCES, "hardlinked backup rejected"
  )
  try check(unlink(path + ".1") == 0, "remove isolated backup hardlink")

  // Successful open resets the once-per-failure report. Force a real EBADF
  // write on a valid, read-only descriptor, even when the tests run as root.
  try check(
    logger.setEnabled(true, path: path) && logger.lastError == 0, "recover from path failure")
  // Drain old asynchronous reports before installing this failure observer.
  var reportsDrained = false
  DispatchQueue.main.async { reportsDrained = true }
  try check(diagnosticTestPumpMain { reportsDrained }, "main report barrier")
  var errorCallbacks = 0
  var callbackWasMain = true
  logger.onError = {
    errorCallbacks += 1
    callbackWasMain = callbackWasMain && Thread.isMainThread
  }
  var injectedFailure = false
  var writerErrno: Int32 = 0
  queue.sync {
    let replacement = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if replacement < 0 { return }
    let original = logger.descriptor
    logger.descriptor = replacement
    if Darwin.close(original) != 0 { return }
    logger.record(.manualReceived, 3)
    injectedFailure = !logger.drain()
    writerErrno = errno
  }
  try check(
    injectedFailure && !logger.isEnabled && logger.lastError == EBADF && writerErrno == EBADF,
    "write failure disables only logger and preserves errno")
  try check(
    diagnosticTestPumpMain { errorCallbacks == 1 } && callbackWasMain,
    "failure callback once on main")
  let failedState = try diagnosticTestState(path)
  logger.record(.manualReceived, 4)
  try check(
    logger.setEnabled(false, path: nil) && logger.lastError == EBADF, "off preserves write error")
  queue.sync {}
  let afterFailure = try diagnosticTestState(path)
  try check(
    failedState.st_size == afterFailure.st_size && errorCallbacks == 1,
    "no repeated failure/write after disable")

  // Backup can become unsafe after enable; fail rotation without following it
  // or appending to the already-full current file. No retry or fallback path.
  try check(
    logger.setEnabled(true, path: path) && logger.lastError == 0, "fresh session clears write error"
  )
  var filled: Int64 = 0
  var rotationFailed = false
  var fixtureError: Error?
  queue.sync {
    do {
      let current = try diagnosticTestState(path)
      filled = try diagnosticTestFill(logger.descriptor, existing: current.st_size)
      try requireTest(symlink("events.log", path + ".1") == 0, "diagnostics: late backup fixture")
      logger.record(.replacementSelectionVerification, Int32.min)
      rotationFailed = !logger.drain()
      writerErrno = errno
    } catch { fixtureError = error }
  }
  if let fixtureError { throw fixtureError }
  try check(
    rotationFailed && !logger.isEnabled && logger.lastError == ELOOP && writerErrno == ELOOP,
    "unsafe late backup fails rotation preserving errno")
  let rotationState = try diagnosticTestState(path)
  try check(
    rotationState.st_size == filled && filled <= 1024 * 1024, "failed rotation did not append")
  logger.record(.manualReceived, 5)
  try check(
    logger.setEnabled(false, path: nil) && logger.lastError == ELOOP,
    "off preserves rotation failure")
  let afterRotation = try diagnosticTestState(path)
  try check(afterRotation.st_size == filled, "post-rotation-failure no write")
  try check(
    diagnosticTestPumpMain { errorCallbacks == 2 } && callbackWasMain,
    "one callback for new failed session")
  try check(
    !logger.setEnabled(true, path: path) && logger.lastError == ELOOP,
    "repeated unsafe enable refused")
  var repeatBarrier = false
  DispatchQueue.main.async { repeatBarrier = true }
  try check(
    diagnosticTestPumpMain { repeatBarrier } && errorCallbacks == 2,
    "failure notification not repeated until recovery")
  try check(unlink(path + ".1") == 0, "remove late unsafe backup")

  // A pathname replaced after enable must not redirect writes to a new file.
  try check(logger.setEnabled(true, path: path), "identity-check session")
  var staleFailed = false
  queue.sync {
    do {
      try requireTest(
        rename(path, root + "/detached.log") == 0, "diagnostics: detach current fixture")
      try diagnosticTestCreate(path)
      logger.record(.manualReceived, 6)
      staleFailed = !logger.drain()
      writerErrno = errno
    } catch { fixtureError = error }
  }
  if let fixtureError { throw fixtureError }
  try check(
    staleFailed && !logger.isEnabled && logger.lastError == ESTALE && writerErrno == ESTALE,
    "current inode replacement fails closed")
  let replacementState = try diagnosticTestState(path)
  try check(replacementState.st_size == 0, "replacement path never written")
  try check(diagnosticTestPumpMain { errorCallbacks == 3 }, "identity failure reported once")
  logger.onError = nil
  logger.shutdown()
  logger.shutdown()
  try check(
    logger.writerQueue == nil && logger.source == nil && !logger.isEnabled,
    "shutdown joins and releases source")
  try check(
    logger.setEnabled(true, path: path) && logger.setEnabled(false, path: nil),
    "reuse after complete shutdown")

  // Resource fallback must not leak a source cycle or deadlock when the last
  // reference is released on the writer rather than by explicit shutdown.
  let releasedPath = root + "/released.log"
  var transient: DiagnosticLogger? = DiagnosticLogger()
  weak let released = transient
  try check(
    transient?.setEnabled(true, path: releasedPath) == true, "owned transient logger enabled")
  guard let transientQueue = transient?.writerQueue else {
    throw TestFailure(description: "diagnostics: transient writer")
  }
  transientQueue.sync {
    transient?.record(.manualReceived, 321)
    transient = nil
  }
  try check(released == nil, "writer-thread destruction has no retain cycle")
  let releasedContents = try diagnosticTestRead(releasedPath)
  try check(
    releasedContents.records.map { $0.stage } == [
      "logging.started", "manual.received", "logging.stopped",
    ] && releasedContents.records[1].detail == 321, "writer-thread destruction drains and closes")
  logger.shutdown()
  try FileManager.default.removeItem(atPath: root)
  removed = true
  return assertions
}
