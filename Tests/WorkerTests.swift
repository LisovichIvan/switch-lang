import Foundation

func runWorkerTests() throws -> Int {
  func metadata(_ kind: InputKind = .key, _ keycode: UInt16, flags: UInt64 = 0) -> InputMetadata {
    InputMetadata(
      kind: kind, keycode: keycode, keyboardType: 0, flags: flags, generation: 1, timestampNS: 1)
  }
  for keycode: UInt16 in [53, 71, 114, 115, 116, 117, 118, 119, 121, 123, 124, 125, 126] {
    try requireTest(isNavigationKey(keycode), "navigation invalidates")
    try requireTest(invalidatesKeyTracking(metadata(.key, keycode)), "navigation tracking gate")
  }
  for keycode: UInt16 in [0, 36, 48, 51, 76] {
    try requireTest(!isNavigationKey(keycode), "ordinary/action/backspace not navigation")
  }
  for flags: UInt64 in [1 << 20, 1 << 18, 1 << 19, 1 << 23, 1 << 22] {
    try requireTest(
      invalidatesKeyTracking(metadata(.key, 0, flags: flags)), "non-hotkey shortcut invalidates")
    try requireTest(
      !invalidatesKeyTracking(metadata(.hotkey, 0, flags: flags)),
      "correction hotkey keeps candidate")
  }
  try requireTest(
    !invalidatesKeyTracking(metadata(.key, 0, flags: (1 << 17) | (1 << 16))),
    "shift/caps keeps candidate")
  for keycode: UInt16 in [36, 48, 76] {
    var tracker = Tracker()
    tracker.observe("ghbdtn", source: .english, focus: 1)
    try requireTest(
      tracker.candidateBeforeAction()?.replacement == "привет", "original action candidate exists")
    let passedThrough = metadata(.key, keycode)
    if invalidatesKeyTracking(passedThrough) { tracker.clear() }
    try requireTest(
      tracker.candidateBeforeAction() == nil && tracker.candidate(automatic: false) == nil,
      "passed-through action cannot correct after submission/focus change")
    try requireTest(
      !invalidatesKeyTracking(metadata(.action, keycode)), "saved undelivered action is distinct")
  }
  try requireTest(
    decodeUTF16Strict([0xD800]) == nil && decodeUTF16Strict([0xDC00]) == nil
      && decodeUTF16Strict([0xD800, 0x0061]) == nil, "invalid UTF16 is not repaired")
  try requireTest(decodeUTF16Strict([0xD83D, 0xDE42]) == "🙂", "valid supplementary scalar")
  let queue = InputQueue()
  for index in 0..<InputQueue.capacity {
    var input = metadata(.key, 0)
    input.generation = UInt64(index + 1)
    try requireTest(queue.trySubmit(input), "bounded queue accepts capacity")
  }
  try requireTest(!queue.trySubmit(metadata(.key, 0)), "bounded queue refuses overflow")
  for index in 0..<InputQueue.capacity {
    try requireTest(queue.take()?.generation == UInt64(index + 1), "metadata queue preserves FIFO")
  }
  queue.close()
  try requireTest(
    queue.take() == nil && !queue.trySubmit(metadata(.key, 0)), "closed queue rejects/wakes")
  let waiting = InputQueue()
  let finished = DispatchSemaphore(value: 0)
  let result = SharedValue(false)
  DispatchQueue.global().async {
    let stopped = waiting.take() == nil
    result.withLock { $0 = stopped }
    finished.signal()
  }
  waiting.close()
  try requireTest(
    finished.wait(timeout: .now() + 2) == .success && result.withLock { $0 }, "close wakes consumer"
  )
  let concurrent = InputQueue()
  let producers = DispatchGroup()
  let consumerDone = DispatchSemaphore(value: 0)
  let consumerReady = DispatchSemaphore(value: 0)
  let validOrder = SharedValue(true)
  DispatchQueue.global().async {
    var lastByProducer = [UInt64: UInt64]()
    var valid = concurrent.take()?.generation == 1
    consumerReady.signal()
    while let input = concurrent.take() {
      let producer = input.generation >> 32
      let sequence = input.generation & 0xFFFF_FFFF
      if let last = lastByProducer[producer], sequence <= last { valid = false }
      lastByProducer[producer] = sequence
    }
    validOrder.withLock { $0 = valid }
    consumerDone.signal()
  }
  var initial = metadata(.key, 0)
  initial.generation = 1
  try requireTest(concurrent.trySubmit(initial), "concurrent queue primed")
  try requireTest(consumerReady.wait(timeout: .now() + 5) == .success, "consumer started")
  for producer in 1...4 {
    producers.enter()
    DispatchQueue.global().async {
      for sequence in 1...1_000 {
        var input = InputMetadata(kind: .key)
        input.generation = UInt64(producer) << 32 | UInt64(sequence)
        _ = concurrent.trySubmit(input)
      }
      producers.leave()
    }
  }
  try requireTest(producers.wait(timeout: .now() + 5) == .success, "nonblocking producers finish")
  concurrent.close()
  concurrent.close()
  try requireTest(
    consumerDone.wait(timeout: .now() + 5) == .success && validOrder.withLock { $0 },
    "concurrent ring never duplicates or reorders a producer and closes idempotently")
  return 8
}
