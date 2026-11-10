import Foundation

// Fixed-capacity metadata ring. Producers never wait; no text enters this queue.
final class InputQueue {
  static let capacity = 64
  private let mutex = NSLock()
  private let available = DispatchSemaphore(value: 0)
  private var storage = [InputMetadata?](repeating: nil, count: capacity)
  private var head = 0
  private var count = 0
  private var closed = false

  func trySubmit(_ input: InputMetadata) -> Bool {
    guard mutex.try() else { return false }
    guard !closed, count < Self.capacity else {
      mutex.unlock()
      return false
    }
    storage[(head + count) % Self.capacity] = input
    count += 1
    mutex.unlock()
    available.signal()
    return true
  }

  func take() -> InputMetadata? {
    available.wait()
    mutex.lock()
    defer { mutex.unlock() }
    guard !closed, count != 0 else { return nil }
    let result = storage[head]
    storage[head] = nil
    head = (head + 1) % Self.capacity
    count -= 1
    return result
  }

  // Called only during shutdown, after listener cleanup has resolved its saved
  // action. Discard pending metadata and wake the sole waiting consumer.
  func close() {
    mutex.lock()
    guard !closed else {
      mutex.unlock()
      return
    }
    closed = true
    for index in storage.indices { storage[index] = nil }
    count = 0
    mutex.unlock()
    available.signal()
  }
}
