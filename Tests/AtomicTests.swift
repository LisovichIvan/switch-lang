import Foundation

func runAtomicTests() throws -> Int {
  let value = try AtomicUInt64(7)
  try requireTest(value.value == 7, "atomic initial value")
  try requireTest(
    value.compareExchange(expected: 7, desired: 8) && value.value == 8, "atomic claim")
  try requireTest(
    !value.compareExchange(expected: 7, desired: 9) && value.value == 8, "obsolete claim refused")
  value.fetchAdd(1)
  try requireTest(
    !value.compareExchange(expected: 8, desired: 9) && value.value == 9,
    "invalidation defeats captured generation")
  try requireTest(value.exchange(0) == 9 && value.value == 0, "atomic exchange")
  try requireTest(value.fetchOr(4) == 0 && value.value == 4, "coalesced report bits")
  value.boolValue = false
  try requireTest(!value.boolValue, "atomic Boolean false")
  value.boolValue = true
  try requireTest(value.boolValue && value.value == 1, "atomic Boolean true")
  let counter = try AtomicUInt64()
  let group = DispatchGroup()
  for _ in 0..<4 {
    group.enter()
    DispatchQueue.global().async {
      for _ in 0..<10_000 { counter.fetchAdd(1) }
      group.leave()
    }
  }
  try requireTest(
    group.wait(timeout: .now() + 5) == .success && counter.value == 40_000,
    "lock-free counter retains concurrent updates")
  return 2
}
