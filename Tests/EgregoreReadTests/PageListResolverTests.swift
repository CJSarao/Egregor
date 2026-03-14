import XCTest
@testable import EgregoreReadLib

final class PageListResolverTests: XCTestCase {

    func testResolvesExactPage() {
        let pages = [
            PageRef(page: 1, chapterIndex: 0, paragraphIndex: 0),
            PageRef(page: 10, chapterIndex: 1, paragraphIndex: 0),
            PageRef(page: 20, chapterIndex: 2, paragraphIndex: 0),
        ]
        let pos = PageListResolver.resolve(page: 10, in: pages)
        XCTAssertEqual(pos?.chapterIndex, 1)
        XCTAssertEqual(pos?.paragraphIndex, 0)
    }

    func testResolvesPageBetweenEntries() {
        let pages = [
            PageRef(page: 1, chapterIndex: 0, paragraphIndex: 0),
            PageRef(page: 10, chapterIndex: 1, paragraphIndex: 0),
            PageRef(page: 20, chapterIndex: 2, paragraphIndex: 0),
        ]
        let pos = PageListResolver.resolve(page: 15, in: pages)
        XCTAssertEqual(pos?.chapterIndex, 1)
    }

    func testResolvesLastPage() {
        let pages = [
            PageRef(page: 1, chapterIndex: 0, paragraphIndex: 0),
            PageRef(page: 50, chapterIndex: 3, paragraphIndex: 5),
        ]
        let pos = PageListResolver.resolve(page: 999, in: pages)
        XCTAssertEqual(pos?.chapterIndex, 3)
        XCTAssertEqual(pos?.paragraphIndex, 5)
    }

    func testReturnsNilForPageBeforeFirst() {
        let pages = [
            PageRef(page: 5, chapterIndex: 0, paragraphIndex: 0),
        ]
        XCTAssertNil(PageListResolver.resolve(page: 1, in: pages))
    }

    func testReturnsNilForEmptyPageList() {
        XCTAssertNil(PageListResolver.resolve(page: 1, in: []))
    }
}
