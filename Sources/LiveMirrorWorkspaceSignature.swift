import Foundation

// QLab's dirty flag also covers controller state (including playhead changes).
// Compare the saved cue/settings graph instead of accepting/rejecting every dirty document.
// Saving preserves genuine operator edits; a differing signature still refuses readiness.
enum MirrorWorkspaceSignature {
    static func capture(_ path: String) throws -> String {
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let value = try archive(raw, depth: 0)
        guard JSONSerialization.isValidJSONObject(value) else { throw MirrorFailure.invalid("Signature workspace non sérialisable") }
        return MirrorFiles.hash(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
    }
    private static func archive(_ data: Data, depth: Int) throws -> Any {
        guard depth < 8, data.count < 128 * 1024 * 1024 else { throw MirrorFailure.invalid("Workspace trop complexe pour vérification") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("qlab-signature-" + UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-convert", "xml1", "-o", "-", file.path]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let xml = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try SignatureXML.read(xml) as? [String: Any],
              root["$archiver"] as? String == "NSKeyedArchiver",
              let objects = root["$objects"] as? [Any], let top = root["$top"] as? [String: Any], let entry = top["root"] else {
            throw MirrorFailure.invalid("Format du workspace non reconnu pour vérification")
        }
        let uiKeys: Set<String> = ["controller", "selectedCueListID", "highlightRelatedCues", "canvasZoomScale",
            "canvasContentOffset", "objectsSplitPosition", "waveformVisibleChannel", "expanded", "lastSeenAudioOutputPatchInfo"]
        func expand(_ v: Any, visiting: [Int], level: Int) throws -> Any {
            guard level < 150 else { throw MirrorFailure.invalid("Workspace trop imbriqué") }
            if let r = v as? [String: Any], r.count == 1, let index = r["CF$UID"] as? Int {
                guard objects.indices.contains(index) else { throw MirrorFailure.invalid("Référence workspace invalide") }
                if let ancestor = visiting.firstIndex(of: index) { return ["ancestorDistance": visiting.count - ancestor] }
                if index == 0 { return NSNull() }
                return try expand(objects[index], visiting: visiting + [index], level: level + 1)
            }
            if let array = v as? [Any] { return try array.map { try expand($0, visiting: visiting, level: level + 1) } }
            if let d = v as? [String: Any] {
                var result = [String: Any]()
                if let keys = d["NS.keys"] as? [Any], let values = d["NS.objects"] as? [Any] {
                    guard keys.count == values.count else { throw MirrorFailure.invalid("Dictionnaire workspace invalide") }
                    for (key, value) in zip(keys, values) {
                        let expandedKey = try expand(key, visiting: visiting, level: level + 1)
                        if let key = expandedKey as? String, uiKeys.contains(key) || ["OSC Access", "Collaboration"].contains(key) { continue }
                        let encodedKey = try JSONSerialization.data(withJSONObject: expandedKey, options: [.sortedKeys, .fragmentsAllowed]).base64EncodedString()
                        result[encodedKey] = try expand(value, visiting: visiting, level: level + 1)
                    }
                    return result
                }
                var className = ""
                if let ref = d["$class"] as? [String: Any], let index = ref["CF$UID"] as? Int,
                   objects.indices.contains(index), let cls = objects[index] as? [String: Any] { className = cls["$classname"] as? String ?? "" }
                if let bytes = d["NS.data"] as? Data {
                    if let embedded = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                       embedded["$archiver"] as? String == "NSKeyedArchiver" {
                        return try archive(bytes, depth: depth + 1)
                    }
                }
                if !className.isEmpty { result["class"] = className }
                for (key, value) in d where key != "$class" && !uiKeys.contains(key) {
                    if className == "AudioOutputPatch" && key == "muteChannels" { continue }
                    result[key] = try expand(value, visiting: visiting, level: level + 1)
                }
                return result
            }
            if let bytes = v as? Data { return ["data": bytes.base64EncodedString()] }
            if let date = v as? Date { return ["date": date.timeIntervalSinceReferenceDate] }
            return v
        }
        return try expand(entry, visiting: [], level: 0)
    }
}

private final class SignatureXML: NSObject, XMLParserDelegate {
    struct Container {
        var kind: String
        var array = [Any]()
        var dictionary = [String: Any]()
        var key: String?
    }
    private var stack = [Container]()
    private var text = ""
    private var result: Any?
    private var failure: Error?
    static func read(_ data: Data) throws -> Any {
        let reader = SignatureXML(), parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.failure == nil, let result = reader.result else {
            throw reader.failure ?? parser.parserError ?? MirrorFailure.invalid("XML workspace illisible")
        }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        if elementName == "dict" || elementName == "array" { stack.append(Container(kind: elementName)) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name == "plist" { return }
        if name == "key" { if !stack.isEmpty { stack[stack.count - 1].key = text }; return }
        let value: Any
        switch name {
        case "dict", "array":
            guard let container = stack.popLast() else { failure = MirrorFailure.invalid("XML invalide : " + name + " / " + text.prefix(100)); parser.abortParsing(); return }
            value = name == "dict" ? container.dictionary : container.array
        case "string": value = text
        case "integer":
            let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int(digits) { value = number }
            else if let number = UInt64(digits) { value = number }
            else { failure = MirrorFailure.invalid("Entier XML invalide : " + digits); parser.abortParsing(); return }
        case "real":
            guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { failure = MirrorFailure.invalid("XML invalide : " + name + " / " + text.prefix(100)); parser.abortParsing(); return }
            value = number.isFinite ? number as Any : ["real": text]
        case "true": value = true
        case "false": value = false
        case "date": value = ["date": text]
        case "data":
            guard let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines), options: [.ignoreUnknownCharacters]) else { failure = MirrorFailure.invalid("XML invalide : " + name + " / " + text.prefix(100)); parser.abortParsing(); return }
            value = bytes
        default: failure = MirrorFailure.invalid("Élément XML workspace inconnu : " + name); parser.abortParsing(); return
        }
        if stack.isEmpty { result = value }
        else if stack[stack.count - 1].kind == "array" { stack[stack.count - 1].array.append(value) }
        else if let key = stack[stack.count - 1].key {
            stack[stack.count - 1].dictionary[key] = value
            stack[stack.count - 1].key = nil
        } else { failure = MirrorFailure.invalid("Clé XML manquante : " + name); parser.abortParsing() }
    }
}
