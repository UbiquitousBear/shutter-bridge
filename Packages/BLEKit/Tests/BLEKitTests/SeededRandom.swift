// A reproducible generator for the seeded garbage-input tests (GarbageInputTests.swift), the same SplitMix64 as PTPKit's
// SeededRandom.swift, trimmed to what these tests use.
//
// Determinism rules, so a failing "seed 0x… iteration N" replays identically on every machine and toolchain:
//   - No Foundation or system randomness, and no `random(in:using:)`: the standard library may change how it maps a
//     generator's output onto a range. Every value here is built from `SplitMix64.next()` with integer arithmetic only.
//   - Never derive a generated value from iterating a Set or Dictionary: Swift seeds hashing per process.
//   - Every base seed is a literal constant in the test that uses it.

import Foundation

/// SplitMix64 (Steele, Lea, Flood 2014; Vigna's reference). Deliberately not a RandomNumberGenerator, so a stray
/// `Int.random(in:using:)` won't compile.
struct SplitMix64 {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// The generator for iteration `i` of a test with base seed `base`. The index is hashed first, so iterations don't overlap.
    static func iteration(_ i: Int, of base: UInt64) -> SplitMix64 {
        var s = SplitMix64(seed: base &+ UInt64(i))
        return SplitMix64(seed: s.next())
    }

    /// Uniform in 0..<n (Lemire's multiply-high, without rejection). n == 0 returns 0.
    mutating func below(_ n: UInt64) -> UInt64 {
        n == 0 ? 0 : next().multipliedFullWidth(by: n).high
    }

    mutating func int(_ r: ClosedRange<Int>) -> Int {
        r.lowerBound + Int(below(UInt64(r.upperBound - r.lowerBound) + 1))
    }

    mutating func chance(_ oneIn: UInt64) -> Bool { below(oneIn) == 0 }

    mutating func element<T>(_ a: [T]) -> T { a[int(0 ... a.count - 1)] }

    /// A byte, one draw in 8 from the edge table.
    mutating func u8() -> UInt8 {
        chance(8) ? element([0, 1, 2, 3, 0x7F, 0x80, 0xFE, 0xFF]) : UInt8(truncatingIfNeeded: next())
    }

    /// `n` bytes from `u8()`.
    mutating func bytes(_ n: Int) -> [UInt8] {
        (0 ..< n).map { _ in u8() }
    }

    /// A length in 0...max: one draw in 8 gives 0, one in 8 gives `max`, the rest are uniform.
    mutating func length(_ max: Int) -> Int {
        switch below(8) {
        case 0: 0
        case 1: max
        default: int(0 ... max)
        }
    }

    /// A printable ASCII string (0x20 to 0x7E) of `count` characters.
    mutating func printable(_ count: Int) -> String {
        String(decoding: (0 ..< count).map { _ in UInt8(int(0x20 ... 0x7E)) }, as: UTF8.self)
    }
}
