import Foundation

struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

func requireTest(_ condition: @autoclosure () -> Bool, _ name: String) throws {
  if !condition() { throw TestFailure(description: name) }
}
