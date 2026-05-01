// ScratchFormulaParser.swift
// ScratchLab
// Minimal independent parser for scratch formula expressions.

import Foundation

enum ScratchFormulaParseError: Error, LocalizedError {
    case emptyInput
    case invalidCharacter(Character, Int)
    case expectedToken(String, Int)
    case unexpectedToken(String, Int)
    case trailingInput(Int)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Formula is empty."
        case .invalidCharacter(let char, let index):
            return "Invalid character '\(char)' at index \(index)."
        case .expectedToken(let expected, let index):
            return "Expected \(expected) at index \(index)."
        case .unexpectedToken(let token, let index):
            return "Unexpected token '\(token)' at index \(index)."
        case .trailingInput(let index):
            return "Unexpected trailing input at index \(index)."
        }
    }
}

private enum ScratchFormulaToken: Equatable {
    case identifier(String)
    case number(Double)
    case plus
    case minus
    case star
    case slash
    case leftParen
    case rightParen
}

private struct ScratchFormulaLexeme: Equatable {
    let token: ScratchFormulaToken
    let source: String
    let index: Int
}

struct ScratchFormulaParser {
    func parse(_ input: String) throws -> ScratchFormulaAST {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScratchFormulaParseError.emptyInput }

        let lexemes = try tokenize(trimmed)
        var state = ParserState(lexemes: lexemes)
        let root = try state.parseExpression()
        if let trailing = state.peek() {
            throw ScratchFormulaParseError.trailingInput(trailing.index)
        }
        return ScratchFormulaAST(root: root)
    }

    private func tokenize(_ input: String) throws -> [ScratchFormulaLexeme] {
        let chars = Array(input)
        var result: [ScratchFormulaLexeme] = []
        var i = 0

        while i < chars.count {
            let char = chars[i]

            if char.isWhitespace {
                i += 1
                continue
            }

            switch char {
            case "+":
                result.append(.init(token: .plus, source: "+", index: i))
                i += 1
            case "-":
                result.append(.init(token: .minus, source: "-", index: i))
                i += 1
            case "*":
                result.append(.init(token: .star, source: "*", index: i))
                i += 1
            case "/":
                result.append(.init(token: .slash, source: "/", index: i))
                i += 1
            case "(":
                result.append(.init(token: .leftParen, source: "(", index: i))
                i += 1
            case ")":
                result.append(.init(token: .rightParen, source: ")", index: i))
                i += 1
            default:
                if char.isASCIIIdentifierStart {
                    let start = i
                    i += 1
                    while i < chars.count, chars[i].isASCIIIdentifierBody {
                        i += 1
                    }
                    let source = String(chars[start..<i])
                    result.append(.init(token: .identifier(source), source: source, index: start))
                } else if char.isNumber || char == "." {
                    let start = i
                    var sawDot = (char == ".")
                    i += 1
                    while i < chars.count {
                        let next = chars[i]
                        if next == "." {
                            if sawDot { break }
                            sawDot = true
                            i += 1
                            continue
                        }
                        if !next.isNumber { break }
                        i += 1
                    }
                    let source = String(chars[start..<i])
                    guard let value = Double(source) else {
                        throw ScratchFormulaParseError.unexpectedToken(source, start)
                    }
                    result.append(.init(token: .number(value), source: source, index: start))
                } else {
                    throw ScratchFormulaParseError.invalidCharacter(char, i)
                }
            }
        }

        return result
    }
}

private extension Character {
    var isASCIIIdentifierStart: Bool {
        isLetter || self == "_"
    }

    var isASCIIIdentifierBody: Bool {
        isLetter || isNumber || self == "_"
    }
}

private struct ParserState {
    let lexemes: [ScratchFormulaLexeme]
    var position = 0

    mutating func parseExpression() throws -> ScratchFormulaNode {
        try parseChain()
    }

    mutating func parseChain() throws -> ScratchFormulaNode {
        var node = try parseScaleOrRepeat()
        while match(.plus) {
            let rhs = try parseScaleOrRepeat()
            node = .binary(.chain, node, rhs)
        }
        return node
    }

    mutating func parseScaleOrRepeat() throws -> ScratchFormulaNode {
        var node = try parseUnary()

        while true {
            if match(.star) {
                let rhs = try parseUnary()
                node = .binary(.repeatCount, node, rhs)
                continue
            }
            if match(.slash) {
                let rhs = try parseUnary()
                node = .binary(.stretch, node, rhs)
                continue
            }
            break
        }

        return node
    }

    mutating func parseUnary() throws -> ScratchFormulaNode {
        if match(.minus) {
            return .unary(.reverse, try parseUnary())
        }
        return try parsePrimary()
    }

    mutating func parsePrimary() throws -> ScratchFormulaNode {
        guard let current = peek() else {
            throw ScratchFormulaParseError.expectedToken("symbol, number, or '('", sourceIndex())
        }

        switch current.token {
        case .identifier(let symbol):
            _ = consume()
            return .symbol(symbol)
        case .number(let value):
            _ = consume()
            return .scalar(value)
        case .leftParen:
            _ = consume()
            let nested = try parseExpression()
            guard match(.rightParen) else {
                throw ScratchFormulaParseError.expectedToken("')'", sourceIndex())
            }
            return nested
        default:
            throw ScratchFormulaParseError.unexpectedToken(current.source, current.index)
        }
    }

    func peek() -> ScratchFormulaLexeme? {
        guard position < lexemes.count else { return nil }
        return lexemes[position]
    }

    mutating func consume() -> ScratchFormulaLexeme? {
        guard position < lexemes.count else { return nil }
        defer { position += 1 }
        return lexemes[position]
    }

    mutating func match(_ token: ScratchFormulaToken) -> Bool {
        guard let current = peek(), current.token == token else { return false }
        _ = consume()
        return true
    }

    func sourceIndex() -> Int {
        peek()?.index ?? lexemes.last.map { $0.index + $0.source.count } ?? 0
    }
}
