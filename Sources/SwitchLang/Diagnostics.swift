import Darwin
import Dispatch
import Foundation

// Only fixed technical outcomes belong here. Never pass input text, ordinary
// keys, character codes, field values, titles, or input-context paths as detail.
enum DiagnosticStage: UInt32 {
  case none = 0
  case loggingStarted = 1
  case loggingStopped = 2
  case capsObservedOn = 10
  case capsObservedOff = 11
  case capsBlocked = 12
  case capsConfigurationReady = 13
  case capsConfigurationBlocked = 14
  case capsResetQueued = 15
  case capsResetCoalesced = 16
  case capsControllerOpen = 17
  case capsRead = 18
  case capsClear = 19
  case capsResetFailed = 20
  case capsResetVerified = 21
  case capsNoTransition = 22
  case capsModifiersRejected = 23
  case capsGenerationChanged = 24
  case capsCommandQueued = 25
  case capsCommandQueueFull = 26
  case manualReceived = 40
  case manualExpired = 41
  case manualGenerationGap = 42
  case manualFocusLayoutChanged = 43
  case manualContextRefused = 44
  case manualNoCandidate = 45
  case manualReplacementResult = 46
  case contextUnavailable = 60
  case contextFocusedElement = 61
  case contextElementIdentity = 62
  case contextElementRole = 63
  case contextElementSubrole = 64
  case contextFocusedFlag = 65
  case contextEnabledFlag = 66
  case contextProtectedContent = 67
  case contextSelectionCount = 68
  case contextRangeWritable = 69
  case contextTextWritable = 70
  case contextRangeRead = 71
  case contextLayoutUnsupported = 72
  case contextCaretChanged = 73
  case contextKeyTranslation = 74
  case contextReady = 75
  case contextEditable = 76
  case contextCharacterCount = 77
  case replacementRefused = 90
  case replacementRangeRead = 91
  case replacementSelectionWrite = 92
  case replacementSelectionVerification = 93
  case replacementTextWrite = 94
  case replacementPositionVerification = 95
  case replacementLayoutSwitch = 96
  case replacementKeyboardPlan = 97
  case replacementKeyboardDelete = 98
  case replacementKeyboardTyped = 99
  case replacementActionSuppressed = 100

  // Conversion to strings takes place only on the writer, never in a producer.
  fileprivate var name: String? {
    switch self {
    case .none: return nil
    case .loggingStarted: return "logging.started"
    case .loggingStopped: return "logging.stopped"
    case .capsObservedOn: return "caps.observed_on"
    case .capsObservedOff: return "caps.observed_off"
    case .capsBlocked: return "caps.blocked"
    case .capsConfigurationReady: return "caps.configuration_ready"
    case .capsConfigurationBlocked: return "caps.configuration_blocked"
    case .capsResetQueued: return "caps.reset_queued"
    case .capsResetCoalesced: return "caps.reset_coalesced"
    case .capsControllerOpen: return "caps.controller_open"
    case .capsRead: return "caps.read"
    case .capsClear: return "caps.clear"
    case .capsResetFailed: return "caps.reset_failed"
    case .capsResetVerified: return "caps.reset_verified"
    case .capsNoTransition: return "caps.no_transition"
    case .capsModifiersRejected: return "caps.modifiers_rejected"
    case .capsGenerationChanged: return "caps.generation_changed"
    case .capsCommandQueued: return "caps.command_queued"
    case .capsCommandQueueFull: return "caps.command_queue_full"
    case .manualReceived: return "manual.received"
    case .manualExpired: return "manual.expired"
    case .manualGenerationGap: return "manual.generation_gap"
    case .manualFocusLayoutChanged: return "manual.focus_layout_changed"
    case .manualContextRefused: return "manual.context_refused"
    case .manualNoCandidate: return "manual.no_candidate"
    case .manualReplacementResult: return "manual.replacement_result"
    case .contextUnavailable: return "context.unavailable"
    case .contextFocusedElement: return "context.focused_element"
    case .contextElementIdentity: return "context.element_identity"
    case .contextElementRole: return "context.element_role"
    case .contextElementSubrole: return "context.element_subrole"
    case .contextFocusedFlag: return "context.focused_flag"
    case .contextEnabledFlag: return "context.enabled_flag"
    case .contextProtectedContent: return "context.protected_content"
    case .contextSelectionCount: return "context.selection_count"
    case .contextRangeWritable: return "context.range_writable"
    case .contextTextWritable: return "context.text_writable"
    case .contextRangeRead: return "context.range_read"
    case .contextLayoutUnsupported: return "context.layout_unsupported"
    case .contextCaretChanged: return "context.caret_changed"
    case .contextKeyTranslation: return "context.key_translation"
    case .contextReady: return "context.ready"
    case .contextEditable: return "context.editable"
    case .contextCharacterCount: return "context.character_count"
    case .replacementRefused: return "replacement.refused"
    case .replacementRangeRead: return "replacement.range_read"
    case .replacementSelectionWrite: return "replacement.selection_write"
    case .replacementSelectionVerification: return "replacement.selection_verification"
    case .replacementTextWrite: return "replacement.text_write"
    case .replacementPositionVerification: return "replacement.position_verification"
    case .replacementLayoutSwitch: return "replacement.layout_switch"
    case .replacementKeyboardPlan: return "replacement.keyboard_plan"
    case .replacementKeyboardDelete: return "replacement.keyboard_delete"
    case .replacementKeyboardTyped: return "replacement.keyboard_typed"
    case .replacementActionSuppressed: return "replacement.action_suppressed"
    }
  }
}

// Darwin's public 64-bit barrier operations are available on macOS 11. They
// avoid a dependency or macOS-15-only Synchronization APIs. The naturally
// aligned allocation is accessed ONLY through OSAtomic, never through Swift
// inout access to shared storage. No allocation occurs after initialization.
private final class DiagnosticAtomicWord {
  private let storage: UnsafeMutablePointer<Int64>

  init() {
    storage = .allocate(capacity: 1)
    storage.initialize(to: 0)
  }

  deinit {
    storage.deinitialize(count: 1)
    storage.deallocate()
  }

  @inline(__always) func load() -> Int64 { OSAtomicAdd64Barrier(0, storage) }
  @inline(__always) @discardableResult
  func add(_ amount: Int64) -> Int64 { OSAtomicAdd64Barrier(amount, storage) }
  @inline(__always) func replace(_ old: Int64, with new: Int64) -> Bool {
    OSAtomicCompareAndSwap64Barrier(old, new, storage)
  }

  // Retrying operations are control/writer-only, never callback operations.
  @discardableResult
  func exchange(_ new: Int64) -> Int64 {
    while true {
      let old = load()
      if replace(old, with: new) { return old }
    }
  }

  func closeAdmission() {
    while true {
      let old = load()
      if replace(old, with: old & ~1) { return }
    }
  }
}

private struct DiagnosticRecord {
  var timestamp: UInt64 = 0
  var stage: DiagnosticStage = .none
  var detail: Int32 = 0
}

private struct DiagnosticRingState {
  var head = 0
  var count = 0
}

final class DiagnosticLogger {
  static let shared = DiagnosticLogger()
  private static let capacity = 128
  private static let fileLimit = 1024 * 1024

  private let session = DiagnosticAtomicWord()
  private let producers = DiagnosticAtomicWord()
  private let dropped = DiagnosticAtomicWord()
  private let context = DiagnosticAtomicWord()
  private let errorCode = DiagnosticAtomicWord()
  private let records: UnsafeMutablePointer<DiagnosticRecord>
  private let draining: UnsafeMutablePointer<DiagnosticRecord>
  // SAFETY: initialized once, protected by ringLock, freed only after joining
  // the writer/producers. Pointer storage avoids Swift dynamic exclusivity's
  // per-thread bookkeeping/allocation on the callback path.
  private let ring: UnsafeMutablePointer<DiagnosticRingState>
  // SAFETY: published before admitting producers; immutable across off/on.
  // Only shutdown after producers stop can clear/release the source.
  private let sourceStorage: UnsafeMutablePointer<DispatchSourceUserDataAdd?>

  // Internal state is exposed only within the module for deterministic tests
  // of a private instance. All descriptor access belongs to writerQueue; all
  // ring access belongs to ringLock. Production control is main-thread-only.
  let ringLock = NSLock()
  var count: Int { ring.pointee.count }
  private(set) var writerQueue: DispatchQueue?
  private(set) var source: DispatchSourceUserDataAdd? {
    get { sourceStorage.pointee }
    set { sourceStorage.pointee = newValue }
  }
  var descriptor: Int32 = -1
  private var directoryDescriptor: Int32 = -1
  private var filename = ""
  private var backupFilename = ""
  private var failureReported = false
  private var isDestroying = false
  private var cancelled: DispatchSemaphore?
  private let queueKey = DispatchSpecificKey<Bool>()
  private var errorHandler: (() -> Void)?

  init() {
    ring = .allocate(capacity: 1)
    ring.initialize(to: DiagnosticRingState())
    sourceStorage = .allocate(capacity: 1)
    sourceStorage.initialize(to: nil)
    records = .allocate(capacity: Self.capacity)
    records.initialize(repeating: DiagnosticRecord(), count: Self.capacity)
    draining = .allocate(capacity: Self.capacity)
    draining.initialize(repeating: DiagnosticRecord(), count: Self.capacity)
  }

  deinit {
    // Explicit shutdown is preferred. A weak source handler prevents a
    // retain cycle; the last reference can also be released by that handler.
    isDestroying = true
    session.closeAdmission()
    if let queue = writerQueue {
      let onWriter = DispatchQueue.getSpecific(key: queueKey) == true
      if onWriter {
        finishDisabling()
      } else {
        _ = queue.sync { finishDisabling() }
      }
      source?.cancel()
      if !onWriter { cancelled?.wait() }
    }
    records.deinitialize(count: Self.capacity)
    records.deallocate()
    draining.deinitialize(count: Self.capacity)
    draining.deallocate()
    ring.deinitialize(count: 1)
    ring.deallocate()
    sourceStorage.deinitialize(count: 1)
    sourceStorage.deallocate()
  }

  var isEnabled: Bool { session.load() & 1 != 0 }
  var lastError: Int32 { Int32(truncatingIfNeeded: errorCode.load()) }

  var onError: (() -> Void)? {
    get {
      precondition(Thread.isMainThread)
      return errorHandler
    }
    set {
      precondition(Thread.isMainThread)
      errorHandler = newValue
    }
  }

  // Main/UI control only: never call from an input callback. Off does not
  // initialize dispatch objects or create files. An already-on call is a no-op.
  @discardableResult
  func setEnabled(_ enabled: Bool, path: String?) -> Bool {
    precondition(Thread.isMainThread)
    if !enabled {
      session.closeAdmission()
      guard let queue = writerQueue else { return true }
      let success = queue.sync { finishDisabling() }
      if !success { errno = lastError }
      return success
    }
    if isEnabled { return true }
    let queue = initializeWriter()
    let success = queue.sync { () -> Bool in
      let length = path?.utf8.count ?? 0
      guard let path, length > 0, length < Int(PATH_MAX), !path.utf8.contains(0) else {
        fail(length >= Int(PATH_MAX) ? ENAMETOOLONG : EINVAL)
        return false
      }
      waitForProducers()
      discard()
      errorCode.exchange(0)
      guard openFiles(path) else {
        fail(errno)
        return false
      }
      failureReported = false
      guard append(DiagnosticRecord(timestamp: Self.now(), stage: .loggingStarted)) else {
        fail(errno)
        return false
      }
      let token = (session.load() &+ 2) | 1
      session.exchange(token)
      return true
    }
    if !success { errno = lastError }
    return success
  }

  // Callback-safe: numeric operations, a single try-lock, a bounded copy,
  // and one coalesced wakeup. Source lifetime extends across all off/on cycles.
  func record(_ stage: DiagnosticStage, _ detail: Int32 = 0) {
    let token = session.load()
    guard token & 1 != 0, stage != .none else { return }
    producers.add(1)
    guard session.load() == token else {
      producers.add(-1)
      return
    }
    if ringLock.try() {
      if count == Self.capacity {
        dropped.add(1)
      } else {
        let position = (ring.pointee.head + ring.pointee.count) % Self.capacity
        records[position] = DiagnosticRecord(timestamp: Self.now(), stage: stage, detail: detail)
        ring.pointee.count += 1
      }
      ringLock.unlock()
    } else {
      dropped.add(1)
    }
    source?.add(data: 1)
    producers.add(-1)
  }

  // A concurrent setter that wins the CAS supersedes this overlapping update;
  // there is no retry/spin on the input path and never a torn stage/code pair.
  func setContextStatus(_ stage: DiagnosticStage, _ detail: Int32) {
    let valid = stage.rawValue >= 60 && stage.rawValue <= 77
    let bits = valid ? UInt64(stage.rawValue) << 32 | UInt64(UInt32(bitPattern: detail)) : 0
    let previous = context.load()
    _ = context.replace(previous, with: Int64(bitPattern: bits))
  }

  // Explicit manual-command path only, not an ordinary-key log/history.
  func recordContextStatus() {
    let bits = UInt64(bitPattern: context.load())
    let stage = DiagnosticStage(rawValue: UInt32(truncatingIfNeeded: bits >> 32)) ?? .none
    record(
      stage == .none ? .contextUnavailable : stage,
      Int32(bitPattern: UInt32(truncatingIfNeeded: bits)))
  }

  // Caller must stop all producers before shutdown. Disable alone is safe
  // with live producers and synchronously drains every admitted record.
  func shutdown() {
    precondition(Thread.isMainThread)
    setEnabled(false, path: nil)
    guard let source else { return }
    source.cancel()
    cancelled?.wait()
    self.source = nil
    writerQueue = nil
    cancelled = nil
  }

  private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

  private func initializeWriter() -> DispatchQueue {
    if let writerQueue { return writerQueue }
    let queue = DispatchQueue(label: "switch-lang.diagnostics")
    queue.setSpecific(key: queueKey, value: true)
    let cancellation = DispatchSemaphore(value: 0)
    let dataSource = DispatchSource.makeUserDataAddSource(queue: queue)
    dataSource.setEventHandler { [weak self] in self?.drain() }
    dataSource.setCancelHandler { cancellation.signal() }
    writerQueue = queue
    source = dataSource
    cancelled = cancellation
    dataSource.resume()
    return queue
  }

  private func waitForProducers() {
    while producers.load() != 0 { sched_yield() }
  }

  private func discard() {
    ringLock.lock()
    ring.pointee.head = 0
    ring.pointee.count = 0
    dropped.exchange(0)
    ringLock.unlock()
  }

  @discardableResult
  private func finishDisabling() -> Bool {
    waitForProducers()
    var success = drain()
    if success && descriptor >= 0 {
      success = append(DiagnosticRecord(timestamp: Self.now(), stage: .loggingStopped))
      if !success { fail(errno) }
    }
    if !closeFiles() {
      fail(errno)
      success = false
    }
    return success
  }

  private func fail(_ error: Int32) {
    session.closeAdmission()
    waitForProducers()
    discard()
    errorCode.exchange(Int64(error))
    _ = closeFiles()
    if !failureReported {
      failureReported = true
      if !isDestroying {
        DispatchQueue.main.async { [weak self] in self?.errorHandler?() }
      }
    }
    errno = error  // Cleanup must not replace the originating errno.
  }

  private func closeFiles() -> Bool {
    var error: Int32 = 0
    if descriptor >= 0 && Darwin.close(descriptor) != 0 { error = errno }
    descriptor = -1
    if directoryDescriptor >= 0 && Darwin.close(directoryDescriptor) != 0 && error == 0 {
      error = errno
    }
    directoryDescriptor = -1
    if error != 0 { errno = error }
    return error == 0
  }

  // Open every ancestor separately. Leaf-only O_NOFOLLOW is insufficient.
  private func openDirectory(_ path: String) -> Int32 {
    var current = Darwin.open(
      path.hasPrefix("/") ? "/" : ".",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if current < 0 { return -1 }
    for component in path.split(separator: "/") {
      let next = String(component).withCString {
        openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      }
      var error: Int32 = next < 0 ? errno : 0
      if Darwin.close(current) != 0 && error == 0 { error = errno }
      if error != 0 {
        if next >= 0 { _ = Darwin.close(next) }
        errno = error
        return -1
      }
      current = next
    }
    return current
  }

  private func validate(_ state: stat) -> Bool {
    guard state.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      errno = EINVAL
      return false
    }
    guard state.st_uid == geteuid(), state.st_nlink == 1, state.st_mode & 0o7777 == 0o600 else {
      errno = EACCES
      return false
    }
    guard state.st_size >= 0, state.st_size <= Self.fileLimit else {
      errno = EFBIG
      return false
    }
    return true
  }

  private func fileState(_ name: String, _ state: inout stat, _ exists: inout Bool) -> Bool {
    if name.withCString({ fstatat(directoryDescriptor, $0, &state, AT_SYMLINK_NOFOLLOW) }) != 0 {
      if errno != ENOENT { return false }
      exists = false
      return true
    }
    exists = true
    guard state.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
      errno = ELOOP
      return false
    }
    return validate(state)
  }

  private func sameFile(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
  }

  private func openFiles(_ path: String) -> Bool {
    let separator = path.lastIndex(of: "/")
    let leaf = separator.map { String(path[path.index(after: $0)...]) } ?? path
    let length = leaf.utf8.count
    guard length > 0, length <= Int(NAME_MAX) - 2, leaf != ".", leaf != ".." else {
      errno = length > Int(NAME_MAX) - 2 ? ENAMETOOLONG : EINVAL
      return false
    }
    filename = leaf
    backupFilename = leaf + ".1"
    let parent: String
    if let separator {
      parent = separator == path.startIndex ? "/" : String(path[..<separator])
    } else {
      parent = "."
    }
    directoryDescriptor = openDirectory(parent)
    guard directoryDescriptor >= 0 else { return false }
    var backup = stat()
    var exists = false
    guard fileState(backupFilename, &backup, &exists) else { return false }
    return openCurrent()
  }

  private func openCurrent() -> Bool {
    var before = stat()
    var exists = false
    guard fileState(filename, &before, &exists) else { return false }
    var flags = O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    if !exists { flags |= O_CREAT | O_EXCL }
    let opened = filename.withCString { openat(directoryDescriptor, $0, flags, mode_t(0o600)) }
    guard opened >= 0 else { return false }
    var after = stat()
    var error: Int32 = 0
    if fstat(opened, &after) != 0 || !validate(after) {
      error = errno
    } else if exists && !sameFile(before, after) {
      error = ESTALE
    }
    if error != 0 {
      _ = Darwin.close(opened)
      errno = error
      return false
    }
    descriptor = opened
    return true
  }

  private func currentState(_ state: inout stat) -> Bool {
    guard fstat(descriptor, &state) == 0, validate(state) else { return false }
    var named = stat()
    var exists = false
    guard fileState(filename, &named, &exists) else { return false }
    guard exists, sameFile(state, named) else {
      errno = ESTALE
      return false
    }
    return true
  }

  private func rotate() -> Bool {
    var current = stat()
    var backup = stat()
    var exists = false
    guard currentState(&current), fileState(backupFilename, &backup, &exists) else { return false }
    let renamed = filename.withCString { original in
      backupFilename.withCString {
        renameat(directoryDescriptor, original, directoryDescriptor, $0)
      }
    }
    guard renamed == 0, fileState(backupFilename, &backup, &exists) else { return false }
    guard exists, sameFile(current, backup) else {
      errno = ESTALE
      return false
    }
    let previous = descriptor
    descriptor = -1
    guard Darwin.close(previous) == 0 else { return false }
    // Never append to an entry inserted after the rename.
    descriptor = filename.withCString {
      openat(
        directoryDescriptor, $0,
        O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
    }
    guard descriptor >= 0 else { return false }
    var created = stat()
    return currentState(&created)
  }

  private func appendLine(_ line: String) -> Bool {
    var state = stat()
    guard currentState(&state) else { return false }
    let length = line.utf8.count
    guard length <= Self.fileLimit else {
      errno = EFBIG
      return false
    }
    if state.st_size > Self.fileLimit - length && !rotate() { return false }
    return line.withCString { bytes in
      var position = 0
      while position < length {
        let written = Darwin.write(descriptor, bytes.advanced(by: position), length - position)
        if written < 0 {
          if errno == EINTR { continue }
          return false
        }
        if written == 0 {
          errno = EIO
          return false
        }
        position += written
      }
      return true
    }
  }

  private func append(_ record: DiagnosticRecord) -> Bool {
    guard let name = record.stage.name else {
      errno = EINVAL
      return false
    }
    let line = "ns=\(record.timestamp) stage=\(name) code=\(record.detail)\n"
    guard line.utf8.count < 160 else {
      errno = EOVERFLOW
      return false
    }
    return appendLine(line)
  }

  // Writer-only. Internal for deterministic isolated queue/failure tests.
  @discardableResult
  func drain() -> Bool {
    ringLock.lock()
    let available = count
    for index in 0..<available {
      draining[index] = records[(ring.pointee.head + index) % Self.capacity]
    }
    ring.pointee.head = (ring.pointee.head + available) % Self.capacity
    ring.pointee.count = 0
    let lost = UInt64(bitPattern: dropped.exchange(0))
    ringLock.unlock()
    guard descriptor >= 0 else { return true }
    for index in 0..<available {
      guard append(draining[index]) else {
        fail(errno)
        return false
      }
    }
    if lost != 0 {
      let line = "dropped=\(lost)\n"
      guard line.utf8.count < 64 else {
        fail(EOVERFLOW)
        return false
      }
      guard appendLine(line) else {
        fail(errno)
        return false
      }
    }
    return true
  }
}
