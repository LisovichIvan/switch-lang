import AtomicSupport

struct AtomicAllocationFailure: Error {}

// Stable, heap-owned C11 cells retain the previous sequentially-consistent
// semantics on macOS 11. No allocation, lock, retry or I/O in these operations.
final class AtomicUInt64 {
  private let pointer: OpaquePointer

  init(_ initial: UInt64 = 0) throws {
    guard let pointer = switch_lang_atomic_create(initial) else { throw AtomicAllocationFailure() }
    self.pointer = pointer
  }

  deinit { switch_lang_atomic_destroy(pointer) }

  var value: UInt64 {
    get { switch_lang_atomic_load(pointer) }
    set { switch_lang_atomic_store(pointer, newValue) }
  }

  var boolValue: Bool {
    get { value != 0 }
    set { value = newValue ? 1 : 0 }
  }

  @discardableResult func exchange(_ desired: UInt64) -> UInt64 {
    switch_lang_atomic_exchange(pointer, desired)
  }

  @discardableResult func fetchAdd(_ amount: UInt64) -> UInt64 {
    switch_lang_atomic_fetch_add(pointer, amount)
  }

  @discardableResult func fetchOr(_ bits: UInt64) -> UInt64 {
    switch_lang_atomic_fetch_or(pointer, bits)
  }

  func compareExchange(expected: UInt64, desired: UInt64) -> Bool {
    switch_lang_atomic_compare_exchange(pointer, expected, desired)
  }
}
