import Foundation

/// A minimal test harness.
///
/// XCTest ships with Xcode, not with the Command Line Tools, and FlowTrace is
/// built with the Command Line Tools on purpose. Rather than make a 10GB Xcode
/// install a prerequisite for running the suite, the suite is an executable:
/// `swift run flowtrace-tests`, non-zero exit on failure, CI-friendly.
enum TestKit {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var currentTest = ""
    nonisolated(unsafe) static var currentFailed = false

    static var useColor: Bool { isatty(fileno(stdout)) == 1 }
    static func dim(_ s: String) -> String { useColor ? "\u{1B}[2m\(s)\u{1B}[0m" : s }
    static func red(_ s: String) -> String { useColor ? "\u{1B}[31m\(s)\u{1B}[0m" : s }
    static func green(_ s: String) -> String { useColor ? "\u{1B}[32m\(s)\u{1B}[0m" : s }
    static func bold(_ s: String) -> String { useColor ? "\u{1B}[1m\(s)\u{1B}[0m" : s }

    static func suite(_ name: String) {
        print("")
        print(bold(name))
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        currentFailed = false
        do {
            try body()
        } catch {
            fail("threw \(error)")
        }
        if currentFailed {
            print("  \(red("✗")) \(name)")
        } else {
            passed += 1
            print("  \(green("✓")) \(dim(name))")
        }
    }

    static func fail(_ message: String, file: String = #fileID, line: Int = #line) {
        currentFailed = true
        failures.append("\(currentTest) — \(message)  \(dim("\(file):\(line)"))")
    }

    static func summarize() -> Never {
        print("")
        if failures.isEmpty {
            print(green("\(passed) passed"))
            print("")
            exit(0)
        }
        print(red("\(failures.count) failed, \(passed) passed"))
        for failure in failures { print("  \(red("✗")) \(failure)") }
        print("")
        exit(1)
    }
}

// MARK: - Assertions

func expect(
    _ condition: Bool, _ message: @autoclosure () -> String = "expected true",
    file: String = #fileID, line: Int = #line
) {
    if !condition { TestKit.fail(message(), file: file, line: line) }
}

func expectEqual<T: Equatable>(
    _ actual: T?, _ expected: T?, _ label: String = "",
    file: String = #fileID, line: Int = #line
) {
    guard actual != expected else { return }
    let prefix = label.isEmpty ? "" : "\(label): "
    TestKit.fail(
        "\(prefix)expected \(describe(expected)), got \(describe(actual))",
        file: file, line: line
    )
}

func expectNil(_ value: Any?, _ label: String = "", file: String = #fileID, line: Int = #line) {
    if let value {
        TestKit.fail("\(label) expected nil, got \(value)", file: file, line: line)
    }
}

func expectNotNil(_ value: Any?, _ label: String = "", file: String = #fileID, line: Int = #line) {
    if value == nil { TestKit.fail("\(label) expected a value, got nil", file: file, line: line) }
}

func expectContains(
    _ haystack: String?, _ needle: String,
    file: String = #fileID, line: Int = #line
) {
    guard let haystack, haystack.contains(needle) else {
        TestKit.fail("expected to contain \"\(needle)\", got \(describe(haystack))", file: file, line: line)
        return
    }
}

func expectNotContains(
    _ haystack: String?, _ needle: String,
    file: String = #fileID, line: Int = #line
) {
    if let haystack, haystack.contains(needle) {
        TestKit.fail("expected NOT to contain \"\(needle)\", got \(describe(haystack))", file: file, line: line)
    }
}

private func describe(_ value: Any?) -> String {
    guard let value else { return "nil" }
    if let string = value as? String { return "\"\(string)\"" }
    return "\(value)"
}

/// Thrown by helpers that cannot continue; caught by `TestKit.test`.
struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func unwrap<T>(_ value: T?, _ label: String = "value") throws -> T {
    guard let value else { throw TestFailure("\(label) was nil") }
    return value
}
