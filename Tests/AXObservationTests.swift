import ApplicationServices
import Foundation

private final class TestAXSubscription: AXObservationSubscription {
  let target: AXObservationTarget
  private let cancelled: () -> Void
  private var stopped = false

  init(target: AXObservationTarget, cancelled: @escaping () -> Void) {
    self.target = target
    self.cancelled = cancelled
  }

  func cancel() {
    if stopped { return }
    stopped = true
    target.active = false
    cancelled()
  }
}

func runAXObservationTests() throws -> Int {
  try requireTest(Thread.isMainThread, "AX lifecycle tests run on the delivery owner")
  let scheduled = SharedValue<[() -> Void]>([])
  let lifecycle = SharedValue<[String]>([])
  var active: TestAXSubscription?
  let owner = AXObservation(
    schedule: { block in scheduled.withLock { $0.append(block) } },
    create: { target in
      lifecycle.withLock { $0.append(Thread.isMainThread ? "create-main" : "create-other") }
      let subscription = TestAXSubscription(target: target) {
        lifecycle.withLock { $0.append(Thread.isMainThread ? "cancel-main" : "cancel-other") }
      }
      active = subscription
      return subscription
    })
  defer { owner.stop() }
  func target(_ identifier: pid_t, notify: @escaping () -> Void = {}) -> AXObservationTarget {
    // Local opaque handles only: no AX messaging or permissions.
    AXObservationTarget(
      processIdentifier: identifier, element: AXUIElementCreateApplication(identifier)
    ) { _, _ in notify() }
  }
  func drain() throws {
    let block = scheduled.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    try requireTest(block != nil, "exactly one pending main drain exists")
    block?()
  }
  owner.start()
  let requested = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    for identifier: pid_t in 1...10_000 { owner.request(target(identifier)) }
    requested.signal()
  }
  try requireTest(
    requested.wait(timeout: .now() + 5) == .success, "worker publication never waits for main")
  try requireTest(
    scheduled.withLock { $0.count } == 1 && lifecycle.withLock { $0.isEmpty },
    "ten thousand worker updates keep one pending request and perform no lifecycle operations")
  try drain()
  try requireTest(
    active?.target.processIdentifier == 10_000, "only the latest subscription is installed")

  // Reproduce the unsafe ordering: delivery on main is still active when a
  // worker requests teardown. Cancellation must wait for the next main drain.
  let published = DispatchSemaphore(value: 0)
  var deliveryProtected = false
  owner.request(
    target(
      10_001,
      notify: { [weak owner] in
        DispatchQueue.global().async {
          owner?.request(nil)
          owner?.request(target(10_002))
          published.signal()
        }
        let completed = published.wait(timeout: .now() + 5) == .success
        deliveryProtected =
          completed && lifecycle.withLock { $0.count } == 3
          && scheduled.withLock { $0.count } == 1
      }))
  try drain()
  if let active { active.target.notify(active.target.element, "synthetic" as CFString) }
  try requireTest(
    deliveryProtected, "in-flight main delivery cannot lose its subscription to worker teardown")
  try drain()
  try requireTest(
    lifecycle.withLock { $0 } == [
      "create-main", "cancel-main", "create-main", "cancel-main", "create-main",
    ],
    "replacement and final release stay serialized with delivery on main")

  let listenerWaiting = DispatchSemaphore(value: 0)
  let confirmation = DispatchSemaphore(value: 0)
  let listenerFinished = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    listenerWaiting.signal()
    if confirmation.wait(timeout: .now() + 5) == .success { listenerFinished.signal() }
  }
  try requireTest(listenerWaiting.wait(timeout: .now() + 5) == .success, "synthetic listener waits")
  owner.request(target(10_002, notify: { confirmation.signal() }))
  try drain()
  if let active { active.target.notify(active.target.element, "synthetic" as CFString) }
  try requireTest(
    listenerFinished.wait(timeout: .now() + 5) == .success,
    "main still delivers AX confirmation while listener is blocked")

  owner.request(target(10_003))
  owner.stop()
  try requireTest(!owner.request(target(10_004)), "shutdown rejects worker publications")
  let beforeDrain = lifecycle.withLock { $0 }
  try drain()
  try requireTest(
    lifecycle.withLock { $0 } == beforeDrain, "late drain cannot restore a closed subscription")

  owner.start()
  owner.request(target(10_005))
  owner.stop()
  owner.start()
  owner.request(target(10_006))
  try requireTest(
    scheduled.withLock { $0.count } == 1, "restart preserves the outstanding drain bound")
  try drain()
  try requireTest(
    active?.target.processIdentifier == 10_006, "restart cannot resurrect an old target")
  owner.stop()

  // A newer request can arrive during synchronous registration itself.
  let reentrantSchedule = SharedValue<[() -> Void]>([])
  var reentrantOwner: AXObservation?
  var staleCancelled = false
  var installed = [pid_t]()
  reentrantOwner = AXObservation(
    schedule: { block in reentrantSchedule.withLock { $0.append(block) } },
    create: { received in
      installed.append(received.processIdentifier)
      if received.processIdentifier == 20_000 { reentrantOwner?.request(target(20_001)) }
      return TestAXSubscription(target: received) {
        if received.processIdentifier == 20_000 { staleCancelled = true }
      }
    })
  reentrantOwner?.start()
  reentrantOwner?.request(target(20_000))
  let firstDrain = reentrantSchedule.withLock { $0.removeFirst() }
  firstDrain()
  try requireTest(staleCancelled, "a superseded factory result is cancelled before installation")
  try requireTest(
    reentrantSchedule.withLock { $0.count } == 1, "registration race queues one follow-up")
  let secondDrain = reentrantSchedule.withLock { $0.removeFirst() }
  secondDrain()
  try requireTest(installed == [20_000, 20_001], "latest registration is not lost")
  reentrantOwner?.stop()
  reentrantOwner = nil
  return 6
}
