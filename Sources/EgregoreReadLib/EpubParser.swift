import Foundation

public struct Chapter {
    public let title: String?
    public let paragraphs: [String]
}

public struct PageRef {
    public let page: Int
    public let chapterIndex: Int
    public let paragraphIndex: Int

    public init(page: Int, chapterIndex: Int, paragraphIndex: Int) {
        self.page = page
        self.chapterIndex = chapterIndex
        self.paragraphIndex = paragraphIndex
    }
}

public struct EpubBook {
    public let chapters: [Chapter]
    public let pageList: [PageRef]?
}

public enum EpubError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidEpub(String)
    case drmProtected
    case unzipFailed(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): return "File not found: \(path)"
        case .invalidEpub(let reason): return "Invalid epub: \(reason)"
        case .drmProtected: return "This epub is DRM-protected. Only DRM-free epubs are supported."
        case .unzipFailed(let reason): return "Failed to unzip epub: \(reason)"
        }
    }
}

public enum EpubParser {

    public static func parse(path: String) throws -> EpubBook {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw EpubError.fileNotFound(path) }

        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tempDir) }

        try unzip(epub: path, to: tempDir.path)
        try checkDRM(in: tempDir)

        let containerPath = tempDir.appendingPathComponent("META-INF/container.xml").path
        guard fm.fileExists(atPath: containerPath) else {
            throw EpubError.invalidEpub("Missing META-INF/container.xml")
        }

        let opfRelativePath = try parseContainer(at: containerPath)
        let opfURL = tempDir.appendingPathComponent(opfRelativePath)
        let opfDir = opfURL.deletingLastPathComponent()

        let (spineHrefs, manifest) = try parseOPF(at: opfURL.path)

        var chapters: [Chapter] = []
        for href in spineHrefs {
            let chapterURL = opfDir.appendingPathComponent(href)
            guard fm.fileExists(atPath: chapterURL.path) else { continue }
            let chapter = try parseChapterXHTML(at: chapterURL.path)
            chapters.append(chapter)
        }

        let pageList = try parsePageList(opfDir: opfDir, manifest: manifest, spineHrefs: spineHrefs)

        return EpubBook(chapters: chapters, pageList: pageList)
    }

    // MARK: - Unzip

    private static func unzip(epub: String, to destination: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", epub, "-d", destination]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EpubError.unzipFailed("unzip exited with status \(process.terminationStatus)")
        }
    }

    // MARK: - DRM check

    private static func checkDRM(in epubDir: URL) throws {
        let encryptionPath = epubDir.appendingPathComponent("META-INF/encryption.xml").path
        guard FileManager.default.fileExists(atPath: encryptionPath) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: encryptionPath))
        let content = String(data: data, encoding: .utf8) ?? ""
        if content.contains("EncryptedData") {
            throw EpubError.drmProtected
        }
    }

    // MARK: - container.xml → OPF path

    private static func parseContainer(at path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let delegate = ContainerXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let opfPath = delegate.opfPath else {
            throw EpubError.invalidEpub("No rootfile in container.xml")
        }
        return opfPath
    }

    // MARK: - OPF → spine + manifest

    private static func parseOPF(at path: String) throws -> ([String], [String: String]) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let delegate = OPFXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        let spineHrefs = delegate.spineIdRefs.compactMap { delegate.manifest[$0] }
        guard !spineHrefs.isEmpty else {
            throw EpubError.invalidEpub("Empty spine in OPF")
        }
        return (spineHrefs, delegate.manifest)
    }

    // MARK: - Chapter XHTML → paragraphs

    private static func parseChapterXHTML(at path: String) throws -> Chapter {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let delegate = XHTMLParagraphDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        let paragraphs = delegate.paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Chapter(title: delegate.title, paragraphs: paragraphs)
    }

    // MARK: - Page list (optional)

    private static func parsePageList(
        opfDir: URL,
        manifest: [String: String],
        spineHrefs: [String]
    ) throws -> [PageRef]? {
        let fm = FileManager.default

        // Look for nav document (EPUB3)
        for (_, href) in manifest {
            let url = opfDir.appendingPathComponent(href)
            guard fm.fileExists(atPath: url.path),
                  href.hasSuffix(".xhtml") || href.hasSuffix(".html") else { continue }
            let data = try Data(contentsOf: url)
            let content = String(data: data, encoding: .utf8) ?? ""
            guard content.contains("page-list") else { continue }

            let delegate = PageListXMLDelegate(spineHrefs: spineHrefs)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            if !delegate.pages.isEmpty { return delegate.pages }
        }
        return nil
    }
}

// MARK: - XML Delegates

private class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var opfPath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "rootfile", let path = attributes["full-path"] {
            opfPath = path
        }
    }
}

private class OPFXMLDelegate: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]  // id → href
    var spineIdRefs: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "item", let id = attributes["id"], let href = attributes["href"] {
            manifest[id] = href
        } else if elementName == "itemref", let idref = attributes["idref"] {
            spineIdRefs.append(idref)
        }
    }
}

private class XHTMLParagraphDelegate: NSObject, XMLParserDelegate {
    var paragraphs: [String] = []
    var title: String?
    private var currentText = ""
    private var inParagraph = false
    private var inTitle = false
    private var inHeading = false
    private static let paragraphTags: Set<String> = ["p", "div"]
    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let tag = elementName.lowercased()
        if Self.paragraphTags.contains(tag) || Self.headingTags.contains(tag) {
            inParagraph = true
            currentText = ""
        }
        if tag == "title" {
            inTitle = true
            currentText = ""
        }
        if Self.headingTags.contains(tag) {
            inHeading = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inParagraph || inTitle {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let tag = elementName.lowercased()
        if Self.paragraphTags.contains(tag) || Self.headingTags.contains(tag) {
            inParagraph = false
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                paragraphs.append(trimmed)
            }
            if inHeading && title == nil && !trimmed.isEmpty {
                title = trimmed
            }
            inHeading = false
        }
        if tag == "title" {
            inTitle = false
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if title == nil && !trimmed.isEmpty {
                title = trimmed
            }
        }
    }
}

private class PageListXMLDelegate: NSObject, XMLParserDelegate {
    var pages: [PageRef] = []
    private let spineHrefs: [String]
    private var inPageList = false
    private var currentText = ""
    private var currentHref: String?

    init(spineHrefs: [String]) {
        self.spineHrefs = spineHrefs
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let tag = elementName.lowercased()
        if tag == "nav" {
            let type = attributes["epub:type"] ?? attributes["type"] ?? ""
            if type == "page-list" { inPageList = true }
        }
        if inPageList && tag == "a", let href = attributes["href"] {
            currentHref = href
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inPageList { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let tag = elementName.lowercased()
        if tag == "nav" { inPageList = false }
        if tag == "a", let href = currentHref {
            let pageNum = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if pageNum > 0, let ref = resolveHref(href) {
                pages.append(ref)
            }
            currentHref = nil
        }
    }

    private func resolveHref(_ href: String) -> PageRef? {
        let parts = href.split(separator: "#", maxSplits: 1)
        guard let first = parts.first else { return nil }
        let file = String(first)
        guard let chapterIndex = spineHrefs.firstIndex(where: { $0.hasSuffix(file) || file.hasSuffix($0) }) else {
            return nil
        }
        let pageNum = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return PageRef(page: pageNum, chapterIndex: chapterIndex, paragraphIndex: 0)
    }
}
