import Foundation

// Uses the installed, documented QLab 5 AppleScript dictionary. Arguments are argv,
// never interpolated into script source. No 'front workspace' targeting.
enum MirrorQLab {
    static let locate = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace absent ou identifiant ambigu"
        set w to item 1 of matches
        if modified of w then save w
        return path of w
      end tell
    end run
    """
    static let check = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace absent ou identifiant ambigu"
        set w to item 1 of matches
        if modified of w then error "Workspace modifié pendant la capture"
        return path of w
      end tell
    end run
    """
    static let currentPath = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace absent ou identifiant ambigu"
        return path of item 1 of matches
      end tell
    end run
    """
    static let idle = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace absent ou identifiant ambigu"
        set w to item 1 of matches
        if (count active cues of w) is not 0 then error "Resynchronisation différée : cues BACKUP actives"
        return path of w
      end tell
    end run
    """
    static let openReceived = """
    on run argv
      set wantedID to item 1 of argv
      set wantedPath to item 2 of argv
      set receivedRoot to (item 3 of argv) & "/"
      set wantedFile to (POSIX file wantedPath) as alias
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is wantedID
        if (count matches) > 1 then error "Plusieurs workspaces avec le même identifiant sont ouverts"
        if (count matches) is 1 then
          set w to item 1 of matches
          if my sameFilePath((get path of w), wantedPath) then return (get path of w)
          if (count active cues of w) is not 0 then error "Fermer les cues actives du BACKUP avant de créer le fallback"
          if not (my pathInsideRoot((get path of w), item 3 of argv)) then error "Autre copie ouverte hors du dossier QLab Fallback : fermer ce workspace puis recréer le fallback"
          -- Preserve the previous received copy before switching documents.
          if modified of w then save w
          close w saving no
        end if
        open wantedFile
        set matches to every workspace whose unique id is wantedID
        if (count matches) is not 1 then error "QLab n'a pas ouvert le workspace reçu"
        if not (my sameFilePath((get path of item 1 of matches), wantedPath)) then error "QLab a ouvert une autre copie"
        return path of item 1 of matches
      end tell
    end run
    on sameFilePath(a, b)
      try
        set fileA to (POSIX file a) as alias
        set fileB to (POSIX file b) as alias
        return fileA is fileB
      on error
        return false
      end try
    end sameFilePath

    on pathInsideRoot(candidate, rootPath)
      set filePath to POSIX path of ((POSIX file candidate) as alias)
      set directoryPath to POSIX path of ((POSIX file rootPath) as alias)
      if directoryPath does not end with "/" then set directoryPath to directoryPath & "/"
      return filePath starts with directoryPath
    end pathInsideRoot

    """
    static let reload = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace absent ou identifiant ambigu"
        set w to item 1 of matches
        if not (my sameFilePath((get path of w), item 2 of argv)) then error "Workspace BACKUP changé avant application"
        if (count active cues of w) is not 0 then error "Resynchronisation différée : cues BACKUP actives"
        close w saving no
        open POSIX file (item 3 of argv)
      end tell
    end run
    on sameFilePath(a, b)
      try
        set fileA to (POSIX file a) as alias
        set fileB to (POSIX file b) as alias
        return fileA is fileB
      on error
        return false
      end try
    end sameFilePath

    """
    static let verify = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace appliqué absent ou ambigu"
        set w to item 1 of matches
        if not (my sameFilePath((get path of w), item 2 of argv)) then error "QLab n'a pas ouvert la version attendue"
        if modified of w then error "Version BACKUP modifiée localement : non synchronisée"
        return path of w
      end tell
    end run
    on sameFilePath(a, b)
      try
        set fileA to (POSIX file a) as alias
        set fileB to (POSIX file b) as alias
        return fileA is fileB
      on error
        return false
      end try
    end sameFilePath

    """
    static let restorePlayhead = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace absent ou ambigu"
        set w to item 1 of matches
        set cueID to item 2 of argv
        set foundCues to every cue of w whose uniqueID is cueID
        if (count foundCues) is not 1 then error "Cue de reprise absente"
        set c to item 1 of foundCues
        set l to parent list of c
        set current cue list of w to l
        set playback position of l to c
        if uniqueID of (playback position of l) is not cueID then error "Playhead non appliqué"
        return cueID
      end tell
    end run
    """
    static let saveExpected = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace absent ou ambigu"
        set w to item 1 of matches
        if not (my sameFilePath((get path of w), item 2 of argv)) then error "Workspace inattendu avant sauvegarde"
        save w
        if modified of w then error "Sauvegarde QLab non terminée"
        return path of w
      end tell
    end run
    on sameFilePath(a, b)
      try
        set fileA to (POSIX file a) as alias
        set fileB to (POSIX file b) as alias
        return fileA is fileB
      on error
        return false
      end try
    end sameFilePath

    """
    static let targets = """
    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace absent ou ambigu"
        set resultText to ""
        repeat with c in cues of item 1 of matches
          set f to missing value
          set f to file target of c
          if f is not missing value then
            set p to POSIX path of f
            if p contains tab or p contains linefeed or p contains return then error "Nom de média non pris en charge"
            set resultText to resultText & (uniqueID of c) & tab & p & linefeed
          end if
        end repeat
        return resultText
      end tell
    end run
    """
    static let relink = """
    on run argv
      -- Materialize file values before doing POSIX coercions. A nested coercion
      -- inside QLab's tell block is dispatched as a remote object specifier (-1700).
      set expectedPath to item 2 of argv
      set n to 3
      repeat while n < count argv
        set cueID to item n of argv
        set targetPath to item (n + 1) of argv
        set targetFile to (POSIX file targetPath) as alias
        tell application id "com.figure53.QLab.5"
          set matches to every workspace whose unique id is item 1 of argv
          if (count matches) is not 1 then error "Workspace absent ou ambigu"
          set w to item 1 of matches
          if not (my sameFilePath((get path of w), expectedPath)) then error "Workspace inattendu pendant relink"
          set foundCues to every cue of w whose uniqueID is cueID
          if (count foundCues) is not 1 then error "Cue média absente ou ambiguë"
          set c to item 1 of foundCues
          set file target of c to targetFile
          set actualFile to get file target of c
        end tell
        if actualFile is missing value then error "Cible média absente après relink : " & cueID
        set actualPath to POSIX path of actualFile
        set expectedResolvedPath to POSIX path of targetFile
        if actualPath is not expectedResolvedPath then error "Cible média non appliquée : " & cueID & " : " & actualPath
        set n to n + 2
      end repeat
      return "relink verified"
    end run
    on sameFilePath(a, b)
      try
        set fileA to (POSIX file a) as alias
        set fileB to (POSIX file b) as alias
        return fileA is fileB
      on error
        return false
      end try
    end sameFilePath

    """

    static let verifyTargets = """
    on run argv
      set expectedPath to item 2 of argv
      set n to 3
      repeat while n < count argv
        set cueID to item n of argv
        set targetFile to (POSIX file (item (n + 1) of argv)) as alias
        tell application id "com.figure53.QLab.5"
          set matches to every workspace whose unique id is item 1 of argv
          if (count matches) is not 1 then error "Workspace absent ou ambigu"
          set w to item 1 of matches
          if not (my sameFilePath((get path of w), expectedPath)) then error "Workspace inattendu pendant vérification des médias"
          set foundCues to every cue of w whose uniqueID is cueID
          if (count foundCues) is not 1 then error "Cue média absente ou ambiguë"
          set actualFile to get file target of item 1 of foundCues
        end tell
        if actualFile is missing value then error "Cible média absente : " & cueID
        set actualPath to POSIX path of actualFile
        set expectedResolvedPath to POSIX path of targetFile
        if actualPath is not expectedResolvedPath then error "Target sauvegardé incorrect : " & cueID & " : " & actualPath
        set n to n + 2
      end repeat
      return "targets verified"
    end run
    on sameFilePath(a, b)
      try
        set fileA to (POSIX file a) as alias
        set fileB to (POSIX file b) as alias
        return fileA is fileB
      on error
        return false
      end try
    end sameFilePath

    """

    static func run(_ script: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // Absolute installed application avoids LaunchServices lookup failures.
            let resolved = script.replacingOccurrences(of: "application id \"com.figure53.QLab.5\"", with: "application \"/Applications/QLab.app\"")
            p.arguments = ["-e", resolved] + arguments
            // File-backed output avoids pipe deadlocks.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let h = try FileHandle(forWritingTo: tmp)
            defer { try? h.close(); try? FileManager.default.removeItem(at: tmp) }
            p.standardOutput = h; p.standardError = h
            try p.run()
            let deadline = Date().addingTimeInterval(20)
            while p.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            if p.isRunning { p.terminate(); throw MirrorFailure.invalid("QLab : délai AppleScript dépassé") }
            let result = String(data: try Data(contentsOf: tmp), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard p.terminationStatus == 0 else { throw MirrorFailure.invalid(result) }
            if [locate, check, idle, verify, openReceived].contains(script), result.hasPrefix("/") {
                return URL(fileURLWithPath: result).resolvingSymlinksInPath().standardizedFileURL.path
            }
            return result
        }.value
    }
}
