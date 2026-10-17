import Foundation

/// Minimal IPTC-Core-over-XMP sidecar support (the modern `.xmp` standard used by
/// Lightroom et al.). Reads/writes: title, caption, keywords, rating, capture date,
/// GPS. Packets are valid XMP; parsing tolerates both our writer's output and
/// common third-party files.
enum XMP {

    struct Metadata: Sendable, Equatable {
        var title: String?
        var caption: String?
        var keywords: [String] = []
        var rating: Int?
        var dateCreated: Date?
        var latitude: Double?
        var longitude: Double?
    }

    // MARK: - Writing

    static func writePacket(_ m: Metadata) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func altTag(_ tag: String, _ value: String?) -> String {
            guard let value, !value.isEmpty else { return "" }
            return """
            <dc:\(tag)><rdf:Alt><rdf:li xml:lang="x-default">\(escape(value))</rdf:li></rdf:Alt></dc:\(tag)>

            """
        }
        var body = ""
        body += altTag("title", m.title)
        body += altTag("description", m.caption)
        if !m.keywords.isEmpty {
            let items = m.keywords.map { "<rdf:li>\(escape($0))</rdf:li>" }.joined()
            body += "<dc:subject><rdf:Bag>\(items)</rdf:Bag></dc:subject>\n    "
        }
        if let rating = m.rating {
            body += "<xmp:Rating>\(rating)</xmp:Rating>\n    "
        }
        if let date = m.dateCreated {
            body += "<photoshop:DateCreated>\(iso8601(date))</photoshop:DateCreated>\n    "
        }
        if let lat = m.latitude {
            body += "<exif:GPSLatitude>\(xmpCoordinate(lat, positive: "N", negative: "S"))</exif:GPSLatitude>\n    "
        }
        if let lon = m.longitude {
            body += "<exif:GPSLongitude>\(xmpCoordinate(lon, positive: "E", negative: "W"))</exif:GPSLongitude>\n    "
        }
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9c"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
              xmlns:exif="http://ns.adobe.com/exif/1.0/">
              \(body.trimmingCharacters(in: .whitespacesAndNewlines))
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """
    }

    static func write(_ m: Metadata, to url: URL) throws {
        try writePacket(m).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Reading

    static func parse(url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> Metadata? {
        var meta = Metadata()
        let parser = XMPParser(data: data)
        guard parser.parse() else { return nil }
        meta.title = parser.altText["title"]
        meta.caption = parser.altText["description"]
        meta.keywords = parser.subjectItems
        if let r = parser.simpleValues["Rating"], let v = Int(r) { meta.rating = v }
        if let d = parser.simpleValues["DateCreated"] { meta.dateCreated = parseISO8601(d) }
        if let s = parser.simpleValues["GPSLatitude"] { meta.latitude = parseCoordinate(s) }
        if let s = parser.simpleValues["GPSLongitude"] { meta.longitude = parseCoordinate(s) }
        return meta
    }

    // MARK: - Helpers

    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Fallback: date-only
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    /// Decimal degrees → XMP "DD,MM.MMMMR" (degrees, decimal minutes, hemisphere ref).
    static func xmpCoordinate(_ decimal: Double, positive: String, negative: String) -> String {
        let ref = decimal >= 0 ? positive : negative
        let abs = abs(decimal)
        let degrees = Int(abs)
        let minutes = (abs - Double(degrees)) * 60
        return String(format: "%d,%.4f%@", degrees, minutes, ref)
    }

    /// Accepts "31,13.82N" (XMP) and plain decimal strings; returns signed decimal degrees.
    static func parseCoordinate(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let plain = Double(trimmed) { return plain }
        // XMP form: DD,MM.MMMM[NEWS]
        let pattern = #"^(\d+),(\d+(?:\.\d+)?)([NSEW])$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let degRange = Range(m.range(at: 1), in: trimmed),
              let minRange = Range(m.range(at: 2), in: trimmed),
              let refRange = Range(m.range(at: 3), in: trimmed),
              let degrees = Double(trimmed[degRange]),
              let minutes = Double(trimmed[minRange])
        else { return nil }
        var value = degrees + minutes / 60
        let ref = trimmed[refRange]
        if ref == "S" || ref == "W" { value = -value }
        return value
    }
}

/// XMLParser delegate collecting the fields we support.
private final class XMPParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    var altText: [String: String] = [:]
    var subjectItems: [String] = []
    var simpleValues: [String: String] = [:]

    private var elementStack: [String] = []
    private var currentText = ""

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> Bool {
        parser.parse()
        return parser.parserError == nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        elementStack.append(qName ?? elementName)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = qName ?? elementName
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { elementStack.removeLast() }

        if name == "rdf:li" && !text.isEmpty {
            // Enclosing dc:* element determines semantics.
            if let enclosing = elementStack.dropLast().last(where: { $0.hasPrefix("dc:") }) {
                if enclosing.hasSuffix(":subject") {
                    subjectItems.append(text)
                } else if enclosing.hasSuffix(":title") {
                    altText["title"] = text
                } else if enclosing.hasSuffix(":description") {
                    altText["description"] = text
                }
            }
        }
        for key in ["Rating", "DateCreated", "GPSLatitude", "GPSLongitude"]
        where name.hasSuffix(":\(key)") {
            simpleValues[key] = text
        }
    }
}
