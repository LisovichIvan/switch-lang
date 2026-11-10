import ApplicationServices
import Carbon
import Darwin
import Foundation

// Metadata only: no event text is read on the tap thread.
enum InputKind: UInt32 {
  case key = 1
  case hotkey = 2
  case reset = 3
  case contextChanged = 4
  case stop = 5
  case action = 6
}

struct InputMetadata {
  var kind: InputKind
  var keycode: UInt16 = 0
  var keyboardType: UInt16 = 0
  var flags: UInt64 = 0
  var generation: UInt64 = 0
  var timestampNS: UInt64 = 0
}

struct ContextSnapshot {
  var focus: UInt64
  var layout: Layout
  var text: [UInt16]
}

func monotonicNowNS() -> UInt64 {
  var value = timespec()
  guard clock_gettime(CLOCK_MONOTONIC, &value) == 0, value.tv_sec >= 0, value.tv_nsec >= 0 else {
    return 0
  }
  return UInt64(value.tv_sec) &* 1_000_000_000 &+ UInt64(value.tv_nsec)
}

let actionBudgetNS: UInt64 = 100_000_000
let actionWakeTag: Int64 = 0x534c_4143_5449_4f4e
let replacementModifierMask =
  CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
  | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue
  | CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskSecondaryFn.rawValue
  | CGEventFlags.maskHelp.rawValue
let shortcutModifierMask =
  CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
  | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskSecondaryFn.rawValue
  | CGEventFlags.maskHelp.rawValue
let bindingModifierMask =
  CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
  | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue

enum RuntimeReason: Int32 {
  case invalidArgument = 1
  case missingValue = 2
  case unexpectedType = 3
  case invalidRange = 4
  case rejectedValue = 5
  case selectionNotCaret = 6
  case allocationFailed = 7
  case notListening = 10
  case paused = 11
  case recording = 12
  case inactiveSession = 13
  case sleeping = 14
  case notTrusted = 15
  case secureInputUnsafe = 16
  case capsNotReady = 17
  case capsInactive = 18
  case generationChanged = 20
  case focusChanged = 21
  case layoutChanged = 22
  case anchorUnconfirmed = 23
  case caretChanged = 24
  case candidateGeneration = 25
  case characterCountChanged = 26
  case boundaryUnconfirmed = 27
  case deadline = 28
  case actionUnavailable = 29
  case selectionOwnership = 30
  case contextRejected = 31
  case translationDeadKey = 32
  case translationLength = 33
  case targetUnavailable = 34
  case layoutUnconfirmed = 35
  case modifiersHeld = 36
  case postingNotTrusted = 37
  case mainUnavailable = 38
  case verificationTimeout = 39
}

@discardableResult
func runtimeCondition(_ accepted: Bool, _ stage: DiagnosticStage, _ reason: RuntimeReason) -> Bool {
  if !accepted { DiagnosticLogger.shared.record(stage, reason.rawValue) }
  return accepted
}

func isActionKey(_ keycode: UInt16) -> Bool { keycode == 36 || keycode == 48 || keycode == 76 }

func actionEligible(
  keycode: UInt16, flags: UInt64, automatic: Bool, hotkey: Bool,
  repeated: Bool, candidate: UInt64, generation: UInt64
) -> Bool {
  automatic && !hotkey && !repeated && isActionKey(keycode) && flags & shortcutModifierMask == 0
    && candidate != 0 && generation &- candidate == 1
}

enum ActionPhase { case idle, pending, committing, switching, ready }

struct DeferredAction {
  var phase: ActionPhase = .idle
  var generation: UInt64 = 0
  var deadline: UInt64 = 0
  var keyDown: CGEvent?
  var wake: CGEvent?
  var timer: CFRunLoopTimer?

  func mayStart(generation: UInt64, now: UInt64) -> Bool {
    phase == .pending && self.generation == generation && now != 0 && now < deadline
  }

  mutating func claim(generation: UInt64, now: UInt64) -> Bool {
    guard mayStart(generation: generation, now: now) else { return false }
    phase = .committing
    return true
  }

  @discardableResult mutating func markReady() -> Bool {
    guard phase == .pending else { return false }
    phase = .ready
    return true
  }

  mutating func take() -> CGEvent? {
    let event = keyDown
    if let timer { CFRunLoopTimerInvalidate(timer) }
    self = DeferredAction()
    return event
  }
}

func suppressActionEvent(pending: inout UInt32, type: CGEventType, keycode: UInt16, repeated: Bool)
  -> Bool
{
  guard pending == UInt32(keycode) + 1, type == .keyDown || type == .keyUp else { return false }
  if type == .keyUp {
    pending = 0
    return true
  }
  if repeated { return true }
  pending = 0
  return false
}

func resolveReplacementAction(
  _ action: inout DeferredAction, result: inout Int32,
  suppressed: inout UInt32
) -> CGEvent? {
  if result == 3 || result == 4 {
    if let saved = action.take() {
      suppressed = UInt32(truncatingIfNeeded: saved.getIntegerValueField(.keyboardEventKeycode)) + 1
    }
    result = 4
    return nil
  }
  if result == 1 { return action.take() }
  action.phase = .pending
  return nil
}

func isPreparationRelease(
  type: CGEventType, keycode: UInt16, flags: UInt64,
  heldModifiers: UInt64, savedActionKey: UInt32
) -> Bool {
  (type == .flagsChanged && flags & ~heldModifiers == 0)
    || (type == .keyUp && UInt32(keycode) + 1 != savedActionKey)
}

func positionMatches(_ selection: CFRange, actualCount: Int, caret: Int, expectedCount: Int) -> Bool
{
  selection.length == 0 && selection.location == caret && actualCount == expectedCount
}

enum KeyboardConfirmation { case pending, confirmed, rejected }

// Each stage has an independent deadline. Notification storms do not extend it;
// perform one final AX read after expiry, even when every wait was signalled.
func awaitKeyboardConfirmation(
  changed: DispatchSemaphore, deadline: UInt64,
  readState: () -> KeyboardConfirmation, now: () -> UInt64
) -> Bool {
  while true {
    var current = now()
    guard current != 0 else { return false }
    let finalRead = current >= deadline
    let state = readState()
    if state == .confirmed { return true }
    if state == .rejected || finalRead { return false }
    current = now()
    guard current != 0 else { return false }
    if current < deadline {
      _ = changed.wait(
        timeout: .now() + .nanoseconds(Int(min(deadline - current, UInt64(Int.max)))))
    }
  }
}

enum ReplacementPhase: UInt64 {
  case queued, waitingModifiers, preparing, deleting, switching, typing, verifying, completed
}
enum MainRequestPhase: UInt64 { case pending, running, completed, cancelled }

final class MainLayoutRequest {
  let phase: AtomicUInt64
  let done = DispatchSemaphore(value: 0)
  // Written only by main, read only after a completed acquire/seq_cst load.
  var success = false
  var plan: KeyboardEventPlan?
  var targetSource: TISInputSource?

  init() throws { phase = try AtomicUInt64(MainRequestPhase.pending.rawValue) }
  func begin() -> Bool {
    phase.compareExchange(
      expected: MainRequestPhase.pending.rawValue, desired: MainRequestPhase.running.rawValue)
  }
  func cancel() {
    if phase.compareExchange(
      expected: MainRequestPhase.pending.rawValue, desired: MainRequestPhase.cancelled.rawValue)
    {
      done.signal()
    }
  }
  func complete(success: Bool) {
    self.success = success
    phase.value = MainRequestPhase.completed.rawValue
    done.signal()
  }
}

// Main retains ONLY this bounded snapshot, never ReplacementJob/AXContext.
// A timed-out main request therefore cannot prolong or touch the worker loan.
final class ReplacementSnapshot {
  let generation: UInt64
  let original: [UInt16]
  let replacement: [UInt16]
  let target: Layout
  let phase: AtomicUInt64
  let cancelled: AtomicUInt64
  let expectsLayoutChange: AtomicUInt64
  let contextDirty: AtomicUInt64
  let contextChanged = DispatchSemaphore(value: 0)

  init(generation: UInt64, original: [UInt16], replacement: [UInt16], target: Layout) throws {
    self.generation = generation
    self.original = original
    self.replacement = replacement
    self.target = target
    phase = try AtomicUInt64(ReplacementPhase.queued.rawValue)
    cancelled = try AtomicUInt64()
    expectsLayoutChange = try AtomicUInt64()
    contextDirty = try AtomicUInt64()
  }
  func signalContext() {
    if contextDirty.exchange(1) == 0 { contextChanged.signal() }
  }
}

func replacementAcceptsLayoutNotification(
  _ snapshot: ReplacementSnapshot, readCurrentLayout: () -> Layout?
) -> Bool {
  guard snapshot.expectsLayoutChange.boolValue, !snapshot.cancelled.boolValue,
    snapshot.phase.value >= ReplacementPhase.switching.rawValue,
    snapshot.phase.value < ReplacementPhase.completed.rawValue
  else { return false }
  // One TIS selection can deliver repeated notifications. Keep the expectation
  // until the job completes, but re-read the actual target on EVERY notice.
  return readCurrentLayout() == snapshot.target
}

final class ReplacementJob {
  // Worker owns this context except during the synchronous listener loan.
  // Set to nil before done.signal, including every stop/error path.
  var context: AXContext?
  let snapshot: ReplacementSnapshot
  let focus: UInt64
  let beforeAction: Bool
  let done = DispatchSemaphore(value: 0)
  var deadline: UInt64
  var source: Layout?
  var pid: pid_t = 0
  var terminalScreenCount: Int?
  var result: Int32 = 0
  var scheduled = false
  var heldModifiers: UInt64 = 0
  var timer: CFRunLoopTimer?
  var expectedElement: AXUIElement?
  var preparation: MainLayoutRequest?
  var mainRequest: MainLayoutRequest?  // Coordination lock protects this slot.

  init(
    context: AXContext, focus: UInt64, generation: UInt64, original: [UInt16],
    replacement: [UInt16],
    target: Layout, beforeAction: Bool, now: UInt64
  ) throws {
    self.context = context
    self.focus = focus
    self.beforeAction = beforeAction
    deadline = now &+ 200_000_000
    snapshot = try ReplacementSnapshot(
      generation: generation, original: original, replacement: replacement, target: target)
  }
}

struct RuntimeCoordination {
  var loop: CFRunLoop?
  var tap: CFMachPort?
  var job: ReplacementJob?
  // Held until the queued block ACKS, never freed by a timeout/cancellation.
  var outstandingRequest: MainLayoutRequest?
}

struct RuntimeFailure: Error {
  let stage: String
  let detail: Int32
}
