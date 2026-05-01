// ScratchFormulaAST.swift
// ScratchLab
// Independent formula AST used for clean-room scratch expression parsing/rendering.

import Foundation

enum ScratchFormulaUnaryOperator: String, CaseIterable, Codable {
    case reverse = "-"
}

enum ScratchFormulaBinaryOperator: String, CaseIterable, Codable {
    case chain = "+"
    case repeatCount = "*"
    case stretch = "/"
}

indirect enum ScratchFormulaNode: Equatable, Codable {
    case symbol(String)
    case scalar(Double)
    case unary(ScratchFormulaUnaryOperator, ScratchFormulaNode)
    case binary(ScratchFormulaBinaryOperator, ScratchFormulaNode, ScratchFormulaNode)
}

struct ScratchFormulaAST: Equatable, Codable {
    let root: ScratchFormulaNode
}
