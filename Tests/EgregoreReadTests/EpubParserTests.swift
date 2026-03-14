import XCTest
@testable import EgregoreReadLib

final class EpubParserTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("egregore-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func createEpub(
        chapters: [(id: String, href: String, body: String)],
        encryption: String? = nil,
        pageListNav: String? = nil
    ) throws -> String {
        let epubRoot = tempDir.appendingPathComponent("epub-content")
        let metaInf = epubRoot.appendingPathComponent("META-INF")
        let oebps = epubRoot.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)

        // mimetype
        try "application/epub+zip".write(to: epubRoot.appendingPathComponent("mimetype"),
                                          atomically: true, encoding: .utf8)

        // container.xml
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try container.write(to: metaInf.appendingPathComponent("container.xml"),
                           atomically: true, encoding: .utf8)

        // encryption.xml (optional)
        if let enc = encryption {
            try enc.write(to: metaInf.appendingPathComponent("encryption.xml"),
                         atomically: true, encoding: .utf8)
        }

        // content.opf
        var manifestItems = ""
        var spineItems = ""
        for ch in chapters {
            manifestItems += "    <item id=\"\(ch.id)\" href=\"\(ch.href)\" media-type=\"application/xhtml+xml\"/>\n"
            spineItems += "    <itemref idref=\"\(ch.id)\"/>\n"
        }
        if pageListNav != nil {
            manifestItems += "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        }

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata/>
          <manifest>
        \(manifestItems)  </manifest>
          <spine>
        \(spineItems)  </spine>
        </package>
        """
        try opf.write(to: oebps.appendingPathComponent("content.opf"),
                     atomically: true, encoding: .utf8)

        // Chapter XHTML files
        for ch in chapters {
            let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>\(ch.id)</title></head>
            <body>
            \(ch.body)
            </body>
            </html>
            """
            try xhtml.write(to: oebps.appendingPathComponent(ch.href),
                           atomically: true, encoding: .utf8)
        }

        // nav.xhtml (optional)
        if let nav = pageListNav {
            try nav.write(to: oebps.appendingPathComponent("nav.xhtml"),
                         atomically: true, encoding: .utf8)
        }

        // Zip it into an epub
        let epubPath = tempDir.appendingPathComponent("test.epub").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-rq", epubPath, "."]
        process.currentDirectoryURL = epubRoot
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return epubPath
    }

    // MARK: - Parsing tests

    func testParsesSingleChapterWithParagraphs() throws {
        let path = try createEpub(chapters: [
            (id: "ch1", href: "ch1.xhtml", body: """
            <h1>First Chapter</h1>
            <p>Hello world.</p>
            <p>Second paragraph.</p>
            """)
        ])

        let book = try EpubParser.parse(path: path)
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters[0].title, "ch1") // <title> tag takes precedence over <h1>
        XCTAssertEqual(book.chapters[0].paragraphs.count, 3) // h1 + 2 p's
        XCTAssertEqual(book.chapters[0].paragraphs[0], "First Chapter")
        XCTAssertEqual(book.chapters[0].paragraphs[1], "Hello world.")
        XCTAssertEqual(book.chapters[0].paragraphs[2], "Second paragraph.")
    }

    func testParsesMultipleChaptersInSpineOrder() throws {
        let path = try createEpub(chapters: [
            (id: "ch1", href: "ch1.xhtml", body: "<p>Chapter one text.</p>"),
            (id: "ch2", href: "ch2.xhtml", body: "<p>Chapter two text.</p>"),
            (id: "ch3", href: "ch3.xhtml", body: "<p>Chapter three text.</p>"),
        ])

        let book = try EpubParser.parse(path: path)
        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertEqual(book.chapters[0].paragraphs.first, "Chapter one text.")
        XCTAssertEqual(book.chapters[1].paragraphs.first, "Chapter two text.")
        XCTAssertEqual(book.chapters[2].paragraphs.first, "Chapter three text.")
    }

    func testExtractsHeadingsAndDivs() throws {
        let path = try createEpub(chapters: [
            (id: "ch1", href: "ch1.xhtml", body: """
            <h2>Section Title</h2>
            <div>Div content here.</div>
            <p>Regular paragraph.</p>
            """)
        ])

        let book = try EpubParser.parse(path: path)
        let paras = book.chapters[0].paragraphs
        XCTAssertEqual(paras.count, 3)
        XCTAssertEqual(paras[0], "Section Title")
        XCTAssertEqual(paras[1], "Div content here.")
        XCTAssertEqual(paras[2], "Regular paragraph.")
    }

    func testSkipsEmptyParagraphs() throws {
        let path = try createEpub(chapters: [
            (id: "ch1", href: "ch1.xhtml", body: """
            <p>Real content.</p>
            <p>   </p>
            <p></p>
            <p>More content.</p>
            """)
        ])

        let book = try EpubParser.parse(path: path)
        XCTAssertEqual(book.chapters[0].paragraphs, ["Real content.", "More content."])
    }

    func testTitleFallsBackToHTMLTitle() throws {
        let path = try createEpub(chapters: [
            (id: "ch1", href: "ch1.xhtml", body: "<p>No heading here.</p>")
        ])

        let book = try EpubParser.parse(path: path)
        XCTAssertEqual(book.chapters[0].title, "ch1") // from <title>ch1</title>
    }

    func testPageListIsNilWhenAbsent() throws {
        let path = try createEpub(chapters: [
            (id: "ch1", href: "ch1.xhtml", body: "<p>Text.</p>")
        ])

        let book = try EpubParser.parse(path: path)
        XCTAssertNil(book.pageList)
    }

    // MARK: - Error tests

    func testFileNotFoundThrows() {
        XCTAssertThrowsError(try EpubParser.parse(path: "/nonexistent/book.epub")) { error in
            guard let epubError = error as? EpubError else {
                return XCTFail("Expected EpubError")
            }
            if case .fileNotFound = epubError {} else {
                XCTFail("Expected fileNotFound, got \(epubError)")
            }
        }
    }

    func testDRMProtectedEpubThrows() throws {
        let encryption = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
            <CipherData><CipherReference URI="OEBPS/ch1.xhtml"/></CipherData>
          </EncryptedData>
        </encryption>
        """

        let path = try createEpub(
            chapters: [(id: "ch1", href: "ch1.xhtml", body: "<p>Encrypted.</p>")],
            encryption: encryption
        )

        XCTAssertThrowsError(try EpubParser.parse(path: path)) { error in
            guard let epubError = error as? EpubError else {
                return XCTFail("Expected EpubError")
            }
            if case .drmProtected = epubError {} else {
                XCTFail("Expected drmProtected, got \(epubError)")
            }
        }
    }

    func testEncryptionXMLWithoutEncryptedDataPasses() throws {
        let encryption = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        </encryption>
        """

        let path = try createEpub(
            chapters: [(id: "ch1", href: "ch1.xhtml", body: "<p>Not encrypted.</p>")],
            encryption: encryption
        )

        let book = try EpubParser.parse(path: path)
        XCTAssertEqual(book.chapters.count, 1)
    }
}
