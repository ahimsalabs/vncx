// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

// Minimal test runner. Swift Testing doesn't discover tests under the Command Line Tools toolchain, so the unit
// tests run as a plain executable: `swift run vncx-tests` (or `task test`).
import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var currentTest = ""

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    do {
        if try !condition() {
            failures += 1
            print("  FAIL \(currentTest) \((("\(file)" as NSString).lastPathComponent)):\(line) \(message)")
        }
    } catch {
        failures += 1
        print("  FAIL \(currentTest) \(line): threw \(error)")
    }
}

func run(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    let before = failures
    do { try body() } catch { failures += 1; print("  FAIL \(name): threw \(error)") }
    print(failures == before ? "  ok   \(name)" : "  FAILED \(name)")
}

run("modpow g^x matches Python") { ModularTests().generatorPowerMatchesPython() }
run("modpow base^x matches Python") { ModularTests().arbitraryBaseMatchesPython() }
run("modpow small moduli") { ModularTests().smallModulus() }
run("VNC auth matches OpenSSL DES") { try AuthTests().vncAuthMatchesOpenSSL() }
run("ARD auth round trip") { try AuthTests().ardRoundTrip() }
run("address parsing") { AddressTests().parse() }
run("address rejects garbage") { AddressTests().rejectsGarbage() }
run("ZRLE tile subencodings") { try DecoderTests().zrleTiles() }
run("Tight palette and gradient filters") { try DecoderTests().tightFilters() }
run("Wake-on-LAN MAC parsing and packet") { WakeTests().macParsing() }
run("Picture quality raw values and order") { try QualityTests().rawValues() }
run("Motion refresh rectangles from grid cells") { MotionTests().cellRects() }

print(failures == 0 ? "all tests passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
