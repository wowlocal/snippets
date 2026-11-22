-- Close only local fixture pages in the temporary directory supplied by this run.
on run argv
    set rootPath to item 1 of argv
    if rootPath does not start with "/private/tmp/snippets-browser-expansion." and rootPath does not start with "/tmp/snippets-browser-expansion." then error "Unexpected fixture directory"
    if application "Safari" is not running then return
    if rootPath starts with "/private/" then set rootPath to text 9 thru -1 of rootPath
    set base to "file://" & rootPath & "/"
    set canonicalBase to "file:///private" & rootPath & "/"
    repeat 12 times
        set found to false
        tell application "Safari"
            set ids to get id of every window
            repeat with windowID in ids
                set w to window id (windowID as integer)
                set owned to {}
                set otherIndex to missing value
                set n to count of tabs of w
                repeat with i from 1 to n
                    set u to URL of tab i of w
                    if my matchesFixture(u, base, canonicalBase) then
                        set end of owned to i as integer
                    else
                        set otherIndex to i as integer
                    end if
                end repeat
                if (count of owned) > 0 then
                    set found to true
                    if otherIndex is missing value then
                        close w
                    else
                        if my matchesFixture(URL of current tab of w, base, canonicalBase) then set current tab of w to tab otherIndex of w
                        repeat with i in reverse of owned
                            if my matchesFixture(URL of tab i of w, base, canonicalBase) then close tab i of w
                        end repeat
                    end if
                end if
            end repeat
        end tell
        if not found then
            my quitEmptyOwnedSafari(rootPath)
            return
        end if
        delay 0.15
    end repeat
    error "Safari still has a tab for this test run"
end run

on matchesFixture(u, base, canonicalBase)
    if u is missing value then return false
    return ((u starts with base) or (u starts with canonicalBase)) and (u ends with "/fixture.html")
end matchesFixture

on quitEmptyOwnedSafari(rootPath)
    try
        set ownedPID to read POSIX file (rootPath & "/owned-safari-pid") as «class utf8»
    on error
        return
    end try
    if application "Safari" is not running then return
    if (do shell script "/usr/bin/pgrep -x Safari") is not ownedPID then return
    tell application "Safari"
        if (count of windows) is 0 then quit
    end tell
end quitEmptyOwnedSafari
