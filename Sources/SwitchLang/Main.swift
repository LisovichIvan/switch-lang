import AppKit
import ApplicationServices
import Carbon

@MainActor
@main
struct SwitchLangMain {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
      switch arguments {
      case ["--self-test"]:
        let groups =
          try runCoreTests() + runSettingsTests() + runCapsLockTests() + runKeyboardEventsTests()
          + runRuntimeTests() + runWorkerTests() + runAtomicTests() + runAXObservationTests()
        try requireTest(groups > 0, "self-test registered groups")
        return
      case ["--test-logging"]:
        let groups = try runDiagnosticsTests()
        print("Swift diagnostic logger: \(groups) checks passed (synthetic records only).")
        return
      case ["--diagnose"]:
        print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
        print("Input Monitoring: \(CGPreflightListenEventAccess() ? "granted" : "missing")")
        print("Secure Input: \(IsSecureEventInputEnabled() ? "enabled" : "disabled")")
        return
      case ["--check-layouts"]:
        let valid = KeyboardLayouts.checkLayouts()
        print(
          "System ABC/U.S. ↔ Russian keyboard tables: \(valid ? "66 key mappings, Caps Lock and keyboard plans match" : "unavailable or mismatched")"
        )
        if !valid { exit(EXIT_FAILURE) }
        return
      case ["--benchmark"]:
        try benchmark()
        return
      case []:
        try runApplication()
      default:
        fputs(
          "Usage: switch-lang [--diagnose | --self-test | --check-layouts | --benchmark | --test-logging]\n",
          stderr)
        exit(EXIT_FAILURE)
      }
    } catch let error as TestFailure {
      fputs("Self-test failed: \(error.description)\n", stderr)
      exit(EXIT_FAILURE)
    } catch {
      fputs("Could not initialize Switch Lang.\n", stderr)
      exit(EXIT_FAILURE)
    }
  }

  private static func runApplication() throws {
    // Preinitialize all diagnostic queues/locks before any input callback.
    let diagnosticLogger = DiagnosticLogger.shared
    let queue = InputQueue()
    let runtime = try KeyboardRuntime(submitInput: { queue.trySubmit($0) })
    let worker = CorrectionWorker(queue: queue, runtime: runtime)
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = ApplicationDelegate(runtime: runtime)
    application.delegate = delegate
    worker.start()
    application.run()
    delegate.shutdown()
    runtime.waitUntilStopped()
    worker.stopAndWait()
    diagnosticLogger.shutdown()
    application.delegate = nil
  }

  private static func benchmark() throws {
    let cases: [(String, Layout)] = [
      ("ghbdtn", .english), ("руддщ", .russian), ("hello", .english),
    ]
    var samples = [UInt64]()
    samples.reserveCapacity(20_000)
    let benchmarkSink = try AtomicUInt64()
    var checksum = 0
    for index in 0..<20_000 {
      let sample = cases[index % cases.count]
      let start = DispatchTime.now().uptimeNanoseconds
      let result = automaticCorrection(sample.0, source: sample.1)
      let end = DispatchTime.now().uptimeNanoseconds
      checksum &+= result?.utf16.count ?? 0
      samples.append(end >= start ? end - start : 0)
    }
    benchmarkSink.value = UInt64(checksum)
    samples.sort()
    print("Synthetic detector only, 20000 samples; not an event-tap or UI benchmark.")
    print("p50=\(samples[10_000]) ns p95=\(samples[19_000]) ns p99=\(samples[19_800]) ns")
  }
}
