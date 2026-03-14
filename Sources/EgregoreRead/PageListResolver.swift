enum PageListResolver {
    struct Position {
        let chapterIndex: Int
        let paragraphIndex: Int
    }

    static func resolve(page: Int, in pageList: [PageRef]) -> Position? {
        guard let ref = pageList.last(where: { $0.page <= page }) else { return nil }
        return Position(chapterIndex: ref.chapterIndex, paragraphIndex: ref.paragraphIndex)
    }
}
