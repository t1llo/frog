import XCTest
@testable import FrogApp

final class MarkdownPreviewTests: XCTestCase {
    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    func testHeadingsParagraphsCodeAndRulesAreBlocksOfTheirOwnWithoutTheirMarkers() {
        let blocks = MarkdownPreview.blocks("""
        # Plan

        ## For *today*

        Buy **two** things
        before noon.

        ```swift
        let total = 2
          print(total)
        ```

        ---

        Done.
        """)
        XCTAssertEqual(blocks.map(\.kind), [.heading(level: 1), .heading(level: 2), .paragraph, .code, .rule, .paragraph])
        XCTAssertEqual(blocks.map(\.id), Array(0..<6), "The list draws each block once")
        XCTAssertEqual(plain(blocks[0].text), "Plan")
        XCTAssertEqual(plain(blocks[1].text), "For today")
        XCTAssertEqual(plain(blocks[2].text), "Buy two things\nbefore noon.", "A line break inside a paragraph stays where it was typed")
        XCTAssertEqual(plain(blocks[3].text), "let total = 2\n  print(total)", "Code keeps its lines and indentation, without the fence")
        XCTAssertEqual(plain(blocks[5].text), "Done.")
        XCTAssertTrue(blocks.allSatisfy { $0.marker == nil && $0.listDepth == 0 && !$0.quoted })
    }

    func testLinesTypedWithoutMarkdownKeepTheirLineBreaks() throws {
        let blocks = MarkdownPreview.blocks("Call Anna\nBuy stamps\nPick up parcel\n\n- milk\n  from the market\n\nBuy *fresh\nbread* today")
        XCTAssertEqual(blocks.map { plain($0.text) }, ["Call Anna\nBuy stamps\nPick up parcel", "milk\nfrom the market", "Buy fresh\nbread today"])
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph, .paragraph])
        let last = try XCTUnwrap(blocks.last)
        XCTAssertEqual(last.text.runs.filter { $0.inlinePresentationIntent?.contains(.emphasized) == true }.map { String(last.text[$0.range].characters) }.joined(), "fresh\nbread",
                       "Emphasis goes on across the line break")
    }

    func testEmphasisCodeSpansAndLinksStayInsideTheirBlock() throws {
        let block = try XCTUnwrap(MarkdownPreview.blocks("Read the **manual**, run `make` and see [the site](https://example.com).").first)
        XCTAssertEqual(plain(block.text), "Read the manual, run make and see the site.")
        let styles = block.text.runs.reduce(into: [String: InlinePresentationIntent]()) { found, run in
            if let style = run.inlinePresentationIntent { found[String(block.text[run.range].characters)] = style }
        }
        XCTAssertEqual(styles, ["manual": .stronglyEmphasized, "make": .code])
        XCTAssertEqual(block.text.runs.compactMap(\.link), [try XCTUnwrap(URL(string: "https://example.com"))])
    }

    func testListItemsCarryTheirBulletOrNumberAndTheirDepth() {
        let blocks = MarkdownPreview.blocks("""
        - milk
        - bread
          1. sliced
          2. toasted
        - eggs

          from the market
        """)
        XCTAssertEqual(blocks.map { plain($0.text) }, ["milk", "bread", "sliced", "toasted", "eggs", "from the market"])
        XCTAssertEqual(blocks.map(\.marker), ["•", "•", "1.", "2.", "•", nil], "A second paragraph of an item continues it without a bullet of its own")
        XCTAssertEqual(blocks.map(\.listDepth), [1, 1, 2, 2, 1, 1])
        XCTAssertTrue(blocks.allSatisfy { $0.kind == .paragraph })
    }

    func testQuotedBlocksAreMarkedAsQuoted() {
        let blocks = MarkdownPreview.blocks("""
        > Remember the bag
        >
        > - and the list

        Not quoted.
        """)
        XCTAssertEqual(blocks.map { plain($0.text) }, ["Remember the bag", "and the list", "Not quoted."])
        XCTAssertEqual(blocks.map(\.quoted), [true, true, false])
        XCTAssertEqual(blocks.map(\.marker), [nil, "•", nil])
    }

    func testATableIsOneBlockWithItsRowsAndKeepsEmptyCellsInPlace() throws {
        let blocks = MarkdownPreview.blocks("""
        | Item | Count | Note |
        | --- | --- | --- |
        | milk | 2 | cold |
        |  | 1 |  |

        After the table.
        """)
        XCTAssertEqual(blocks.count, 2)
        guard case .table(let rows) = try XCTUnwrap(blocks.first).kind else { return XCTFail("The table is not one block") }
        XCTAssertEqual(rows.map { $0.map(plain) }, [["Item", "Count", "Note"], ["milk", "2", "cold"], ["", "1"]])
        XCTAssertEqual(blocks[1].kind, .paragraph)
        XCTAssertEqual(blocks[1].id, 1)
    }

    func testTextWithoutMarkdownAndAnEmptyNote() {
        XCTAssertEqual(MarkdownPreview.blocks(""), [])
        XCTAssertEqual(MarkdownPreview.blocks(" \n\n"), [])
        let blocks = MarkdownPreview.blocks("First line\n\nSecond <b>line</b>\n\n<div>kept as typed</div>\n")
        XCTAssertEqual(blocks.map { plain($0.text) }, ["First line", "Second <b>line</b>", "<div>kept as typed</div>"])
        XCTAssertTrue(blocks.allSatisfy { $0.kind == .paragraph })
    }
}
