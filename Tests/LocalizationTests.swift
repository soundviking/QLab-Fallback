import Foundation

@main struct LocalizationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundle = Bundle(url: root)!
        precondition(L10n.languageCode("system", preferred: ["de-DE"]) == "de")
        precondition(L10n.languageCode("es", preferred: ["fr"]) == "es")
        for language in L10n.supported {
            precondition(L10n.text("PRIMARY", selection: language, resourceBundle: bundle) == "PRIMARY")
            precondition(L10n.text("BACKUP", selection: language, resourceBundle: bundle) == "BACKUP")
            for page in 0..<5 {
                let key = "help.body.\(page)"
                precondition(L10n.text(key, selection: language, resourceBundle: bundle) != key)
            }
        }
        precondition(L10n.text("Aide", selection: "en", resourceBundle: bundle) == "Help")
        precondition(L10n.text("Aide", selection: "de", resourceBundle: bundle) == "Hilfe")
        precondition(L10n.text("Aide", selection: "es", resourceBundle: bundle) == "Ayuda")
        precondition(L10n.text("MY MASTER WORKSPACE", selection: "de", resourceBundle: bundle) == "MY MASTER WORKSPACE")
        print("PASS: Apple catalog, four help languages, automatic/manual selection, PRIMARY/BACKUP and user names preserved")
    }
}
