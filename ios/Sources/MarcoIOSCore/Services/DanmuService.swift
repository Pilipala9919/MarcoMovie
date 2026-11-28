// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

public struct DanmuMatchCandidate: Equatable, Hashable, Identifiable, Sendable {
    public var id: String { "\(sourceOrigin)|\(episodeId)" }
    public let sourceOrigin: String
    public let animeId: String
    public let animeTitle: String
    public let episodeId: String
    public let episodeTitle: String
    public let confidence: Double

    public init(
        sourceOrigin: String,
        animeId: String,
        animeTitle: String,
        episodeId: String,
        episodeTitle: String,
        confidence: Double = 1.0
    ) {
        self.sourceOrigin = sourceOrigin
        self.animeId = animeId
        self.animeTitle = animeTitle
        self.episodeId = episodeId
        self.episodeTitle = episodeTitle
        self.confidence = confidence
    }
}

public struct DanmuRuleValidationResult: Equatable, Sendable {
    public let valid: Bool
    public let error: String

    public init(valid: Bool, error: String = "") {
        self.valid = valid
        self.error = error
    }

    public static let ok = DanmuRuleValidationResult(valid: true, error: "")

    public static func fail(_ reason: String) -> DanmuRuleValidationResult {
        DanmuRuleValidationResult(valid: false, error: reason)
    }
}

// MARK: - Recursive-Descent Static ReDoS Validator

private struct SafeRegexBranchStats {
    let unboundedQuants: Int
    let detUnboundedQuants: Int
    let totalUnboundedQuants: Int
    let varQuants: Int
    let altGroups: Int
    let choices: Int
    let maxExpandedLen: Int
    let work: Int
}

private struct SafeRegexQuantStats {
    static let none = SafeRegexQuantStats(unbounded: 0, varQuant: 0, choices: 1, maxLen: 1, lazy: false)
    let unbounded: Int
    let varQuant: Int
    let choices: Int
    let maxLen: Int
    let lazy: Bool
}

private struct SafeRegexAtomInfo {
    enum Kind {
        case other
        case literal
        case digit
        case space
        case word
        case asciiClass
    }

    static let other = SafeRegexAtomInfo(kind: .other, literalCode: -1, asciiMask: nil, isDot: false)
    static let dot = SafeRegexAtomInfo(kind: .other, literalCode: -1, asciiMask: nil, isDot: true)
    static let digit = SafeRegexAtomInfo(kind: .digit, literalCode: -1, asciiMask: nil, isDot: false)
    static let space = SafeRegexAtomInfo(kind: .space, literalCode: -1, asciiMask: nil, isDot: false)
    static let word = SafeRegexAtomInfo(kind: .word, literalCode: -1, asciiMask: nil, isDot: false)

    let kind: Kind
    let literalCode: Int
    let asciiMask: [UInt32]?
    let isDot: Bool

    static func literal(_ code: Int) -> SafeRegexAtomInfo {
        SafeRegexAtomInfo(kind: .literal, literalCode: code, asciiMask: nil, isDot: false)
    }

    static func asciiClass(_ mask: [UInt32]) -> SafeRegexAtomInfo {
        SafeRegexAtomInfo(kind: .asciiClass, literalCode: -1, asciiMask: mask, isDot: false)
    }

    func isDisjointFromLiteral(_ sepCode: Int) -> Bool {
        switch kind {
        case .literal:
            if literalCode >= 128 && sepCode >= 128
                && !Self.isCaselessCjk(literalCode) && !Self.isCaselessCjk(sepCode)
            {
                return false
            }
            return Self.foldAsciiLower(literalCode) != Self.foldAsciiLower(sepCode)
        case .digit:
            return sepCode < 0x30 || sepCode > 0x39
        case .space:
            return !Self.isRegexWhitespace(sepCode)
        case .word:
            return !((sepCode >= 0x30 && sepCode <= 0x39)
                || (sepCode >= 0x41 && sepCode <= 0x5A)
                || (sepCode >= 0x61 && sepCode <= 0x7A)
                || sepCode == 0x5F)
        case .asciiClass:
            guard sepCode >= 0 && sepCode < 128, let mask = asciiMask else { return true }
            let folded = Self.foldAsciiLower(sepCode)
            let matchRaw = (mask[sepCode >> 5] & (UInt32(1) << (sepCode & 31))) != 0
            let matchFold = (mask[folded >> 5] & (UInt32(1) << (folded & 31))) != 0
            return !matchRaw && !matchFold
        case .other:
            return false
        }
    }

    static func isCaselessCjk(_ ch: Int) -> Bool {
        (ch >= 0x4E00 && ch <= 0x9FFF)
            || (ch >= 0x3400 && ch <= 0x4DBF)
            || (ch >= 0x3040 && ch <= 0x30FF)
    }

    static func foldAsciiLower(_ ch: Int) -> Int {
        (ch >= 0x41 && ch <= 0x5A) ? (ch + 32) : ch
    }

    static func isRegexWhitespace(_ ch: Int) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0x0C || ch == 0x0B
            || ch == 0x00A0 || ch == 0x1680 || (ch >= 0x2000 && ch <= 0x200A)
            || ch == 0x2028 || ch == 0x2029 || ch == 0x202F || ch == 0x205F
            || ch == 0x3000 || ch == 0xFEFF
    }
}

private final class SafeRegexValidator {
    private static let unboundedChoiceCost = 181
    private static let workCap = DanmuBlockFilter.maxTotalWork + 1

    private let units: [UInt16]
    private var pos: Int = 0
    private var wildcardCount: Int = 0
    private var groupDepth: Int = 0
    private var errorMessage: String?

    init(_ expr: String) {
        self.units = Array(expr.utf16)
    }

    func validate() -> DanmuRuleValidationResult {
        for cu in units where Self.isSurrogateCodeUnit(Int(cu)) {
            return .fail("正则表达式不支持代理项或扩展平面字符")
        }
        let root = parseAlternation(isTopLevel: true)
        if let err = errorMessage {
            return .fail(err)
        }
        if pos != units.count {
            return .fail("正则表达式包含多余的闭合括号")
        }
        guard let root = root else {
            return .fail("正则表达式语法无效")
        }
        if root.choices > DanmuBlockFilter.maxTotalChoices {
            return .fail("正则表达式总回溯分支复杂度过高")
        }
        if root.totalUnboundedQuants > DanmuBlockFilter.maxTotalUnbounded {
            return .fail("正则表达式无界量词总数超过安全上限")
        }
        if root.work > DanmuBlockFilter.maxTotalWork {
            return .fail("正则表达式总回溯工作量超过安全上限")
        }
        return .ok
    }

    private func fail(_ reason: String) {
        if errorMessage == nil {
            errorMessage = reason
        }
    }

    private static func isSurrogateCodeUnit(_ cu: Int) -> Bool {
        cu >= 0xD800 && cu <= 0xDFFF
    }

    private static func satAdd(_ a: Int, _ b: Int) -> Int {
        let s = a &+ b
        return (s < 0 || s >= workCap) ? workCap : s
    }

    private static func satMul(_ a: Int, _ b: Int) -> Int {
        guard a > 0 && b > 0 else { return 0 }
        let (p, overflow) = a.multipliedReportingOverflow(by: b)
        return (overflow || p >= workCap) ? workCap : p
    }

    private static func isQuantStart(_ ch: Int) -> Bool {
        ch == 0x2A || ch == 0x2B || ch == 0x3F || ch == 0x7B
    }

    private static func isHexDigit(_ ch: Int) -> Bool {
        (ch >= 0x30 && ch <= 0x39)
            || (ch >= 0x61 && ch <= 0x66)
            || (ch >= 0x41 && ch <= 0x46)
    }

    private static func isAsciiPunctuation(_ ch: Int) -> Bool {
        if ch < 0x21 || ch > 0x7E { return false }
        if ch >= 0x30 && ch <= 0x39 { return false }
        if ch >= 0x61 && ch <= 0x7A { return false }
        if ch >= 0x41 && ch <= 0x5A { return false }
        return ch != 0x5F
    }

    private func unit(at index: Int) -> Int {
        Int(units[index])
    }

    private func peekUnquantifiedLiteralCode() -> Int {
        guard pos < units.count else { return -1 }
        let c = unit(at: pos)
        switch c {
        case 0x7C, 0x29, 0x28, 0x5B, 0x5D, 0x7B, 0x7D, 0x2A, 0x2B, 0x3F, 0x5E, 0x24, 0x2E:
            return -1
        default:
            break
        }
        let code: Int
        let afterPos: Int
        if c == 0x5C {
            guard pos + 1 < units.count else { return -1 }
            let next = unit(at: pos + 1)
            switch next {
            case 0x74: code = 0x09; afterPos = pos + 2
            case 0x6E: code = 0x0A; afterPos = pos + 2
            case 0x72: code = 0x0D; afterPos = pos + 2
            case 0x66: code = 0x0C; afterPos = pos + 2
            default:
                if Self.isAsciiPunctuation(next) {
                    code = next
                    afterPos = pos + 2
                } else {
                    return -1
                }
            }
        } else {
            code = c
            afterPos = pos + 1
        }
        if afterPos < units.count && Self.isQuantStart(unit(at: afterPos)) {
            return -1
        }
        return code
    }

    private func parseAlternation(isTopLevel: Bool) -> SafeRegexBranchStats? {
        guard let first = parseBranch(), errorMessage == nil else { return nil }
        var maxUnbounded = first.unboundedQuants
        var maxDetUnbounded = first.detUnboundedQuants
        var sumTotalUnbounded = first.totalUnboundedQuants
        var maxVar = first.varQuants
        var maxAltGroups = first.altGroups
        var sumChoices = first.choices
        var maxExpandedLen = first.maxExpandedLen
        var sumWork = first.work
        var sumBoundedWork = (first.totalUnboundedQuants == 0 && first.choices > 1) ? first.work : 0
        var branchCount = 1

        if isTopLevel && !checkTopLevelTotals(
            sumChoices: sumChoices,
            sumTotalUnbounded: sumTotalUnbounded,
            sumBoundedWork: sumBoundedWork,
            sumWork: sumWork
        ) {
            return nil
        }

        while pos < units.count && unit(at: pos) == 0x7C {
            pos += 1
            guard let next = parseBranch(), errorMessage == nil else { return nil }
            branchCount += 1
            maxUnbounded = max(maxUnbounded, next.unboundedQuants)
            maxDetUnbounded = max(maxDetUnbounded, next.detUnboundedQuants)
            sumTotalUnbounded = Self.satAdd(sumTotalUnbounded, next.totalUnboundedQuants)
            maxVar = max(maxVar, next.varQuants)
            maxAltGroups = max(maxAltGroups, next.altGroups)
            maxExpandedLen = max(maxExpandedLen, next.maxExpandedLen)
            sumChoices = Self.satAdd(sumChoices, next.choices)
            sumWork = Self.satAdd(sumWork, next.work)
            if next.totalUnboundedQuants == 0 && next.choices > 1 {
                sumBoundedWork = Self.satAdd(sumBoundedWork, next.work)
            }
            if isTopLevel && !checkTopLevelTotals(
                sumChoices: sumChoices,
                sumTotalUnbounded: sumTotalUnbounded,
                sumBoundedWork: sumBoundedWork,
                sumWork: sumWork
            ) {
                return nil
            }
        }

        let reportedAltGroups = (!isTopLevel && branchCount > 1) ? (maxAltGroups + 1) : maxAltGroups
        return SafeRegexBranchStats(
            unboundedQuants: maxUnbounded,
            detUnboundedQuants: maxDetUnbounded,
            totalUnboundedQuants: sumTotalUnbounded,
            varQuants: maxVar,
            altGroups: reportedAltGroups,
            choices: sumChoices,
            maxExpandedLen: maxExpandedLen,
            work: sumWork
        )
    }

    private func checkTopLevelTotals(
        sumChoices: Int,
        sumTotalUnbounded: Int,
        sumBoundedWork: Int,
        sumWork: Int
    ) -> Bool {
        if sumChoices > DanmuBlockFilter.maxTotalChoices {
            fail("正则表达式总回溯分支复杂度过高")
            return false
        }
        if sumTotalUnbounded > DanmuBlockFilter.maxTotalUnbounded {
            fail("正则表达式无界量词总数超过安全上限")
            return false
        }
        if sumBoundedWork > DanmuBlockFilter.maxTotalBoundedWork {
            fail("正则表达式总回溯工作量超过安全上限")
            return false
        }
        if sumWork > DanmuBlockFilter.maxTotalWork {
            fail("正则表达式总回溯工作量超过安全上限")
            return false
        }
        return true
    }

    private func parseBranch() -> SafeRegexBranchStats? {
        var unbounded = 0
        var detUnbounded = 0
        var totalUnbounded = 0
        var varQuants = 0
        var altGroups = 0
        var choices = 1
        var maxExpandedLen = 0
        var work = 0
        var atomCount = 0
        var postUnboundedLiterals = 0
        var postUnboundedNonLiteral = 0
        var postUnboundedLitCodes: [Int] = []

        while pos < units.count {
            let ch = unit(at: pos)
            if ch == 0x7C || ch == 0x29 { break }
            atomCount += 1

            if ch == 0x28 {
                pos += 1
                if pos < units.count && unit(at: pos) == 0x3F {
                    if pos + 1 < units.count && unit(at: pos + 1) == 0x3A {
                        pos += 2
                    } else if pos + 1 < units.count {
                        let m = unit(at: pos + 1)
                        if m == 0x3C {
                            fail("禁止使用正则后行断言")
                        } else if m == 0x2D || (m >= 0x61 && m <= 0x7A) || (m >= 0x41 && m <= 0x5A) {
                            fail("禁止使用正则内联修饰符")
                        } else if m == 0x3D || m == 0x21 {
                            fail("禁止使用正则环视断言")
                        } else {
                            fail("禁止使用不受支持的正则扩展分组")
                        }
                        return nil
                    } else {
                        fail("正则表达式语法错误: 未闭合分组")
                        return nil
                    }
                }
                groupDepth += 1
                if groupDepth > DanmuBlockFilter.maxGroupDepth {
                    fail("正则分组嵌套层数超过上限")
                    return nil
                }
                guard let inner = parseAlternation(isTopLevel: false), errorMessage == nil else {
                    return nil
                }
                groupDepth -= 1
                guard pos < units.count && unit(at: pos) == 0x29 else {
                    fail("正则表达式语法错误: 未闭合括号")
                    return nil
                }
                pos += 1
                if pos < units.count && Self.isQuantStart(unit(at: pos)) {
                    fail("禁止闭合括号后紧跟量词以防回溯风险")
                    return nil
                }
                if unbounded > 0 {
                    postUnboundedNonLiteral = Self.satAdd(postUnboundedNonLiteral, inner.maxExpandedLen)
                    if postUnboundedNonLiteral > DanmuBlockFilter.maxPostUnboundedNonLiteral {
                        fail("正则表达式无界量词后的非字面后缀超过安全上限")
                        return nil
                    }
                }
                work = Self.satAdd(work, Self.satMul(choices, inner.work))
                unbounded += inner.unboundedQuants
                detUnbounded += inner.detUnboundedQuants
                totalUnbounded += inner.totalUnboundedQuants
                varQuants += inner.varQuants
                altGroups += inner.altGroups
                choices = Self.satMul(choices, inner.choices)
                maxExpandedLen = Self.satAdd(maxExpandedLen, inner.maxExpandedLen)
                if !checkBranchBudget(
                    unbounded: unbounded,
                    detUnbounded: detUnbounded,
                    totalUnbounded: totalUnbounded,
                    varQuants: varQuants,
                    altGroups: altGroups,
                    choices: choices,
                    maxExpandedLen: maxExpandedLen,
                    work: work
                ) {
                    return nil
                }
                continue
            }

            if Self.isQuantStart(ch) {
                fail("量词缺少前置匹配项")
                return nil
            }
            if ch == 0x7D || ch == 0x5D {
                fail("正则表达式包含未转义的闭合符号")
                return nil
            }
            if ch == 0x5E || ch == 0x24 {
                pos += 1
                if pos < units.count && Self.isQuantStart(unit(at: pos)) {
                    fail("禁止对零宽断言使用量词")
                    return nil
                }
                continue
            }

            let atom: SafeRegexAtomInfo
            if ch == 0x5B {
                guard let parsed = parseCharClass(), errorMessage == nil else { return nil }
                atom = parsed
            } else if ch == 0x5C {
                let parsed = parseOutsideEscape()
                if errorMessage != nil { return nil }
                guard let unwrapped = parsed else {
                    if pos < units.count && Self.isQuantStart(unit(at: pos)) {
                        fail("禁止对零宽断言使用量词")
                        return nil
                    }
                    continue
                }
                atom = unwrapped
            } else if ch == 0x2E {
                pos += 1
                atom = .dot
            } else {
                pos += 1
                atom = .literal(ch)
            }

            guard let q = parseQuantifier(isDot: atom.isDot), errorMessage == nil else { return nil }
            let isUnquantifiedLiteral = atom.kind == .literal && q.unbounded == 0 && q.varQuant == 0 && q.maxLen == 1

            if q.unbounded > 0 {
                let nextLit = q.lazy ? -1 : peekUnquantifiedLiteralCode()
                let deterministic = nextLit >= 0 && atom.isDisjointFromLiteral(nextLit)
                work = Self.satAdd(work, Self.satMul(choices, Self.unboundedChoiceCost))
                totalUnbounded += 1
                varQuants += 1
                maxExpandedLen = Self.satAdd(maxExpandedLen, q.maxLen)
                if deterministic {
                    detUnbounded += 1
                } else {
                    unbounded += 1
                    choices = Self.satMul(choices, q.choices)
                }
            } else if q.varQuant > 0 {
                if unbounded > 0 {
                    postUnboundedNonLiteral = Self.satAdd(postUnboundedNonLiteral, q.maxLen)
                    if postUnboundedNonLiteral > DanmuBlockFilter.maxPostUnboundedNonLiteral {
                        fail("正则表达式无界量词后的非字面后缀超过安全上限")
                        return nil
                    }
                }
                work = Self.satAdd(work, Self.satMul(choices, Self.satMul(q.choices, q.maxLen)))
                varQuants += 1
                choices = Self.satMul(choices, q.choices)
                maxExpandedLen = Self.satAdd(maxExpandedLen, q.maxLen)
            } else if unbounded > 0 && isUnquantifiedLiteral {
                postUnboundedLiterals += 1
                if postUnboundedLiterals > DanmuBlockFilter.maxPostUnboundedLiterals {
                    fail("正则表达式无界量词后的字面后缀超过安全上限")
                    return nil
                }
                let folded = (atom.literalCode >= 128 && !SafeRegexAtomInfo.isCaselessCjk(atom.literalCode))
                    ? 0xFFFD
                    : SafeRegexAtomInfo.foldAsciiLower(atom.literalCode)
                let sameCount = postUnboundedLitCodes.filter { $0 == folded }.count + 1
                if sameCount > DanmuBlockFilter.maxPostUnboundedSameChar {
                    fail("正则表达式无界量词后的重复字符后缀超过安全上限")
                    return nil
                }
                postUnboundedLitCodes.append(folded)
                work = Self.satAdd(work, (choices + 3) / 4)
                maxExpandedLen = Self.satAdd(maxExpandedLen, 1)
            } else {
                if unbounded > 0 {
                    postUnboundedNonLiteral = Self.satAdd(postUnboundedNonLiteral, q.maxLen)
                    if postUnboundedNonLiteral > DanmuBlockFilter.maxPostUnboundedNonLiteral {
                        fail("正则表达式无界量词后的非字面后缀超过安全上限")
                        return nil
                    }
                }
                work = Self.satAdd(work, Self.satMul(choices, q.maxLen))
                maxExpandedLen = Self.satAdd(maxExpandedLen, q.maxLen)
            }

            if !checkBranchBudget(
                unbounded: unbounded,
                detUnbounded: detUnbounded,
                totalUnbounded: totalUnbounded,
                varQuants: varQuants,
                altGroups: altGroups,
                choices: choices,
                maxExpandedLen: maxExpandedLen,
                work: work
            ) {
                return nil
            }
        }

        if atomCount == 0 {
            fail("正则表达式禁止空分支或空分组")
            return nil
        }
        return SafeRegexBranchStats(
            unboundedQuants: unbounded,
            detUnboundedQuants: detUnbounded,
            totalUnboundedQuants: totalUnbounded,
            varQuants: varQuants,
            altGroups: altGroups,
            choices: choices,
            maxExpandedLen: maxExpandedLen,
            work: work
        )
    }

    private func checkBranchBudget(
        unbounded: Int,
        detUnbounded: Int,
        totalUnbounded: Int,
        varQuants: Int,
        altGroups: Int,
        choices: Int,
        maxExpandedLen: Int,
        work: Int
    ) -> Bool {
        if unbounded > DanmuBlockFilter.maxUnboundedPerBranch
            || detUnbounded > DanmuBlockFilter.maxDetUnboundedPerBranch
        {
            fail("禁止同分支内组合多个无界量词以防回溯风险")
            return false
        }
        if totalUnbounded > DanmuBlockFilter.maxTotalUnbounded {
            fail("正则表达式无界量词总数超过安全上限")
            return false
        }
        if varQuants > DanmuBlockFilter.maxVarQuantsPerBranch {
            fail("禁止同分支内组合过多可变长量词以防回溯风险")
            return false
        }
        if altGroups > DanmuBlockFilter.maxAltGroupsPerBranch {
            fail("禁止同分支内串联过多交替分组以防回溯风险")
            return false
        }
        let lenLimit = (varQuants > 0 || altGroups > 0)
            ? DanmuBlockFilter.maxBranchExpandedLen
            : DanmuBlockFilter.maxRegexLength
        if maxExpandedLen > lenLimit {
            fail("正则表达式分支展开长度超过安全上限")
            return false
        }
        let choiceLimit = unbounded == 0
            ? DanmuBlockFilter.maxBoundedBranchChoices
            : DanmuBlockFilter.maxBranchChoices
        if choices > choiceLimit {
            fail("正则表达式回溯复杂度过高")
            return false
        }
        let workLimit = totalUnbounded > 0
            ? DanmuBlockFilter.maxBranchWork
            : (choices == 1 ? DanmuBlockFilter.maxRegexLength : DanmuBlockFilter.maxBoundedBranchWork)
        if work > workLimit {
            fail("正则表达式回溯工作量超过安全上限")
            return false
        }
        return true
    }

    private func parseQuantifier(isDot: Bool) -> SafeRegexQuantStats? {
        guard pos < units.count else { return .none }
        let q = unit(at: pos)
        if q == 0x2A || q == 0x2B {
            pos += 1
            if isDot {
                wildcardCount += 1
                if wildcardCount > DanmuBlockFilter.maxWildcards {
                    fail("通配符 .* / .+ 超过 3 次上限")
                    return nil
                }
            }
            var lazy = false
            if pos < units.count && unit(at: pos) == 0x3F {
                pos += 1
                lazy = true
            }
            if pos < units.count && Self.isQuantStart(unit(at: pos)) {
                fail("禁止堆叠或占有型量词")
                return nil
            }
            return SafeRegexQuantStats(unbounded: 1, varQuant: 1, choices: Self.unboundedChoiceCost, maxLen: 1, lazy: lazy)
        }
        if q == 0x3F {
            pos += 1
            if pos < units.count && Self.isQuantStart(unit(at: pos)) {
                fail("禁止堆叠或占有型量词")
                return nil
            }
            return SafeRegexQuantStats(unbounded: 0, varQuant: 1, choices: 2, maxLen: 1, lazy: false)
        }
        if q == 0x7B {
            pos += 1
            let minVal = parseBoundedInt()
            if errorMessage != nil { return nil }
            guard pos < units.count else {
                fail("正则表达式量词花括号未闭合")
                return nil
            }
            let sep = unit(at: pos)
            if sep == 0x7D {
                pos += 1
                if minVal == 0 {
                    fail("禁止使用零次量词")
                    return nil
                }
                if pos < units.count && Self.isQuantStart(unit(at: pos)) {
                    fail("禁止堆叠或占有型量词")
                    return nil
                }
                return SafeRegexQuantStats(unbounded: 0, varQuant: 0, choices: 1, maxLen: minVal, lazy: false)
            }
            if sep == 0x2C {
                pos += 1
                if pos < units.count && unit(at: pos) == 0x7D {
                    pos += 1
                    if isDot {
                        wildcardCount += 1
                        if wildcardCount > DanmuBlockFilter.maxWildcards {
                            fail("通配符 .* / .+ 超过 3 次上限")
                            return nil
                        }
                    }
                    var lazy = false
                    if pos < units.count && unit(at: pos) == 0x3F {
                        pos += 1
                        lazy = true
                    }
                    if pos < units.count && Self.isQuantStart(unit(at: pos)) {
                        fail("禁止堆叠或占有型量词")
                        return nil
                    }
                    return SafeRegexQuantStats(
                        unbounded: 1,
                        varQuant: 1,
                        choices: Self.unboundedChoiceCost,
                        maxLen: max(1, minVal),
                        lazy: lazy
                    )
                }
                let maxVal = parseBoundedInt()
                if errorMessage != nil { return nil }
                guard pos < units.count && unit(at: pos) == 0x7D else {
                    fail("正则表达式量词花括号格式无效")
                    return nil
                }
                pos += 1
                if maxVal < minVal {
                    fail("正则表达式量词上限小于下限")
                    return nil
                }
                if maxVal == 0 {
                    fail("禁止使用零次量词")
                    return nil
                }
                if maxVal == minVal {
                    if pos < units.count && Self.isQuantStart(unit(at: pos)) {
                        fail("禁止堆叠或占有型量词")
                        return nil
                    }
                    return SafeRegexQuantStats(unbounded: 0, varQuant: 0, choices: 1, maxLen: maxVal, lazy: false)
                }
                var lazy = false
                if pos < units.count && unit(at: pos) == 0x3F {
                    pos += 1
                    lazy = true
                }
                if pos < units.count && Self.isQuantStart(unit(at: pos)) {
                    fail("禁止堆叠或占有型量词")
                    return nil
                }
                return SafeRegexQuantStats(unbounded: 0, varQuant: 1, choices: maxVal - minVal + 1, maxLen: maxVal, lazy: lazy)
            }
            fail("正则表达式量词花括号格式无效")
            return nil
        }
        return .none
    }

    private func parseBoundedInt() -> Int {
        let start = pos
        var val = 0
        while pos < units.count {
            let d = unit(at: pos)
            if d < 0x30 || d > 0x39 { break }
            val = val * 10 + (d - 0x30)
            if val > DanmuBlockFilter.maxQuantifierBound {
                fail("正则表达式量词数值超过 20 上限")
                return -1
            }
            pos += 1
        }
        if pos == start {
            fail("正则表达式量词花括号缺少数字")
            return -1
        }
        return val
    }

    private func parseOutsideEscape() -> SafeRegexAtomInfo? {
        pos += 1
        guard pos < units.count else {
            fail("正则表达式以未闭合转义符结尾")
            return nil
        }
        let next = unit(at: pos)
        if (next >= 0x31 && next <= 0x39) || next == 0x6B {
            fail("禁止使用正则反向引用")
            return nil
        }
        switch next {
        case 0x62, 0x42: pos += 1; return nil
        case 0x64: pos += 1; return .digit
        case 0x73: pos += 1; return .space
        case 0x77: pos += 1; return .word
        case 0x44, 0x57, 0x53: pos += 1; return .other
        case 0x74: pos += 1; return .literal(0x09)
        case 0x6E: pos += 1; return .literal(0x0A)
        case 0x72: pos += 1; return .literal(0x0D)
        case 0x66: pos += 1; return .literal(0x0C)
        case 0x78:
            pos += 1
            let code = parseFixedHexEscape(digits: 2)
            return errorMessage == nil ? .literal(code) : nil
        case 0x75:
            pos += 1
            let code = parseFixedHexEscape(digits: 4)
            return errorMessage == nil ? .literal(code) : nil
        default:
            if Self.isAsciiPunctuation(next) {
                pos += 1
                return .literal(next)
            }
            fail("禁止使用不受支持的正则转义序列")
            return nil
        }
    }

    private func parseFixedHexEscape(digits: Int) -> Int {
        guard pos + digits <= units.count else {
            fail("正则十六进制转义位数不足")
            return -1
        }
        var value = 0
        for i in 0..<digits {
            let h = unit(at: pos + i)
            guard Self.isHexDigit(h) else {
                fail("正则十六进制转义格式无效")
                return -1
            }
            let nibble = h <= 0x39 ? (h - 0x30) : (h <= 0x46 ? (h - 0x41 + 10) : (h - 0x61 + 10))
            value = (value << 4) | nibble
        }
        pos += digits
        if digits == 4 && Self.isSurrogateCodeUnit(value) {
            fail("正则表达式不支持代理项或扩展平面字符")
            return -1
        }
        return value
    }

    private static func setAsciiMaskBit(_ mask: inout [UInt32], code: Int) {
        if code >= 0 && code < 128 {
            mask[code >> 5] |= UInt32(1) << (code & 31)
            let folded = SafeRegexAtomInfo.foldAsciiLower(code)
            mask[folded >> 5] |= UInt32(1) << (folded & 31)
        }
    }

    private func parseCharClass() -> SafeRegexAtomInfo? {
        pos += 1
        var negated = false
        if pos < units.count && unit(at: pos) == 0x5E {
            pos += 1
            negated = true
        }
        var itemCount = 0
        var prevWasSingleChar = false
        var prevCharCode = -1
        var pendingRange = false
        var trackAsciiMask = !negated
        var asciiMask: [UInt32] = [0, 0, 0, 0]

        while pos < units.count && unit(at: pos) != 0x5D {
            let c = unit(at: pos)
            if c == 0x5B {
                fail("禁止在字符类中使用未转义的 [")
                return nil
            }
            if c == 0x26 && pos + 1 < units.count && unit(at: pos + 1) == 0x26 {
                fail("禁止在字符类中使用交集语法")
                return nil
            }
            if c == 0x2D && !pendingRange && itemCount > 0 && pos + 1 < units.count && unit(at: pos + 1) != 0x5D {
                if !prevWasSingleChar {
                    fail("字符类范围不能以简写字符类作为起点")
                    return nil
                }
                pos += 1
                pendingRange = true
                continue
            }

            let isSingleChar: Bool
            let charCode: Int
            if c == 0x5C {
                pos += 1
                guard pos < units.count else {
                    fail("正则表达式以未闭合转义符结尾")
                    return nil
                }
                let next = unit(at: pos)
                switch next {
                case 0x64, 0x44, 0x77, 0x57, 0x73, 0x53:
                    pos += 1
                    isSingleChar = false
                    charCode = -1
                    trackAsciiMask = false
                case 0x74: pos += 1; isSingleChar = true; charCode = 0x09
                case 0x6E: pos += 1; isSingleChar = true; charCode = 0x0A
                case 0x72: pos += 1; isSingleChar = true; charCode = 0x0D
                case 0x66: pos += 1; isSingleChar = true; charCode = 0x0C
                case 0x78:
                    pos += 1
                    charCode = parseFixedHexEscape(digits: 2)
                    if errorMessage != nil { return nil }
                    isSingleChar = true
                case 0x75:
                    pos += 1
                    charCode = parseFixedHexEscape(digits: 4)
                    if errorMessage != nil { return nil }
                    isSingleChar = true
                default:
                    if Self.isAsciiPunctuation(next) {
                        pos += 1
                        isSingleChar = true
                        charCode = next
                    } else {
                        fail("禁止在字符类中使用不受支持的转义序列")
                        return nil
                    }
                }
            } else {
                pos += 1
                isSingleChar = true
                charCode = c
            }

            if pendingRange {
                if !isSingleChar {
                    fail("字符类范围不能以简写字符类作为终点")
                    return nil
                }
                if charCode < prevCharCode {
                    fail("字符类范围起点大于终点")
                    return nil
                }
                if trackAsciiMask {
                    if prevCharCode >= 0 && charCode < 128 {
                        for k in prevCharCode...charCode {
                            Self.setAsciiMaskBit(&asciiMask, code: k)
                        }
                    } else {
                        trackAsciiMask = false
                    }
                }
                pendingRange = false
                prevWasSingleChar = false
            } else {
                if trackAsciiMask && isSingleChar {
                    if charCode >= 0 && charCode < 128 {
                        Self.setAsciiMaskBit(&asciiMask, code: charCode)
                    } else {
                        trackAsciiMask = false
                    }
                }
                prevWasSingleChar = isSingleChar
                prevCharCode = charCode
            }
            itemCount += 1
        }

        guard pos < units.count && unit(at: pos) == 0x5D else {
            fail("字符类未闭合")
            return nil
        }
        pos += 1
        if itemCount == 0 {
            fail("字符类不能为空")
            return nil
        }
        return trackAsciiMask ? .asciiClass(asciiMask) : .other
    }
}

/// Block filter supporting plain substring rules (case-insensitive) and static-ReDoS-validated
/// `re:<pattern>` (and legacy `/<pattern>/`) rules.
public struct DanmuBlockFilter: Sendable {
    public static let maxRules = 100
    public static let maxRegexLength = 120
    public static let maxWildcards = 3
    public static let maxGroupDepth = 6
    public static let maxQuantifierBound = 20
    public static let maxUnboundedPerBranch = 1
    public static let maxDetUnboundedPerBranch = 1
    public static let maxTotalUnbounded = 2
    public static let maxVarQuantsPerBranch = 2
    public static let maxAltGroupsPerBranch = 2
    public static let maxBranchExpandedLen = 28
    public static let maxPostUnboundedLiterals = 10
    public static let maxPostUnboundedSameChar = 4
    public static let maxPostUnboundedNonLiteral = 2
    public static let maxBoundedBranchChoices = 16
    public static let maxBranchChoices = 550
    public static let maxTotalChoices = 600
    public static let maxBoundedBranchWork = 100
    public static let maxTotalBoundedWork = 160
    public static let maxBranchWork = 620
    public static let maxTotalWork = 900

    public static let empty = DanmuBlockFilter(rules: [])

    private let substrings: [String]
    private let regexes: [NSRegularExpression]

    public var isEmpty: Bool {
        substrings.isEmpty && regexes.isEmpty
    }

    public var ruleCount: Int {
        substrings.count + regexes.count
    }

    public static func validateRule(_ rawRule: String) -> DanmuRuleValidationResult {
        let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .fail("屏蔽规则不能为空")
        }
        let expr: String
        if trimmed.hasPrefix("re:") {
            expr = String(trimmed.dropFirst(3))
        } else if trimmed.hasPrefix("/") && trimmed.hasSuffix("/") && trimmed.count >= 3 {
            expr = String(trimmed.dropFirst().dropLast())
        } else {
            return .ok
        }

        if expr.isEmpty {
            return .fail("正则表达式不能为空")
        }
        if expr.utf16.count > maxRegexLength {
            return .fail("正则表达式长度超过 120 字符上限")
        }
        let staticCheck = SafeRegexValidator(expr).validate()
        if !staticCheck.valid {
            return staticCheck
        }
        do {
            _ = try NSRegularExpression(pattern: expr, options: [.caseInsensitive])
        } catch {
            return .fail("正则表达式语法错误: \(error.localizedDescription)")
        }
        return .ok
    }

    public static func compile(_ rules: [String]) -> DanmuBlockFilter {
        DanmuBlockFilter(rules: rules)
    }

    public init(rules: [String]) {
        var subs: [String] = []
        var res: [NSRegularExpression] = []
        var accepted = 0
        for raw in rules {
            if accepted >= Self.maxRules { break }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let validation = Self.validateRule(trimmed)
            guard validation.valid else { continue }

            if trimmed.hasPrefix("re:") {
                let pattern = String(trimmed.dropFirst(3))
                if let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    res.append(compiled)
                    accepted += 1
                }
            } else if trimmed.hasPrefix("/") && trimmed.hasSuffix("/") && trimmed.count >= 3 {
                let pattern = String(trimmed.dropFirst().dropLast())
                if let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    res.append(compiled)
                    accepted += 1
                }
            } else {
                subs.append(trimmed.lowercased())
                accepted += 1
            }
        }
        self.substrings = subs
        self.regexes = res
    }

    public func shouldBlock(_ text: String) -> Bool {
        guard !text.isEmpty, !isEmpty else { return false }
        if !substrings.isEmpty {
            let lower = text.lowercased()
            for sub in substrings where lower.contains(sub) { return true }
        }
        let range = NSRange(text.startIndex..., in: text)
        for re in regexes where re.firstMatch(in: text, range: range) != nil { return true }
        return false
    }

    public func isBlocked(_ text: String) -> Bool {
        shouldBlock(text)
    }
}

// MARK: - Windowed 30s Danmaku Segment Cache

/// Windowed 30-second danmaku cache with 12s visibility lifetime, 3-window LRU pinning (`{w-1, w, w+1}`),
/// hard caps (24 windows / 18,000 items), signed effective-clock snapshots, and `bindPreloadedItems`.
public final class DanmuSegmentCache: @unchecked Sendable {
    public static let windowDurationMs = 30_000
    public static let maxCommentLifetimeMs = 12_000
    public static let prefetchOffsetMs = 18_000
    public static let maxCachedWindows = 24
    public static let maxWindowItems = 1_500
    public static let maxTotalItems = 18_000

    private let lock = NSLock()
    private var windows: [Int: [DanmuComment]] = [:]
    private var lruOrder: [Int] = []
    private var totalItems: Int = 0
    private var currentPinnedWindow: Int = 0
    private var timeOffsetMsValue: Int = 0
    private var blockFilter: DanmuBlockFilter = .empty
    private var activeSessionId: String = ""
    private var preloadedSorted: [DanmuComment] = []

    public init() {}

    public static func computeEffectiveMs(rawPositionMs: Int, timeOffsetMs: Int) -> Int {
        rawPositionMs + timeOffsetMs
    }

    public static func computeWindowIndex(effectiveMs: Int) -> Int {
        effectiveMs < 0 ? 0 : (effectiveMs / windowDurationMs)
    }

    public var cachedWindowCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return windows.count
    }

    public var totalCachedItemCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalItems
    }

    public var timeOffsetMs: Int {
        lock.lock()
        defer { lock.unlock() }
        return timeOffsetMsValue
    }

    public var sessionId: String {
        lock.lock()
        defer { lock.unlock() }
        return activeSessionId
    }

    public func isWindowCached(_ windowIndex: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return windows[windowIndex] != nil
    }

    public func setBlockFilter(_ filter: DanmuBlockFilter) {
        lock.lock()
        blockFilter = filter
        lock.unlock()
    }

    public func setTimeOffsetMs(_ offsetMs: Int) {
        lock.lock()
        timeOffsetMsValue = min(max(offsetMs, -30_000), 30_000)
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        windows.removeAll()
        lruOrder.removeAll()
        totalItems = 0
        currentPinnedWindow = 0
        activeSessionId = ""
        preloadedSorted.removeAll()
        lock.unlock()
    }

    /// Binds preloaded comments (e.g. from full-episode JSON/XML fetch or AI online matcher),
    /// deduplicating, sorting, capping at `maxTotalItems`, and populating the initial window.
    public func bindPreloadedItems(
        _ items: [DanmuComment],
        sessionId: String,
        initialPositionMs: Int = 0
    ) {
        let sortedInput = items.sorted { lhs, rhs in
            if lhs.timeMs != rhs.timeMs { return lhs.timeMs < rhs.timeMs }
            return lhs.id < rhs.id
        }
        var seen = Set<String>()
        var normalized: [DanmuComment] = []
        normalized.reserveCapacity(min(sortedInput.count, Self.maxTotalItems))
        for item in sortedInput {
            let trimmedText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.timeMs >= 0, !trimmedText.isEmpty, seen.insert(item.id).inserted else { continue }
            normalized.append(item)
            if normalized.count >= Self.maxTotalItems { break }
        }

        lock.lock()
        windows.removeAll()
        lruOrder.removeAll()
        totalItems = 0
        activeSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "preloaded_danmu"
            : sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        preloadedSorted = normalized
        let effectiveMs = Self.computeEffectiveMs(rawPositionMs: initialPositionMs, timeOffsetMs: timeOffsetMsValue)
        let w = Self.computeWindowIndex(effectiveMs: effectiveMs)
        currentPinnedWindow = w
        if !normalized.isEmpty {
            let slice = Self.slicePreloadedWindow(normalized, windowIndex: w)
            putWindowLocked(w, items: slice)
        }
        lock.unlock()
    }

    public func putWindow(_ windowIndex: Int, items: [DanmuComment]) {
        guard windowIndex >= 0 else { return }
        let capped = Array(
            items
                .sorted { lhs, rhs in
                    if lhs.timeMs != rhs.timeMs { return lhs.timeMs < rhs.timeMs }
                    return lhs.id < rhs.id
                }
                .prefix(Self.maxWindowItems)
        )
        lock.lock()
        putWindowLocked(windowIndex, items: capped)
        lock.unlock()
    }

    /// Returns visible comments at `rawPositionMs` within `[effectiveMs - 12000, effectiveMs]`,
    /// applying active `DanmuBlockFilter` and pinning `{w - 1, w, w + 1}` in LRU.
    public func comments(atMs rawPositionMs: Int) -> [DanmuComment] {
        lock.lock()
        defer { lock.unlock() }
        let effectiveMs = Self.computeEffectiveMs(rawPositionMs: rawPositionMs, timeOffsetMs: timeOffsetMsValue)
        guard effectiveMs >= 0 else { return [] }

        let w = effectiveMs / Self.windowDurationMs
        currentPinnedWindow = w

        if !preloadedSorted.isEmpty {
            if windows[w] == nil {
                putWindowLocked(w, items: Self.slicePreloadedWindow(preloadedSorted, windowIndex: w))
            }
            if w > 0 && windows[w - 1] == nil {
                putWindowLocked(w - 1, items: Self.slicePreloadedWindow(preloadedSorted, windowIndex: w - 1))
            }
        }

        let prevItems = w > 0 ? touchWindowLocked(w - 1) : nil
        let currItems = touchWindowLocked(w)
        let minTimeMs = effectiveMs - Self.maxCommentLifetimeMs

        var seen = Set<String>()
        var out: [DanmuComment] = []
        let filter = blockFilter

        func collect(_ source: [DanmuComment]?) {
            guard let source = source, !source.isEmpty else { return }
            for item in source {
                if item.timeMs < minTimeMs { continue }
                if item.timeMs > effectiveMs { break }
                if !filter.isEmpty && filter.shouldBlock(item.text) { continue }
                if seen.insert(item.id).inserted {
                    out.append(item)
                }
            }
        }

        collect(prevItems)
        collect(currItems)
        out.sort { lhs, rhs in
            if lhs.timeMs != rhs.timeMs { return lhs.timeMs < rhs.timeMs }
            return lhs.id < rhs.id
        }
        return out
    }

    private func touchWindowLocked(_ windowIndex: Int) -> [DanmuComment]? {
        guard let existing = windows[windowIndex] else { return nil }
        if let idx = lruOrder.firstIndex(of: windowIndex) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(windowIndex)
        return existing
    }

    private func putWindowLocked(_ windowIndex: Int, items: [DanmuComment]) {
        if let old = windows[windowIndex] {
            totalItems = max(0, totalItems - old.count)
        }
        windows[windowIndex] = items
        totalItems += items.count
        if let idx = lruOrder.firstIndex(of: windowIndex) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(windowIndex)
        evictIfNeededLocked()
    }

    private func evictIfNeededLocked() {
        let pinned: Set<Int> = [
            max(0, currentPinnedWindow - 1),
            currentPinnedWindow,
            currentPinnedWindow + 1,
        ]
        var idx = 0
        while (windows.count > Self.maxCachedWindows || totalItems > Self.maxTotalItems) && idx < lruOrder.count {
            let candidate = lruOrder[idx]
            if pinned.contains(candidate) {
                idx += 1
                continue
            }
            lruOrder.remove(at: idx)
            if let removed = windows.removeValue(forKey: candidate) {
                totalItems = max(0, totalItems - removed.count)
            }
        }
    }

    private static func slicePreloadedWindow(_ sorted: [DanmuComment], windowIndex: Int) -> [DanmuComment] {
        guard !sorted.isEmpty, windowIndex >= 0 else { return [] }
        let startMs = windowIndex * windowDurationMs
        let endMs = startMs + windowDurationMs
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].timeMs < startMs {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var out: [DanmuComment] = []
        var i = lo
        while i < sorted.count && out.count < maxWindowItems {
            let item = sorted[i]
            if item.timeMs >= endMs { break }
            if item.timeMs >= startMs {
                out.append(item)
            }
            i += 1
        }
        return out
    }
}

// MARK: - 3-Way Danmaku Source Sync Merger

public struct DanmuSourceSyncMergeResult: Equatable, Sendable {
    public let merged: DanmuSourceSyncDocument
    public let localChanged: Bool
    public let needsUpload: Bool
    public let pendingAuthOrigins: [String]

    public init(
        merged: DanmuSourceSyncDocument,
        localChanged: Bool,
        needsUpload: Bool,
        pendingAuthOrigins: [String]
    ) {
        self.merged = merged
        self.localChanged = localChanged
        self.needsUpload = needsUpload
        self.pendingAuthOrigins = pendingAuthOrigins
    }
}

/// Deterministic 3-way merger for `.danmu.json` WebDAV sidecars with explicit
/// `authorizedCredentialOrigins` protection so cloud-synced origins never receive
/// local `appId`/`appSecret` without explicit user authorization.
public enum DanmuSourceSyncMerger {
    public static func merge(
        local: DanmuSourceSyncDocument,
        base: DanmuSourceSyncDocument?,
        remote: DanmuSourceSyncDocument?,
        hasLocalCredentials: Bool,
        authorizedCredentialOrigins: Set<String>? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> DanmuSourceSyncMergeResult {
        let normalizedAuth: Set<String>? = authorizedCredentialOrigins.map { rawSet in
            Set(rawSet.compactMap { DanmuService.normalizeOrigin($0) })
        }

        func pendingAuth(for doc: DanmuSourceSyncDocument, remoteAddedUrls: Set<String> = []) -> [String] {
            var out: [String] = []
            var seen = Set<String>()
            for entry in doc.sources {
                guard let norm = DanmuService.normalizeOrigin(entry.url) else { continue }
                let needsApproval: Bool
                if let authSet = normalizedAuth {
                    needsApproval = (entry.requiresAuth || remoteAddedUrls.contains(norm)) && !authSet.contains(norm)
                } else {
                    needsApproval = (entry.requiresAuth && !hasLocalCredentials) || remoteAddedUrls.contains(norm)
                }
                if needsApproval && seen.insert(norm).inserted {
                    out.append(norm)
                }
            }
            return out
        }

        // Case 1: Remote sidecar absent (404)
        guard let remote = remote else {
            if local.isFreshUninitialized {
                return DanmuSourceSyncMergeResult(
                    merged: local,
                    localChanged: false,
                    needsUpload: false,
                    pendingAuthOrigins: []
                )
            }
            var next = local
            next.initialized = true
            next.updatedAt = local.updatedAt > 0 ? local.updatedAt : nowMs
            next.revision = max(1, local.revision)
            return DanmuSourceSyncMergeResult(
                merged: next,
                localChanged: false,
                needsUpload: true,
                pendingAuthOrigins: pendingAuth(for: next)
            )
        }

        // Case 2: Local is a fresh uninitialized device -> restore remote
        if local.isFreshUninitialized {
            var restored = remote
            restored.initialized = true
            let remoteSet = Set(restored.sources.compactMap { DanmuService.normalizeOrigin($0.url) })
            return DanmuSourceSyncMergeResult(
                merged: restored,
                localChanged: !restored.sources.isEmpty,
                needsUpload: false,
                pendingAuthOrigins: pendingAuth(for: restored, remoteAddedUrls: remoteSet)
            )
        }

        // Defense-in-depth: empty remote without explicit clearedAt must never wipe local sources
        if remote.sources.isEmpty && remote.clearedAt <= 0 && !local.sources.isEmpty {
            var preserved = local
            preserved.initialized = true
            return DanmuSourceSyncMergeResult(
                merged: preserved,
                localChanged: false,
                needsUpload: false,
                pendingAuthOrigins: pendingAuth(for: preserved)
            )
        }

        // Case 3: Identical sources & clearedAt
        if local.sources == remote.sources && local.clearedAt == remote.clearedAt {
            var converged = local
            converged.initialized = true
            converged.updatedAt = max(local.updatedAt, remote.updatedAt)
            converged.revision = max(local.revision, remote.revision)
            return DanmuSourceSyncMergeResult(
                merged: converged,
                localChanged: false,
                needsUpload: false,
                pendingAuthOrigins: pendingAuth(for: converged)
            )
        }

        // Case 4 / 5: Fast-forward when one side matches base
        let localUnchanged = base != nil && local.sources == base!.sources && local.clearedAt == base!.clearedAt
        let remoteUnchanged = base != nil && remote.sources == base!.sources && remote.clearedAt == base!.clearedAt
        if localUnchanged && !remoteUnchanged {
            var applied = remote
            applied.initialized = true
            let localUrls = Set(local.sources.compactMap { DanmuService.normalizeOrigin($0.url) })
            let addedFromRemote = Set(applied.sources.compactMap { DanmuService.normalizeOrigin($0.url) })
                .subtracting(localUrls)
            return DanmuSourceSyncMergeResult(
                merged: applied,
                localChanged: local.sources != applied.sources || local.clearedAt != applied.clearedAt,
                needsUpload: false,
                pendingAuthOrigins: pendingAuth(for: applied, remoteAddedUrls: addedFromRemote)
            )
        }
        if remoteUnchanged && !localUnchanged {
            var pushed = local
            pushed.initialized = true
            pushed.updatedAt = max(nowMs, max(local.updatedAt, remote.updatedAt) + 1)
            pushed.revision = max(local.revision, remote.revision) + 1
            return DanmuSourceSyncMergeResult(
                merged: pushed,
                localChanged: false,
                needsUpload: true,
                pendingAuthOrigins: pendingAuth(for: pushed)
            )
        }

        // Case 6: Concurrent edits (or no common base)
        if local.sources.isEmpty && local.clearedAt > 0 && local.clearedAt > remote.updatedAt {
            var pushed = local
            pushed.initialized = true
            pushed.updatedAt = max(nowMs, max(local.updatedAt, remote.updatedAt) + 1)
            pushed.revision = max(local.revision, remote.revision) + 1
            return DanmuSourceSyncMergeResult(
                merged: pushed,
                localChanged: false,
                needsUpload: true,
                pendingAuthOrigins: []
            )
        }
        if remote.sources.isEmpty && remote.clearedAt > 0 && remote.clearedAt > local.updatedAt {
            var applied = remote
            applied.initialized = true
            return DanmuSourceSyncMergeResult(
                merged: applied,
                localChanged: !local.sources.isEmpty,
                needsUpload: false,
                pendingAuthOrigins: []
            )
        }

        // 3-way union preserving deletions relative to base
        let baseUrls = Set((base?.sources ?? []).compactMap { DanmuService.normalizeOrigin($0.url) })
        let localUrls = Set(local.sources.compactMap { DanmuService.normalizeOrigin($0.url) })
        let remoteUrls = Set(remote.sources.compactMap { DanmuService.normalizeOrigin($0.url) })
        let deletedLocally = baseUrls.subtracting(localUrls)
        let deletedRemotely = baseUrls.subtracting(remoteUrls)
        let addedLocally = localUrls.subtracting(baseUrls)
        let addedRemotely = remoteUrls.subtracting(baseUrls)

        var mergedEntries: [DanmuSourceEntry] = []
        var seen = Set<String>()
        let orderedInput = local.updatedAt >= remote.updatedAt
            ? (local.sources + remote.sources)
            : (remote.sources + local.sources)
        for rawEntry in orderedInput {
            guard mergedEntries.count < DanmuService.maxServers,
                  let norm = DanmuService.normalizeOrigin(rawEntry.url)
            else { continue }
            if deletedLocally.contains(norm) && !addedRemotely.contains(norm) { continue }
            if deletedRemotely.contains(norm) && !addedLocally.contains(norm) { continue }
            if seen.insert(norm).inserted {
                let requiresAuth = local.sources.first(where: { DanmuService.normalizeOrigin($0.url) == norm })?.requiresAuth == true
                    || remote.sources.first(where: { DanmuService.normalizeOrigin($0.url) == norm })?.requiresAuth == true
                mergedEntries.append(DanmuSourceEntry(url: norm, requiresAuth: requiresAuth))
            }
        }

        let nextTs = max(nowMs, max(local.updatedAt, remote.updatedAt) + 1)
        let mergedDoc = DanmuSourceSyncDocument(
            schemaVersion: DanmuSourceSyncDocument.currentSchemaVersion,
            updatedAt: nextTs,
            revision: max(local.revision, remote.revision) + 1,
            clearedAt: mergedEntries.isEmpty ? nextTs : 0,
            initialized: true,
            sources: mergedEntries
        )
        let addedFromRemote = Set(mergedEntries.map(\.url)).subtracting(localUrls)
        return DanmuSourceSyncMergeResult(
            merged: mergedDoc,
            localChanged: mergedDoc.sources != local.sources || mergedDoc.clearedAt != local.clearedAt,
            needsUpload: mergedDoc.sources != remote.sources || mergedDoc.clearedAt != remote.clearedAt,
            pendingAuthOrigins: pendingAuth(for: mergedDoc, remoteAddedUrls: addedFromRemote)
        )
    }
}

// MARK: - DandanPlay-Compatible Danmaku Service

/// Clean-room DandanPlay Open API v2 compatible segmented & full-episode danmaku service.
/// Security contracts:
/// - Default `serverUrls` is strictly `""` (zero built-in third-party endpoints).
/// - `appId`/`appSecret` signature headers are sent ONLY to explicitly authorized origins.
/// - XML parsing strictly rejects `<!DOCTYPE` and `<!ENTITY` to prevent XXE attacks.
public final class DanmuService: @unchecked Sendable {
    public static let maxServers = 8
    public static let maxPayloadBytes = 8 * 1024 * 1024
    public static let maxFullEpisodeItems = 20_000

    private static let xmlDanmuTagRegex = try! NSRegularExpression(
        pattern: #"<d\b[^>]*\bp\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</d>"#,
        options: [.caseInsensitive]
    )

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 12
            cfg.timeoutIntervalForResource = 25
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public static func normalizeOrigin(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://\(s)"
        }
        guard var comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
              let host = comps.host?.lowercased(), !host.isEmpty
        else { return nil }
        comps.scheme = scheme
        comps.host = host
        comps.user = nil
        comps.password = nil
        comps.query = nil
        comps.fragment = nil
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        return comps.string
    }

    public static func parseConfiguredOrigins(_ multiline: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for line in multiline.components(separatedBy: CharacterSet(charactersIn: "\r\n,;")) {
            guard out.count < maxServers else { break }
            if let norm = normalizeOrigin(line), seen.insert(norm).inserted {
                out.append(norm)
            }
        }
        return out
    }

    /// Strict authorization guard: cloud-synced or pending/dismissed origins NEVER receive local
    /// `appId`/`appSecret` credentials unless explicitly present in `authorizedCredentialOrigins`.
    public static func shouldSendCredentials(toOrigin rawOrigin: String, settings: DanmuSettings) -> Bool {
        guard !settings.appId.isEmpty, !settings.appSecret.isEmpty,
              let norm = normalizeOrigin(rawOrigin)
        else { return false }
        let pendingSet = Set(settings.pendingAuthOrigins.compactMap { normalizeOrigin($0) })
        if pendingSet.contains(norm) { return false }
        let dismissedSet = Set(settings.dismissedAuthOrigins.compactMap { normalizeOrigin($0) })
        if dismissedSet.contains(norm) { return false }
        let authorizedSet = Set(settings.authorizedCredentialOrigins.compactMap { normalizeOrigin($0) })
        return authorizedSet.contains(norm)
    }

    /// POST `/api/v2/match` against configured DandanPlay-compatible origins.
    public func matchEpisode(
        fileName: String,
        fileHash: String = "",
        fileSize: Int64 = 0,
        videoDuration: Int = 0,
        settings: DanmuSettings
    ) async throws -> [DanmuMatchCandidate] {
        let origins = Self.parseConfiguredOrigins(settings.serverUrls)
        guard !origins.isEmpty else { return [] }
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return [] }

        let apiPath = "/api/v2/match"
        var bodyMap: [String: Any] = [
            "fileName": trimmedName,
            "matchMode": fileHash.isEmpty ? "fileNameOnly" : "hashAndFileName",
        ]
        if !fileHash.isEmpty { bodyMap["fileHash"] = fileHash }
        if fileSize > 0 { bodyMap["fileSize"] = fileSize }
        if videoDuration > 0 { bodyMap["videoDuration"] = videoDuration }
        let payloadData = try JSONSerialization.data(withJSONObject: bodyMap)

        var candidates: [DanmuMatchCandidate] = []
        for origin in origins {
            guard let url = URL(string: "\(origin)\(apiPath)") else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = payloadData
            applySignatureIfAuthorized(request: &req, origin: origin, apiPath: apiPath, settings: settings)

            guard let (data, resp) = try? await session.marcoData(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let matches = obj["matches"] as? [[String: Any]]
            else { continue }

            let isExact = (obj["isMatched"] as? Bool) == true
            for m in matches {
                let epId = stringVal(m["episodeId"])
                guard !epId.isEmpty else { continue }
                candidates.append(
                    DanmuMatchCandidate(
                        sourceOrigin: origin,
                        animeId: stringVal(m["animeId"]),
                        animeTitle: stringVal(m["animeTitle"]),
                        episodeId: epId,
                        episodeTitle: stringVal(m["episodeTitle"]),
                        confidence: isExact ? 1.0 : 0.78
                    )
                )
            }
            if !candidates.isEmpty { break }
        }
        return candidates.sorted { $0.confidence > $1.confidence }
    }

    public func searchEpisodes(
        title: String,
        episodeIndex: Int = 0,
        settings: DanmuSettings
    ) async throws -> [DanmuMatchCandidate] {
        let origins = Self.parseConfiguredOrigins(settings.serverUrls)
        guard !origins.isEmpty else { return [] }
        let cleanTitle = EpisodeScraperService.cleanSeriesTitle(title)
        guard !cleanTitle.isEmpty else { return [] }

        var allCandidates: [DanmuMatchCandidate] = []
        for origin in origins {
            let apiPath = "/api/v2/search/episodes"
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=?#/")
            let qTitle = cleanTitle.addingPercentEncoding(withAllowedCharacters: allowed) ?? cleanTitle
            let urlStr = "\(origin)\(apiPath)?anime=\(qTitle)"
            guard let url = URL(string: urlStr) else { continue }

            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            applySignatureIfAuthorized(request: &req, origin: origin, apiPath: apiPath, settings: settings)

            guard let (data, resp) = try? await session.marcoData(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let animes = obj["animes"] as? [[String: Any]]
            else { continue }

            for anime in animes {
                let animeId = stringVal(anime["animeId"])
                let animeTitle = stringVal(anime["animeTitle"])
                let episodes = (anime["episodes"] as? [[String: Any]]) ?? []
                for (idx, ep) in episodes.enumerated() {
                    let epId = stringVal(ep["episodeId"])
                    let epTitle = stringVal(ep["episodeTitle"])
                    guard !epId.isEmpty else { continue }
                    let score: Double = (episodeIndex > 0 && idx + 1 == episodeIndex) ? 1.0 : 0.7
                    allCandidates.append(
                        DanmuMatchCandidate(
                            sourceOrigin: origin,
                            animeId: animeId,
                            animeTitle: animeTitle,
                            episodeId: epId,
                            episodeTitle: epTitle,
                            confidence: score
                        )
                    )
                }
            }
            if !allCandidates.isEmpty { break }
        }
        return allCandidates.sorted { $0.confidence > $1.confidence }
    }

    /// GET `/api/v2/bangumi/{animeId}` to list all episodes of a matched anime/series.
    public func fetchBangumiEpisodes(
        origin: String,
        animeId: String,
        settings: DanmuSettings
    ) async throws -> [DanmuMatchCandidate] {
        guard let normOrigin = Self.normalizeOrigin(origin), !animeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#&+")
        let encodedId = animeId.addingPercentEncoding(withAllowedCharacters: allowed) ?? animeId
        let apiPath = "/api/v2/bangumi/\(encodedId)"
        guard let url = URL(string: "\(normOrigin)\(apiPath)") else { return [] }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        applySignatureIfAuthorized(request: &req, origin: normOrigin, apiPath: apiPath, settings: settings)

        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("番剧分集接口返回 HTTP \(http.statusCode)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let bangumi = obj["bangumi"] as? [String: Any],
              let episodes = bangumi["episodes"] as? [[String: Any]]
        else { return [] }

        let animeTitle = stringVal(bangumi["animeTitle"])
        return episodes.compactMap { ep in
            let epId = stringVal(ep["episodeId"])
            guard !epId.isEmpty else { return nil }
            return DanmuMatchCandidate(
                sourceOrigin: normOrigin,
                animeId: animeId,
                animeTitle: animeTitle,
                episodeId: epId,
                episodeTitle: stringVal(ep["episodeTitle"]),
                confidence: 0.9
            )
        }
    }

    public func fetchComments(
        origin: String,
        episodeId: String,
        settings: DanmuSettings
    ) async throws -> [DanmuComment] {
        guard let normOrigin = Self.normalizeOrigin(origin), !episodeId.isEmpty else { return [] }
        let apiPath = "/api/v2/comment/\(episodeId)"
        guard let url = URL(string: "\(normOrigin)\(apiPath)?withRelated=true&chConvert=1") else { return [] }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("application/json, application/xml, text/xml", forHTTPHeaderField: "Accept")
        applySignatureIfAuthorized(request: &req, origin: normOrigin, apiPath: apiPath, settings: settings)

        let (data, resp) = try await session.marcoData(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MarcoError.networkFailure("弹幕接口返回 HTTP \(http.statusCode)")
        }

        // Check if response is a segmented manifest pointing to segment URLs on the same origin
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let segments = obj["segments"] as? [[String: Any]],
           !segments.isEmpty,
           obj["comments"] == nil
        {
            var merged: [DanmuComment] = []
            for seg in segments.prefix(DanmuSegmentCache.maxCachedWindows) {
                let segPath = stringVal(seg["url"])
                guard !segPath.isEmpty else { continue }
                let resolved = CmsParser.resolveUrl(base: "\(normOrigin)/", relative: segPath)
                guard let segUrl = URL(string: resolved),
                      let segOrigin = Self.normalizeOrigin(resolved),
                      segOrigin.hasPrefix(normOrigin) || segUrl.host?.lowercased() == URL(string: normOrigin)?.host?.lowercased()
                else { continue }
                var segReq = URLRequest(url: segUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
                segReq.httpMethod = "GET"
                applySignatureIfAuthorized(request: &segReq, origin: normOrigin, apiPath: segUrl.path, settings: settings)
                if let (segData, segResp) = try? await session.marcoData(for: segReq),
                   let segHttp = segResp as? HTTPURLResponse, (200...299).contains(segHttp.statusCode),
                   let segComments = try? Self.parseCommentsPayload(segData, settings: settings)
                {
                    merged.append(contentsOf: segComments)
                }
            }
            merged.sort { $0.timeMs < $1.timeMs }
            return merged
        }

        return try Self.parseCommentsPayload(data, settings: settings)
    }

    /// Preserved non-throwing JSON comment parser supporting `{p, m}` objects and tuple arrays.
    public static func parseCommentsJson(_ data: Data, settings: DanmuSettings) -> [DanmuComment] {
        (try? parseCommentsPayload(data, settings: settings)) ?? []
    }

    /// Full danmaku payload parser supporting:
    /// - DandanPlay JSON objects (`{p, m, cid}` or `{time, mode, color, text, id}`)
    /// - Tuple JSON arrays (`[timeSec, mode, color, text, id?]`)
    /// - Bilibili / DandanPlay XML (`<d p="t,mode,size,color,...">text</d>`) with strict XXE
    ///   (`<!DOCTYPE` / `<!ENTITY`) rejection.
    public static func parseCommentsPayload(
        _ data: Data,
        settings: DanmuSettings = DanmuSettings(),
        maxItems: Int = maxFullEpisodeItems
    ) throws -> [DanmuComment] {
        guard data.count <= maxPayloadBytes else {
            throw MarcoError.invalidFormat("弹幕数据超过 8 MB 大小限制")
        }
        var content = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("\u{FEFF}") {
            content = String(content.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !content.isEmpty else { return [] }

        let filter = DanmuBlockFilter(rules: settings.blockRules)
        var parsed: [DanmuComment] = []

        if content.hasPrefix("<") {
            let upper = content.uppercased()
            if upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY") {
                throw MarcoError.invalidFormat("XML 弹幕禁止包含 DOCTYPE 或 ENTITY 声明")
            }
            let range = NSRange(content.startIndex..., in: content)
            for match in xmlDanmuTagRegex.matches(in: content, range: range) {
                if parsed.count >= maxItems { break }
                guard let pRange = Range(match.range(at: 1), in: content),
                      let textRange = Range(match.range(at: 2), in: content)
                else { continue }
                let pParts = String(content[pRange]).components(separatedBy: ",")
                guard pParts.count >= 4,
                      let timeSec = Double(pParts[0].trimmingCharacters(in: .whitespaces)),
                      let modeRaw = Int(pParts[1].trimmingCharacters(in: .whitespaces)),
                      let colorRaw = UInt32(pParts[3].trimmingCharacters(in: .whitespaces))
                else { continue }
                let text = unescapeXml(String(content[textRange])).trimmingCharacters(in: .whitespacesAndNewlines)
                let cid = pParts.count >= 8 ? pParts[7].trimmingCharacters(in: .whitespaces) : ""
                appendIfAllowed(
                    to: &parsed,
                    id: cid,
                    timeSec: timeSec,
                    modeCode: modeRaw,
                    colorRgb: colorRaw,
                    text: text,
                    settings: settings,
                    filter: filter
                )
            }
        } else {
            let jsonObj = try JSONSerialization.jsonObject(with: Data(content.utf8))
            let rawList: [Any]? = extractJsonCommentList(from: jsonObj)
            guard let list = rawList else { return [] }
            parsed.reserveCapacity(min(list.count, maxItems))

            for entry in list {
                if parsed.count >= maxItems { break }
                if let tuple = entry as? [Any], tuple.count >= 4 {
                    guard let timeSec = doubleValue(tuple[0]) else { continue }
                    let modeRaw = intValue(tuple[1]) ?? 1
                    let colorRaw = UInt32(max(0, intValue(tuple[2]) ?? 0xFFFFFF))
                    let text = stringValueStatic(tuple[3])
                    let cid = tuple.count > 4 ? stringValueStatic(tuple[4]) : ""
                    appendIfAllowed(
                        to: &parsed,
                        id: cid,
                        timeSec: timeSec,
                        modeCode: modeRaw,
                        colorRgb: colorRaw,
                        text: text,
                        settings: settings,
                        filter: filter
                    )
                } else if let dict = entry as? [String: Any] {
                    let text = stringValueStatic(dict["m"] ?? dict["text"] ?? dict["content"])
                    var timeSec = doubleValue(dict["time"] ?? dict["t"]) ?? -1.0
                    if let tMs = intValue(dict["timeMs"]) {
                        timeSec = Double(tMs) / 1000.0
                    }
                    var modeRaw = intValue(dict["mode"]) ?? 1
                    var colorRaw = UInt32(max(0, intValue(dict["color"] ?? dict["rgbColor"]) ?? 0xFFFFFF))
                    if let pField = dict["p"] as? String {
                        let parts = pField.components(separatedBy: ",")
                        if let t = Double(parts.first?.trimmingCharacters(in: .whitespaces) ?? "") {
                            timeSec = t
                        }
                        if parts.count > 1, let m = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                            modeRaw = m
                        }
                        if parts.count > 2, let c = UInt32(parts[2].trimmingCharacters(in: .whitespaces)) {
                            colorRaw = c
                        }
                    }
                    guard timeSec >= 0 else { continue }
                    let cid = stringValueStatic(dict["cid"] ?? dict["id"])
                    appendIfAllowed(
                        to: &parsed,
                        id: cid,
                        timeSec: timeSec,
                        modeCode: modeRaw,
                        colorRgb: colorRaw,
                        text: text,
                        settings: settings,
                        filter: filter
                    )
                }
            }
        }

        parsed.sort { lhs, rhs in
            if lhs.timeMs != rhs.timeMs { return lhs.timeMs < rhs.timeMs }
            return lhs.id < rhs.id
        }
        return parsed
    }

    // MARK: - Private Helpers

    private static func extractJsonCommentList(from root: Any) -> [Any]? {
        if let arr = root as? [Any] { return arr }
        guard let map = root as? [String: Any] else { return nil }
        for key in ["comments", "danmuku", "danmaku", "danmu", "data", "list"] {
            if let arr = map[key] as? [Any] { return arr }
        }
        if let inner = map["data"] as? [String: Any] {
            for key in ["comments", "danmuku", "danmaku", "danmu", "list"] {
                if let arr = inner[key] as? [Any] { return arr }
            }
        }
        return nil
    }

    private static func appendIfAllowed(
        to list: inout [DanmuComment],
        id: String,
        timeSec: Double,
        modeCode: Int,
        colorRgb: UInt32,
        text: String,
        settings: DanmuSettings,
        filter: DanmuBlockFilter
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !filter.shouldBlock(trimmed) else { return }
        let mode: DanmuMode
        switch modeCode {
        case 4: mode = .bottom
        case 5: mode = .top
        default: mode = .scroll
        }
        if mode == .scroll && !settings.showScroll { return }
        if mode == .top && !settings.showTop { return }
        if mode == .bottom && !settings.showBottom { return }

        let adjustedMs = max(0, Int((timeSec * 1000.0).rounded()) + settings.timeOffsetMs)
        let effectiveId = id.isEmpty ? "\(adjustedMs)_\(list.count)" : id
        list.append(
            DanmuComment(
                id: effectiveId,
                timeMs: adjustedMs,
                mode: mode,
                colorRgb: colorRgb & 0x00FF_FFFF,
                text: String(trimmed.prefix(180))
            )
        )
    }

    private func applySignatureIfAuthorized(
        request: inout URLRequest,
        origin: String,
        apiPath: String,
        settings: DanmuSettings
    ) {
        guard Self.shouldSendCredentials(toOrigin: origin, settings: settings) else { return }
        let ts = Int64(Date().timeIntervalSince1970)
        let signatureInput = "\(settings.appId)\(ts)\(apiPath)\(settings.appSecret)"
        let digest = Data(SHA256.hash(data: Data(signatureInput.utf8))).base64EncodedString()
        request.setValue(settings.appId, forHTTPHeaderField: "X-AppId")
        request.setValue("\(ts)", forHTTPHeaderField: "X-Timestamp")
        request.setValue(digest, forHTTPHeaderField: "X-Signature")
    }

    private static func unescapeXml(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func stringValueStatic(_ any: Any?) -> String {
        guard let any = any, !(any is NSNull) else { return "" }
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private func stringVal(_ any: Any?) -> String {
        Self.stringValueStatic(any)
    }
}
