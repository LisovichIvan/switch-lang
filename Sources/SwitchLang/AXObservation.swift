import ApplicationServices
import Foundation

final class AXObservationTarget {
  let processIdentifier: pid_t
  let element: AXUIElement
  let notify: (AXUIElement, CFString) -> Void
  // Main-thread only; invalidated before disconnecting the source.
  var active = true

  init(
    processIdentifier: pid_t, element: AXUIElement,
    notify: @escaping (AXUIElement, CFString) -> Void
  ) {
    self.processIdentifier = processIdentifier
    self.element = element
    self.notify = notify
  }
}

protocol AXObservationSubscription: AnyObject {
  func cancel()
}

private let observationCallback: AXObserverCallback = { _, element, name, pointer in
  precondition(Thread.isMainThread)
  guard let pointer else { return }
  // SAFETY: the subscription retains its target until its source and observer
  // are destroyed on this same thread. No concurrent teardown is possible.
  let target = Unmanaged<AXObservationTarget>.fromOpaque(pointer).takeUnretainedValue()
  if target.active { target.notify(element, name) }
}

private final class SystemAXObservation: AXObservationSubscription {
  private let target: AXObservationTarget
  private var observer: AXObserver?

  init?(target: AXObservationTarget) {
    precondition(Thread.isMainThread)
    self.target = target
    var created: AXObserver?
    guard AXObserverCreate(target.processIdentifier, observationCallback, &created) == .success,
      let created
    else { return nil }
    observer = created
    let application = AXUIElementCreateApplication(target.processIdentifier)
    // SAFETY: retained by this subscription, never the worker-owned AXContext.
    let pointer = Unmanaged.passUnretained(target).toOpaque()
    for (element, name) in [
      (application, kAXFocusedUIElementChangedNotification),
      (application, kAXFocusedWindowChangedNotification),
      (target.element, kAXValueChangedNotification),
      (target.element, kAXSelectedTextChangedNotification),
      (target.element, kAXUIElementDestroyedNotification),
    ] {
      // Notifications are advisory: unsupported subscriptions cannot authorize
      // replacement, which still requires synchronous metadata confirmation.
      _ = AXObserverAddNotification(created, element, name as CFString, pointer)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
  }

  func cancel() {
    precondition(Thread.isMainThread)
    target.active = false
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    // AXObserver unregisters its notifications on release. Both that release
    // and source dispatch now belong to main, including during shutdown.
    observer = nil
  }

  deinit { cancel() }
}

// Worker/listener publish at most one pending target. Only main creates,
// dispatches, cancels and releases subscriptions; it never borrows AXContext.
final class AXObservation {
  private struct Request {
    let revision: UInt64
    let target: AXObservationTarget?
  }

  private struct State {
    var enabled = false
    var revision: UInt64 = 0
    var pending: Request?
    var scheduled = false
  }

  private let state = SharedValue(State())
  private let schedule: (@escaping () -> Void) -> Void
  private let create: (AXObservationTarget) -> AXObservationSubscription?
  private var subscription: AXObservationSubscription?

  init(
    schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
    create: @escaping (AXObservationTarget) -> AXObservationSubscription? = {
      SystemAXObservation(target: $0)
    }
  ) {
    self.schedule = schedule
    self.create = create
  }

  func start() {
    precondition(Thread.isMainThread)
    state.withLock { $0.enabled = true }
  }

  @discardableResult
  func request(_ target: AXObservationTarget?) -> Bool {
    let accepted = state.withLock { state -> (accepted: Bool, schedule: Bool) in
      guard state.enabled else { return (false, false) }
      state.revision &+= 1
      state.pending = Request(revision: state.revision, target: target)
      guard !state.scheduled else { return (true, false) }
      state.scheduled = true
      return (true, true)
    }
    if accepted.schedule { enqueueDrain() }
    return accepted.accepted
  }

  func stop() {
    precondition(Thread.isMainThread)
    state.withLock {
      $0.enabled = false
      $0.revision &+= 1
      $0.pending = nil
      // An already queued drain retains its one scheduling slot until it runs,
      // even across stop/start. Never accumulate cancelled main blocks.
    }
    subscription?.cancel()
    subscription = nil
  }

  private func enqueueDrain() {
    schedule { [weak self] in self?.drain() }
  }

  private func drain() {
    precondition(Thread.isMainThread)
    let request = state.withLock { state -> Request? in
      guard state.enabled, let pending = state.pending else {
        state.scheduled = false
        return nil
      }
      state.pending = nil
      return pending
    }
    guard let request else { return }
    let current = state.withLock { $0.enabled && $0.revision == request.revision }
    if current {
      subscription?.cancel()
      subscription = nil
      if let target = request.target, let created = create(target) {
        if state.withLock({ $0.enabled && $0.revision == request.revision }) {
          subscription = created
        } else {
          created.cancel()
        }
      }
    }
    let again = state.withLock { state -> Bool in
      if state.enabled && state.pending != nil { return true }
      state.scheduled = false
      return false
    }
    if again { enqueueDrain() }
  }

  deinit {
    // Runtime.stop closes the owner on main before joining worker/listener.
    precondition(subscription == nil)
  }
}
