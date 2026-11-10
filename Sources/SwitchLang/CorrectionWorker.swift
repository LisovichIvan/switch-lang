import Foundation

private enum TrackingDiagnostic: Int32 {
  case noInput = 0
  case reset = 1
  case expired = 2
  case generationGap = 3
  case navigationOrShortcut = 4
  case contextRefused = 5
  case focusLayoutChanged = 6
  case unsupportedLayout = 7
  case untranslatedKey = 8
  case invalidUnicode = 9
  case unsupportedKey = 10
  case observedInput = 11
  case backspace = 12
  case anchorChanged = 13
  case replacementConsumed = 14
}

func contextNotificationIsCurrent(
  _ input: InputMetadata, processedGeneration: UInt64, currentGeneration: UInt64
) -> Bool {
  input.kind != .contextChanged
    || (input.generation == processedGeneration && currentGeneration == processedGeneration)
}

func isNavigationKey(_ keycode: UInt16) -> Bool {
  keycode == 53 || keycode == 71 || (114...119).contains(keycode) || keycode == 121
    || (123...126).contains(keycode)
}

func invalidatesKeyTracking(_ input: InputMetadata) -> Bool {
  let shortcuts: UInt64 = (1 << 20) | (1 << 18) | (1 << 19) | (1 << 23) | (1 << 22)
  return input.kind == .key
    && (input.flags & shortcuts != 0 || isNavigationKey(input.keycode) || input.keycode == 36
      || input.keycode == 48 || input.keycode == 76)
}

func decodeUTF16Strict(_ units: [UInt16]) -> String? {
  var index = 0
  while index < units.count {
    let unit = units[index]
    if (0xD800...0xDBFF).contains(unit) {
      guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
        return nil
      }
      index += 2
    } else {
      guard !(0xDC00...0xDFFF).contains(unit) else { return nil }
      index += 1
    }
  }
  return String(decoding: units, as: UTF16.self)
}

// The sole processing thread owns tracker/context. During replace it lends the
// context exclusively to the listener and does not touch it until completion.
final class CorrectionWorker {
  private let queue: InputQueue
  private let runtime: KeyboardRuntime
  private let finished = DispatchGroup()
  private var thread: Thread?
  private var tracker = Tracker()
  private var lastGeneration: UInt64 = 0
  private var trackedFocus: UInt64 = 0
  private var trackedLayout: Layout?
  private var trackingDiagnostic = TrackingDiagnostic.noInput

  init(queue: InputQueue, runtime: KeyboardRuntime) {
    self.queue = queue
    self.runtime = runtime
  }

  func start() {
    guard thread == nil else { return }
    finished.enter()
    let processingThread = Thread { [self] in
      defer { finished.leave() }
      do {
        let context = try AXContext(runtime: runtime)
        defer { context.reset() }
        while let input = queue.take() {
          autoreleasepool { process(input, context: context) }
        }
      } catch {
        runtime.report(1)
      }
    }
    processingThread.name = "Switch Lang processing"
    thread = processingThread
    processingThread.start()
  }

  func stopAndWait() {
    queue.close()
    finished.wait()
    thread = nil
  }

  private func process(_ input: InputMetadata, context: AXContext) {
    // A saved action must be completed on every early return, but only if
    // still pending; a destructive job owns its own completion/suppression.
    defer { if input.kind == .action { runtime.finishAction(input.generation) } }
    let manual = input.kind == .hotkey
    if manual {
      DiagnosticLogger.shared.record(.manualReceived, trackingDiagnostic.rawValue)
      DiagnosticLogger.shared.recordContextStatus()
    }
    runtime.publishActionCandidate(0)
    if input.kind == .stop { return }
    let now = monotonicNowNS()
    let age = now >= input.timestampNS ? now - input.timestampNS : 0
    if input.kind == .reset || now == 0 || input.timestampNS == 0 || age > 200_000_000 {
      if manual { DiagnosticLogger.shared.record(.manualExpired) }
      trackingDiagnostic = input.kind == .reset ? .reset : .expired
      tracker.clear()
      runtime.discardTerminalAnchor()
      context.reset()
      lastGeneration = input.generation
      trackedFocus = 0
      if input.kind == .reset && age <= 200_000_000 && input.timestampNS != 0 {
        context.primeTerminal(generation: input.generation)
      }
      return
    }
    let preInputAnchor = runtime.takeTerminalAnchor(
      for: input, processedGeneration: lastGeneration)
    if preInputAnchor != nil {
      // This snapshot finished before the first key, not after its text was
      // observed. Never carry the previous prompt's word into the new anchor.
      tracker.clear()
      trackedFocus = 0
    }
    if input.kind == .key || input.kind == .hotkey || input.kind == .action {
      if lastGeneration != 0 && input.generation != lastGeneration &+ 1 {
        if manual { DiagnosticLogger.shared.record(.manualGenerationGap) }
        tracker.clear()
        trackingDiagnostic = .generationGap
      }
      lastGeneration = input.generation
    }
    if invalidatesKeyTracking(input) {
      tracker.clear()
      trackingDiagnostic = .navigationOrShortcut
      runtime.discardTerminalAnchor()
      context.reset()
      trackedFocus = 0
      context.primeTerminal(generation: input.generation)
      return
    }
    guard
      contextNotificationIsCurrent(
        input, processedGeneration: lastGeneration, currentGeneration: runtime.inputGeneration.value
      )
    else { return }
    let currentContext = context.read(input, preInputAnchor: preInputAnchor)
    guard
      contextNotificationIsCurrent(
        input, processedGeneration: lastGeneration, currentGeneration: runtime.inputGeneration.value
      )
    else { return }
    guard let snapshot = currentContext else {
      if manual {
        DiagnosticLogger.shared.record(.manualContextRefused)
        DiagnosticLogger.shared.recordContextStatus()
      }
      tracker.clear()
      trackingDiagnostic = .contextRefused
      trackedFocus = 0
      return
    }
    if snapshot.focus != trackedFocus || snapshot.layout != trackedLayout {
      if manual { DiagnosticLogger.shared.record(.manualFocusLayoutChanged) }
      tracker.clear()
      trackingDiagnostic = .focusLayoutChanged
      trackedFocus = snapshot.focus
      trackedLayout = snapshot.layout
    }
    if input.kind == .key {
      if input.keycode == 51 {
        tracker.backspace()
        trackingDiagnostic = .backspace
        return
      }
      guard !snapshot.text.isEmpty, snapshot.text.count <= 8 else {
        tracker.clear()
        trackingDiagnostic = .untranslatedKey
        return
      }
      guard let text = decodeUTF16Strict(snapshot.text) else {
        tracker.clear()
        trackingDiagnostic = .invalidUnicode
        return
      }
      if text.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) {
        tracker.clear()
        trackingDiagnostic = .unsupportedKey
        return
      }
      tracker.observe(text, source: snapshot.layout, focus: snapshot.focus)
      trackingDiagnostic = .observedInput
    }
    if input.kind == .contextChanged || input.kind == .hotkey || input.kind == .action {
      if let observed = tracker.candidate(automatic: false) {
        let confirmed = context.confirm(
          length: observed.original.utf16.count,
          focus: snapshot.focus, generation: lastGeneration)
        if confirmed < 0 {
          guard
            contextNotificationIsCurrent(
              input, processedGeneration: lastGeneration,
              currentGeneration: runtime.inputGeneration.value)
          else { return }
          tracker.clear()
          trackingDiagnostic = .anchorChanged
          return
        }
      }
    }
    let automatic = runtime.automaticEnabled
    if automatic && (input.kind == .key || input.kind == .contextChanged)
      && tracker.candidateBeforeAction() != nil
    {
      runtime.publishActionCandidate(lastGeneration)
    }
    guard
      manual
        || (automatic
          && (input.kind == .key || input.kind == .contextChanged || input.kind == .action))
    else { return }
    let candidate =
      input.kind == .action
      ? tracker.candidateBeforeAction() : tracker.candidate(automatic: !manual)
    guard let candidate = candidate else {
      if manual { DiagnosticLogger.shared.record(.manualNoCandidate, trackingDiagnostic.rawValue) }
      return
    }
    let result = runtime.replace(
      context: context, focus: snapshot.focus, generation: lastGeneration,
      original: Array(candidate.original.utf16), replacement: Array(candidate.replacement.utf16),
      target: candidate.target, beforeAction: input.kind == .action)
    if manual { DiagnosticLogger.shared.record(.manualReplacementResult, result) }
    if result != 0 {
      tracker.clear()
      trackingDiagnostic = .replacementConsumed
      runtime.publishActionCandidate(0)
      if result != 1 { runtime.report(result == 4 ? 10 : 4) }
    }
  }
}
