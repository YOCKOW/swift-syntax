import XCTest
import SwiftSyntax
import SwiftParser
import SwiftOperatorPrecedence
import _SwiftSyntaxTestSupport

/// Visitor that looks for ExprSequenceSyntax nodes.
private class ExprSequenceSearcher: SyntaxAnyVisitor {
  var foundSequenceExpr = false

  override func visit(
    _ node: SequenceExprSyntax
  ) -> SyntaxVisitorContinueKind {
    foundSequenceExpr = true
    return .skipChildren
  }

  override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind{
    return foundSequenceExpr ? .skipChildren : .visitChildren
  }
}

extension SyntaxProtocol {
  /// Determine whether the given syntax contains an ExprSequence anywhere.
  var containsExprSequence: Bool {
    let searcher = ExprSequenceSearcher(viewMode: .sourceAccurate)
    searcher.walk(self)
    return searcher.foundSequenceExpr
  }
}

/// A syntax rewriter that folds explicitly-parenthesized sequence expressions
/// into  a structured syntax tree.
class ExplicitParenFolder : SyntaxRewriter {
  override func visit(_ node: TupleExprSyntax) -> ExprSyntax {
    // Identify syntax nodes of the form (x + y), which is a
    // TupleExprSyntax(SequenceExpr(x, BinaryOperatorExprSyntax, y))./
    guard node.elementList.count == 1,
          let firstNode = node.elementList.first,
          firstNode.label == nil,
          let sequenceExpr = firstNode.expression.as(SequenceExprSyntax.self),
          sequenceExpr.elements.count == 3,
          let leftOperand = sequenceExpr.elements.first,
          let middleExpr = sequenceExpr.elements.removingFirst().first,
          let operatorExpr = middleExpr.as(BinaryOperatorExprSyntax.self),
          let rightOperand =
            sequenceExpr.elements.removingFirst().removingFirst().first
    else {
      return ExprSyntax(node)
    }

    return ExprSyntax(
      InfixOperatorExprSyntax(
        leftOperand: visit(Syntax(leftOperand)).as(ExprSyntax.self)!,
        operatorOperand: ExprSyntax(operatorExpr),
        rightOperand: visit(Syntax(rightOperand)).as(ExprSyntax.self)!)
      )
  }
}

extension OperatorPrecedence {
  /// Assert that parsing and folding the given "unfolded" source code
  /// produces the same syntax tree as the fully-parenthesized version of
  /// the same source.
  ///
  /// The `expectedSource` should be a fully-parenthesized expression, e.g.,
  /// `(a + (b * c))` that expresses how the initial code should have been
  /// folded.
  func assertExpectedFold(
    _ source: String,
    _ fullyParenthesizedSource: String
  ) throws {
    // Parse and fold the source we're testing.
    let parsed = try Parser.parse(source: source)
    let foldedSyntax = try foldAll(parsed)
    XCTAssertFalse(foldedSyntax.containsExprSequence)

    // Parse and "fold" the parenthesized version.
    let parenthesizedParsed = try Parser.parse(source: fullyParenthesizedSource)
    let parenthesizedSyntax = ExplicitParenFolder().visit(parenthesizedParsed)
    XCTAssertFalse(parenthesizedSyntax.containsExprSequence)

    // Make sure the two have the same structure.
    XCTAssertSameStructure(foldedSyntax, parenthesizedSyntax)
  }
}

public class OperatorPrecedenceTests: XCTestCase {
  func testLogicalExprsSingle() throws {
    let opPrecedence = OperatorPrecedence.logicalOperators
    let parsed = try Parser.parse(source: "x && y || w && v || z")
    let sequenceExpr =
      parsed.statements.first!.item.as(SequenceExprSyntax.self)!
    let foldedExpr = try opPrecedence.foldSingle(sequenceExpr)
    XCTAssertEqual("\(foldedExpr)", "x && y || w && v || z")
    XCTAssertNil(foldedExpr.as(SequenceExprSyntax.self))
  }

  func testLogicalExprs() throws {
    let opPrecedence = OperatorPrecedence.logicalOperators
    try opPrecedence.assertExpectedFold("x && y || w", "((x && y) || w)")
    try opPrecedence.assertExpectedFold("x || y && w", "(x || (y && w))")
  }

  func testSwiftExprs() throws {
    let opPrecedence = OperatorPrecedence.standardOperators
    let parsed = try Parser.parse(source: "(x + y > 17) && x && y || w && v || z")
    let sequenceExpr =
        parsed.statements.first!.item.as(SequenceExprSyntax.self)!
    let foldedExpr = try opPrecedence.foldSingle(sequenceExpr)
    XCTAssertEqual("\(foldedExpr)", "(x + y > 17) && x && y || w && v || z")
    XCTAssertNil(foldedExpr.as(SequenceExprSyntax.self))
  }

  func testNestedSwiftExprs() throws {
    let opPrecedence = OperatorPrecedence.standardOperators
    let parsed = try Parser.parse(source: "(x + y > 17) && x && y || w && v || z")
    let foldedAll = try opPrecedence.foldAll(parsed)
    XCTAssertEqual("\(foldedAll)", "(x + y > 17) && x && y || w && v || z")
    XCTAssertFalse(foldedAll.containsExprSequence)
  }

  func testParsedLogicalExprs() throws {
    let logicalOperatorSources =
    """
    precedencegroup LogicalDisjunctionPrecedence {
      associativity: left
    }

    precedencegroup LogicalConjunctionPrecedence {
      associativity: left
      higherThan: LogicalDisjunctionPrecedence
    }

    // "Conjunctive"

    infix operator &&: LogicalConjunctionPrecedence

    // "Disjunctive"

    infix operator ||: LogicalDisjunctionPrecedence
    """

    let parsedOperatorPrecedence = try Parser.parse(source: logicalOperatorSources)
    var opPrecedence = OperatorPrecedence()
    try opPrecedence.addSourceFile(parsedOperatorPrecedence)

    let parsed = try Parser.parse(source: "x && y || w && v || z")
    let sequenceExpr =
      parsed.statements.first!.item.as(SequenceExprSyntax.self)!
    let foldedExpr = try opPrecedence.foldSingle(sequenceExpr)
    XCTAssertEqual("\(foldedExpr)", "x && y || w && v || z")
    XCTAssertNil(foldedExpr.as(SequenceExprSyntax.self))
  }

  func testParseErrors() throws {
    let sources =
    """
    infix operator +
    infix operator +

    precedencegroup A {
      associativity: none
      higherThan: B
    }

    precedencegroup A {
      associativity: none
      higherThan: B
    }
    """

    let parsedOperatorPrecedence = try Parser.parse(source: sources)

    var opPrecedence = OperatorPrecedence()
    var errors: [OperatorPrecedenceError] = []
    opPrecedence.addSourceFile(parsedOperatorPrecedence) { error in
      errors.append(error)
    }

    XCTAssertEqual(errors.count, 2)
    guard case let .operatorAlreadyExists(existing, new) = errors[0] else {
      XCTFail("expected an 'operator already exists' error")
      return
    }

    XCTAssertEqual(errors[0].message, "redefinition of infix operator '+'")
    _ = existing
    _ = new

    guard case let .groupAlreadyExists(existingGroup, newGroup) = errors[1] else {
      XCTFail("expected a 'group already exists' error")
      return
    }
    XCTAssertEqual(errors[1].message, "redefinition of precedence group 'A'")
    _ = newGroup
    _ = existingGroup
  }

  func testFoldErrors() throws {
    let parsedOperatorPrecedence = try Parser.parse(source:
      """
      precedencegroup A {
        associativity: none
      }

      precedencegroup C {
        associativity: none
        lowerThan: B
      }

      precedencegroup D {
        associativity: none
      }

      infix operator +: A
      infix operator -: A

      infix operator *: C

      infix operator ++: D
      """)

    var opPrecedence = OperatorPrecedence()
    try opPrecedence.addSourceFile(parsedOperatorPrecedence)

    do {
      var errors: [OperatorPrecedenceError] = []
      let parsed = try Parser.parse(source: "a + b * c")
      let sequenceExpr =
        parsed.statements.first!.item.as(SequenceExprSyntax.self)!
      _ = opPrecedence.foldSingle(sequenceExpr) { error in
        errors.append(error)
      }

      XCTAssertEqual(errors.count, 2)
      guard case let .missingGroup(groupName, location) = errors[0] else {
        XCTFail("expected a 'missing group' error")
        return
      }
      XCTAssertEqual(groupName, "B")
      XCTAssertEqual(errors[0].message, "unknown precedence group 'B'")
      _ = location
    }

    do {
      var errors: [OperatorPrecedenceError] = []
      let parsed = try Parser.parse(source: "a / c")
      let sequenceExpr =
        parsed.statements.first!.item.as(SequenceExprSyntax.self)!
      _ = opPrecedence.foldSingle(sequenceExpr) { error in
        errors.append(error)
      }

      XCTAssertEqual(errors.count, 1)
      guard case let .missingOperator(operatorName, location) = errors[0] else {
        XCTFail("expected a 'missing operator' error")
        return
      }
      XCTAssertEqual(operatorName, "/")
      XCTAssertEqual(errors[0].message, "unknown infix operator '/'")
      _ = location
    }

    do {
      var errors: [OperatorPrecedenceError] = []
      let parsed = try Parser.parse(source: "a + b - c")
      let sequenceExpr =
        parsed.statements.first!.item.as(SequenceExprSyntax.self)!
      _ = opPrecedence.foldSingle(sequenceExpr) { error in
        errors.append(error)
      }

      XCTAssertEqual(errors.count, 1)
      guard case let .incomparableOperators(_, leftGroup, _, rightGroup) =
              errors[0] else {
        XCTFail("expected an 'incomparable operator' error")
        return
      }
      XCTAssertEqual(leftGroup, "A")
      XCTAssertEqual(rightGroup, "A")
      XCTAssertEqual(
        errors[0].message,
        "adjacent operators are in non-associative precedence group 'A'")
    }

    do {
      var errors: [OperatorPrecedenceError] = []
      let parsed = try Parser.parse(source: "a ++ b - d")
      let sequenceExpr =
        parsed.statements.first!.item.as(SequenceExprSyntax.self)!
      _ = opPrecedence.foldSingle(sequenceExpr) { error in
        errors.append(error)
      }

      XCTAssertEqual(errors.count, 1)
      guard case let .incomparableOperators(_, leftGroup, _, rightGroup) =
              errors[0] else {
        XCTFail("expected an 'incomparable operator' error")
        return
      }
      XCTAssertEqual(leftGroup, "D")
      XCTAssertEqual(rightGroup, "A")
      XCTAssertEqual(
        errors[0].message,
        "adjacent operators are in unordered precedence groups 'D' and 'A'")
    }
  }
}
