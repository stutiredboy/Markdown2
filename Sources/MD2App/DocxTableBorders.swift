import Foundation

enum DocxTableBorders {
    enum Part: String, CaseIterable {
        case document
        case footnotes

        var path: String { "word/\(rawValue).xml" }
    }

    private static let namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    static func addingGrid(to documentXML: Data, part: Part) throws -> Data? {
        let document = try XMLDocument(
            data: documentXML, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]
        )
        guard let root = document.rootElement(), root.localName == part.rawValue, root.uri == namespace else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tables = try document.nodes(forXPath: "//*[local-name()='tbl']")
            .compactMap { $0 as? XMLElement }
            .filter { $0.uri == namespace }
        guard !tables.isEmpty else { return nil }
        // Word can ignore borders inherited from Pandoc's legacy TableNormal
        // style. Apply the grid directly to each table's properties.
        for table in tables { addGrid(to: table) }
        return document.xmlData(options: .nodeCompactEmptyElement)
    }

    private static func addGrid(to table: XMLElement) {
        let tablePrefix = table.prefix ?? ""
        let prefix = tablePrefix.isEmpty ? "w" : tablePrefix
        let properties: XMLElement
        if let existing = table.elements(forLocalName: "tblPr", uri: namespace).first {
            properties = existing
        } else {
            let name = tablePrefix.isEmpty ? "tblPr" : "\(prefix):tblPr"
            properties = XMLElement(name: name, uri: namespace)
            let grid = table.elements(forLocalName: "tblGrid", uri: namespace).first
            table.insertChild(properties, at: grid?.index ?? 0)
        }

        let borders = XMLElement(name: "\(prefix):tblBorders", uri: namespace)
        if tablePrefix.isEmpty {
            borders.addNamespace(XMLNode.namespace(withName: prefix, stringValue: namespace) as! XMLNode)
        }
        for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
            let border = XMLElement(name: "\(prefix):\(edge)", uri: namespace)
            for (attribute, value) in [("val", "single"), ("sz", "4"), ("space", "0"), ("color", "auto")] {
                border.addAttribute(XMLNode.attribute(withName: "\(prefix):\(attribute)", stringValue: value) as! XMLNode)
            }
            borders.addChild(border)
        }

        // OOXML requires tblBorders before shading, cell margins, and table look.
        if let existing = properties.elements(forLocalName: "tblBorders", uri: namespace).first {
            properties.replaceChild(at: existing.index, with: borders)
        } else {
            insert(borders, in: properties, before: [
                "shd", "tblLayout", "tblCellMar", "tblLook", "tblCaption", "tblDescription", "tblPrChange"
            ])
        }
    }

    private static func insert(_ element: XMLElement, in parent: XMLElement, before names: Set<String>) {
        let next = parent.children?.first {
            $0.uri == namespace && names.contains($0.localName ?? "")
        }
        parent.insertChild(element, at: next?.index ?? parent.childCount)
    }
}
