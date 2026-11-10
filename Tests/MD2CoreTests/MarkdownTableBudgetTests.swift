import Foundation
import Testing
@testable import MD2Core

struct MarkdownTableBudgetTests {
    private func table(rows: Int, columns: Int) -> String {
        let content = "|" + Array(repeating: "x", count: columns).joined(separator: "|") + "|"
        let delimiter = "|" + Array(repeating: "-", count: columns).joined(separator: "|") + "|"
        return ([content, delimiter] + Array(repeating: content, count: rows - 2)).joined(separator: "\n")
    }
    private func result(_ source: String, _ action: MarkdownTableEditing.Action = .nextCell) -> Result<MarkdownEditing.Edit, MarkdownTableEditing.Rejection> {
        let location = (source as NSString).range(of: "x").location
        return MarkdownTableEditing.result(source, selection: NSRange(location: location, length: 0), action: action)
    }
    @Test func exactColumnAndCellLimitsAndOneOver() throws {
        _ = try result(table(rows: 3, columns: 128)).get()
        #expect(result(table(rows: 3, columns: 129)) == .failure(.budget))
        _ = try result(table(rows: 200, columns: 100)).get()
        #expect(result(table(rows: 201, columns: 100)) == .failure(.budget))
        #expect(result(table(rows: 200, columns: 100), .insertColumnAfter) == .failure(.budget))
        #expect(result(table(rows: 200, columns: 100), .insertRowBelow) == .failure(.budget))
    }
    @Test func exactRowLimitAndOneOver() throws {
        _ = try result(table(rows: 1_000, columns: 2)).get()
        #expect(result(table(rows: 1_001, columns: 2)) == .failure(.budget))
        #expect(result(table(rows: 1_000, columns: 2), .insertRowBelow) == .failure(.budget))
    }
    @Test func exactSourceAndTableUnitsAndOneOver() throws {
        let small = table(rows: 3, columns: 2)
        let exactSource = String(repeating: "a", count: 500_000 - small.utf16.count - 2) + "\n\n" + small
        _ = try result(exactSource).get()
        #expect(result("a" + exactSource) == .failure(.budget))
        let exactTable = String(small.dropLast(2)) + String(repeating: "a", count: 100_000 - small.utf16.count) + "x|"
        _ = try result(exactTable).get()
        #expect(result(exactTable + "a") == .failure(.budget))
        #expect(result(exactTable, .insertRowBelow) == .failure(.budget))
    }
    @Test func sourceLineLimitIncludesSparseBlankLines() throws {
        let exact = String(repeating: "\n", count: 19_997) + table(rows: 3, columns: 2)
        _ = try result(exact).get()
        #expect(result("\n" + exact) == .failure(.budget))
    }
}
