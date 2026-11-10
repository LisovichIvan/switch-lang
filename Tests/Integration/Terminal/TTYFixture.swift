import Darwin
import Foundation

// Isolated, bounded synthetic editor. Never launches a shell or executes input.
private let commandName = Notification.Name("local.switch-lang.terminal-fixture.command")
private let stateName = Notification.Name("local.switch-lang.terminal-fixture.state")
private let words = [
  "", "ghbdtn", "привет", "руддщ", "hello", "Ghbdtn", "Привет", "ghbdtn ", "привет ", "руддщ ",
  "hello ",
]

private final class TTYFixture {
  let session: String
  let directory: String
  private var original = termios()
  private var input: DispatchSourceRead?
  private var observer: NSObjectProtocol?
  private var timeout: DispatchWorkItem?
  private var text = ""
  private var pendingUTF8: [UInt8] = []
  private var escape: [UInt8] = []
  private var returns = 0
  private var tabs = 0
  private var lastActionMatch = -1
  private var deletions = 0
  private var received = 0
  private var request = 0
  private var stopped = false
  private var echo = true

  init(session: String, directory: String) {
    self.session = session
    self.directory = directory
  }

  private func output(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    return bytes.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return true }
      var offset = 0
      var attempts = 0
      while offset < buffer.count && attempts < 32 {
        attempts += 1
        let count = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        offset += count
      }
      return offset == buffer.count
    }
  }

  func start() -> Bool {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
      tcgetattr(STDIN_FILENO, &original) == 0
    else { return false }
    var raw = original
    cfmakeraw(&raw)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return false }
    observer = DistributedNotificationCenter.default().addObserver(
      forName: commandName, object: session, queue: .main
    ) { [weak self] notification in self?.command(notification) }
    let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    source.setEventHandler { [weak self] in self?.readInput() }
    input = source
    source.resume()
    let timeout = DispatchWorkItem { [weak self] in self?.finish() }
    self.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)
    guard output("\u{1b}]2;Switch Lang Synthetic Terminal \(session)\u{7}\u{1b}[2J\u{1b}[H> ")
    else {
      finish()
      return false
    }
    publish()
    return true
  }

  private func match() -> Int { words.firstIndex { Array($0.utf16) == Array(text.utf16) } ?? -1 }

  private func publish() {
    let state: [String: Any] = [
      "session": session, "pid": getpid(), "parentPID": getppid(),
      "request": request, "match": match(), "length": text.utf16.count,
      "returns": returns, "tabs": tabs, "actionMatch": lastActionMatch,
      "deletions": deletions, "received": received, "echo": echo,
    ]
    // State contains only fixed match IDs/counts, never arbitrary input.
    if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
      data.count <= 2048
    {
      try? data.write(to: URL(fileURLWithPath: directory + "/fixture-state.json"), options: .atomic)
    }
    DistributedNotificationCenter.default().postNotificationName(
      stateName, object: session, userInfo: state, deliverImmediately: true)
  }

  private func command(_ notification: Notification) {
    guard !stopped, let information = notification.userInfo,
      let name = information["command"] as? String,
      let request = information["request"] as? NSNumber
    else { return }
    self.request = request.intValue
    switch name {
    case "reset":
      text = ""
      pendingUTF8 = []
      escape = []
      echo = true
      returns = 0
      tabs = 0
      lastActionMatch = -1
      deletions = 0
      received = 0
      guard output("\u{1b}[2J\u{1b}[H> ") else {
        finish()
        return
      }
    case "prepareNoEcho":
      text = ""
      pendingUTF8 = []
      escape = []
      echo = false
      returns = 0
      tabs = 0
      lastActionMatch = -1
      deletions = 0
      received = 0
      guard output("\u{1b}[2J\u{1b}[H> ghbdtn") else {
        finish()
        return
      }
    case "snapshot": break
    case "quit":
      finish()
      return
    default: return
    }
    publish()
  }

  private func readInput() {
    guard !stopped else { return }
    var bytes = [UInt8](repeating: 0, count: 256)
    let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
    guard count > 0 else {
      finish()
      return
    }
    for byte in bytes.prefix(count) {
      received += 1
      guard received <= 4096 else {
        finish()
        return
      }
      if !escape.isEmpty || byte == 27 {
        escape.append(byte)
        if escape.count >= 3 || (escape.count == 2 && byte != 91) {
          // Deliberately no shell/editor navigation fallback.
          escape.removeAll(keepingCapacity: true)
        }
        continue
      }
      if byte == 13 || byte == 10 || byte == 9 {
        pendingUTF8.removeAll(keepingCapacity: true)
        lastActionMatch = match()
        if byte == 9 {
          tabs += 1
        } else {
          returns += 1
          // Synthetic command completion: no shell or input execution. The
          // next prompt is deliberately later than Return's input callback.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.stopped else { return }
            self.text = ""
            guard self.output("\r\n> ") else {
              self.finish()
              return
            }
            self.publish()
          }
        }
      } else if byte == 127 || byte == 8 {
        pendingUTF8.removeAll(keepingCapacity: true)
        if !text.isEmpty {
          text.removeLast()
          deletions += 1
          if echo && !output("\u{8} \u{8}") {
            finish()
            return
          }
        }
      } else if byte >= 32 {
        pendingUTF8.append(byte)
        guard pendingUTF8.count <= 4 else {
          finish()
          return
        }
        if let decoded = String(bytes: pendingUTF8, encoding: .utf8) {
          guard decoded.unicodeScalars.count == 1,
            decoded.unicodeScalars.allSatisfy({
              (32...126).contains($0.value) || (0x410...0x44F).contains($0.value)
                || $0.value == 0x401 || $0.value == 0x451
            }), text.unicodeScalars.count < 80
          else {
            finish()
            return
          }
          text += decoded
          pendingUTF8.removeAll(keepingCapacity: true)
          if echo && !output(decoded) {
            finish()
            return
          }
        }
      }
    }
    publish()
  }

  func finish() {
    guard !stopped else { return }
    stopped = true
    timeout?.cancel()
    input?.cancel()
    input = nil
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    observer = nil
    _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
    _ = output("\r\nSynthetic test finished.\r\n")
    exit(0)
  }
}

@main
private struct Main {
  static func main() {
    umask(0o077)
    let arguments = CommandLine.arguments
    guard arguments.count == 3, UUID(uuidString: arguments[1]) != nil,
      arguments[2] == TerminalIntegrationConfiguration.directory
    else { exit(2) }
    let fixture = TTYFixture(session: arguments[1], directory: arguments[2])
    guard fixture.start() else { exit(3) }
    withExtendedLifetime(fixture) { RunLoop.main.run() }
  }
}
