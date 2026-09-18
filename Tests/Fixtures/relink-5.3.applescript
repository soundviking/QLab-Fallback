    on run argv
      tell application id "com.figure53.QLab.5"
        set matches to every workspace whose unique id is item 1 of argv
        if (count matches) is not 1 then error "Workspace absent ou ambigu"
        set w to item 1 of matches
        if path of w is not item 2 of argv then error "Workspace inattendu pendant relink"
        set n to 3
        repeat while n < count argv
          set cueID to item n of argv
          set targetPath to item (n + 1) of argv
          set foundCues to every cue of w whose uniqueID is cueID
          if (count foundCues) is not 1 then error "Cue média absente ou ambiguë"
          set c to item 1 of foundCues
          set file target of c to POSIX file targetPath
          if POSIX path of (file target of c) is not targetPath then error "Cible média non appliquée"
          set n to n + 2
        end repeat
      end tell
    end run