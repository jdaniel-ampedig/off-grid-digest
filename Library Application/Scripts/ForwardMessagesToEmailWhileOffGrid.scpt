-- ForwardMessagesToEmailWhileOffGrid.scpt
-- Unread-only, 1:1 chats only (exclude groups), marks read after send, bundles by conversation.
-- Runs only during a user-defined off-grid window.
-- Includes fallback extraction from attributedBody for modern iMessages.

use AppleScript version "2.8"
use scripting additions

property stateDir : POSIX path of (path to library folder from user domain) & "Application Support/MsgForward/"
property stateFile : stateDir & "last_rowid.txt"

property callStateFile : stateDir & "auto_last_callid.txt"
property callDBPath : POSIX path of (path to library folder from user domain) & "Application Support/CallHistoryDB/CallHistory.storedata"

property offgridStart : ""
property offgridEnd   : ""
property targetEmail : "segfault31@yahoo.com"

-- =========================
-- Config reader
-- Returns {enabled:boolean, startStr:text, endStr:text, emailStr:text}
on readConfig()
    try
        -- Candidate paths (container first, then normal Library)
        set contPath to POSIX path of (path to library folder from user domain) & "Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/config.ini"
        set userPath to POSIX path of (path to library folder from user domain) & "Application Support/MsgForward/config.ini"

        -- Pick the first that exists AND is non-empty
        set cfgPath to ""
        if (do shell script "/usr/bin/test -s " & quoted form of contPath & " ; echo $?") is "0" then
            set cfgPath to contPath
        else if (do shell script "/usr/bin/test -s " & quoted form of userPath & " ; echo $?") is "0" then
            set cfgPath to userPath
        end if

-- TODO remove below and fix above to detect the correct file
set cfgPath to contPath

        my logRun("readConfig: using cfgPath -> " & cfgPath)
        if cfgPath is "" then return {true, "", "", ""}

        -- Read file and normalize CR to LF
        set raw to do shell script "/bin/cat " & quoted form of cfgPath
        set raw to my replaceText(raw, return, linefeed)

        -- Defaults
        set enabledStr to ""
        set startStr to ""
        set endStr to ""
        set emailStr to ""

        -- Split into lines
        set oldTID to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set rows to text items of raw
        set AppleScript's text item delimiters to oldTID

        repeat with ln in rows
            set lineText to my trimBoth(ln as text)
            if lineText is "" then
                -- skip blank
            else if my startsWith(lineText, "#") then
                -- skip comment
            else
                set eqPos to offset of "=" in lineText
                if eqPos > 0 then
                    set k to my trimBoth(text 1 thru (eqPos - 1) of lineText)
                    set v to my trimBoth(text (eqPos + 1) thru -1 of lineText)
                    -- strip trailing % if present
                    if v ends with "%" then set v to text 1 thru -2 of v
                    -- case-insensitive keys
                    if my iequals(k, "enabled") then
                        set enabledStr to v
                    else if my iequals(k, "offgridStart") then
                        set startStr to v
                    else if my iequals(k, "offgridEnd") then
                        set endStr to v
                    else if my iequals(k, "forwardingEmail") then
                        set emailStr to v
                    end if
                end if
            end if
        end repeat

        -- enabled defaults to true if not present
        set enabledBool to true
        if enabledStr is not "" then
            if my iequals(enabledStr, "true") or my iequals(enabledStr, "1") or my iequals(enabledStr, "yes") then
                set enabledBool to true
            else
                set enabledBool to false
            end if
        end if

        my logRun("readConfig: enabled=" & (enabledBool as text) & " startStr=" & startStr & " endStr=" & endStr & " forwardingEmail=" & emailStr)
        return {enabledBool, startStr, endStr, emailStr}

    on error errMsg number errNum
        my logRun("readConfig error " & (errNum as text) & ": " & errMsg)
        return {true, "", "", ""}
    end try
end readConfig

on writeLastCallID(n)
    do shell script "/bin/echo " & (n as text) & " > " & quoted form of callStateFile
end writeLastCallID

-- =========================
-- Missed calls
on fetchMissedCallsSince(lastCID)
    try
        set sql1 to "
WITH rec AS (
  SELECT
    zr.Z_PK AS cid,
    strftime('%Y-%m-%d %H:%M:%S', zr.ZDATE + 978307200, 'unixepoch','localtime') AS ts,
    COALESCE(zr.ZADDRESS, '') AS addr,
    zr.ZANSWERED AS answered,
    zr.ZORIGINATED AS originated,
    COALESCE(zr.ZDURATION,0) AS dur
  FROM ZCALLRECORD zr
)
SELECT cid, ts, addr, dur
FROM rec
WHERE cid > " & lastCID & " AND originated = 0 AND answered = 0
ORDER BY cid ASC
LIMIT 200;
"
        set cmd to "/usr/bin/sqlite3 -separator ' || ' " & quoted form of callDBPath & " " & quoted form of sql1
        set raw to do shell script cmd
        if raw is "" then return {{}, lastCID} -- none

        set AppleScript's text item delimiters to linefeed
        set rows to text items of raw
        set itemsOut to {}
        set maxCID to lastCID

        repeat with r in rows
            if r is not "" then
                set AppleScript's text item delimiters to " || "
                set cols to text items of r
                if (count of cols) ≥ 4 then
                    set cid to (item 1 of cols) as integer
                    set ts to item 2 of cols
                    set addr to item 3 of cols
                    set dur to item 4 of cols
                    if cid > maxCID then set maxCID to cid
                    set end of itemsOut to (ts & " - Missed call from " & addr & " (" & dur & "s)")
                end if
            end if
        end repeat

        return {itemsOut, maxCID}

    on error errMsg number errNum
        my logRun("Missed-calls query failed (" & errNum & "): " & errMsg)
        return {{}, lastCID}
    end try
end fetchMissedCallsSince


-- Returns the first existing & readable Call History DB path (or "")
on findCallDBPath()
    try
        set base to POSIX path of (path to library folder from user domain)
        set candidates to { ¬
            base & "Application Support/CallHistoryDB/CallHistory.storedata", ¬
            base & "Application Support/CallHistoryDB/CallHistoryV2.sqlite", ¬
            base & "Application Support/CallHistoryTransactions/CallHistory.storedata", ¬
            base & "Application Support/com.apple.CallHistoryDB/CallHistory.storedata" ¬
            }
        repeat with p in candidates
            set pp to p as text
            -- must exist, be non-empty, and readable
            if (do shell script "/usr/bin/test -s " & quoted form of pp & " ; echo $?") is "0" then
                if (do shell script "/usr/bin/test -r " & quoted form of pp & " ; echo $?") is "0" then
                    -- quick read-only probe (prints nothing, returns 0 if ok)
                    try
                        do shell script "/usr/bin/sqlite3 -readonly " & quoted form of pp & " 'PRAGMA schema_version;' >/dev/null"
                        return pp
                    end try
                end if
            end if
        end repeat
    on error errMsg number errNum
        my logRun("findCallDBPath error " & errNum & ": " & errMsg)
    end try
    return ""
end findCallDBPath

-- =========================
-- Main
on run
    set cfg to my readConfig()
    set isEnabled to item 1 of cfg
    set cfgStart to item 2 of cfg
    set cfgEnd to item 3 of cfg
    set cfgEmail to item 4 of cfg

    if cfgStart is not "" then set offgridStart to cfgStart
    if cfgEnd is not "" then set offgridEnd to cfgEnd
    if cfgEmail is not "" then set targetEmail to cfgEmail

    if isEnabled is false then
        my logRun("Disabled via config; skipping run.")
        return
    end if

    try
        -- Window gate
        set nowEpoch to (do shell script "date +%s") as integer
        if my isWithinWindow(nowEpoch, offgridStart, offgridEnd) is false then
            my logRun("Outside off-grid window; skipping run. Start=" & offgridStart & " End=" & offgridEnd)
            return
        end if

        -- State + DB
        my ensureStateFile()
        set lastID to my readLastID()
        set dbPath to POSIX path of (path to library folder from user domain) & "Messages/chat.db"

        -- SQL: normalize newlines in m.text and include HEX(attributedBody) as fallback.
        set sql to "
WITH msgs AS (
  SELECT
    m.ROWID AS rid,
    strftime('%Y-%m-%d %H:%M:%S',
      (m.date/1000000000) + 978307200,
      'unixepoch','localtime'
    ) AS ts,
    COALESCE(c.display_name, c.chat_identifier, 'Unknown Chat') AS chatname,
    COALESCE(h.id, 'Unknown') AS sender,
    REPLACE(COALESCE(NULLIF(m.text,''), ''), char(10), '⏎') AS body,
    COALESCE((
      SELECT GROUP_CONCAT(
               COALESCE(a.transfer_name, a.filename, 'file')
               || CASE WHEN a.mime_type IS NOT NULL AND a.mime_type <> '' THEN ' (' || a.mime_type || ')' ELSE '' END
               , ', '
             )
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = m.ROWID
    ), '') AS attachments,
    HEX(m.attributedBody) AS ablob
  FROM message m
  LEFT JOIN handle h             ON h.ROWID = m.handle_id
  JOIN chat_message_join cmj     ON cmj.message_id = m.ROWID
  JOIN chat c                    ON c.ROWID = cmj.chat_id
  WHERE m.is_from_me = 0
    AND m.is_read = 0
    AND m.ROWID > " & lastID & "
    AND (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) = 1
)
SELECT rid, ts, chatname, sender, body, attachments, ablob
FROM msgs
ORDER BY rid ASC
LIMIT 500;
"

        set cmd to "/usr/bin/sqlite3 -separator ' || ' " & quoted form of dbPath & " " & quoted form of sql
        set raw to do shell script cmd

        -- If no unread messages, try "missed calls only" path
        if raw is "" then
            my logRun("No unread 1:1 messages; checking missed calls (within window)")

            set headerLine to "New unread 1:1 messages: 0 across 0 conversations" & return & return
            set bodyText to headerLine

            -- Missed calls section
            my ensureCallState()
            set lastCID to my readLastCallID()

            if (do shell script "[ -r " & quoted form of callDBPath & " ] && echo 0 || echo 1") is "0" then
                set mc to my fetchMissedCallsSince(lastCID)
                set missedList to item 1 of mc
                set newMaxCID to item 2 of mc

                if (count of missedList) > 0 then
                    set bodyText to bodyText & "Missed calls:" & return
                    repeat with ln in missedList
                        set bodyText to bodyText & "  • " & (ln as text) & return
                    end repeat
                    my writeLastCallID(newMaxCID)

                    if targetEmail is "" then
                        my logRun("No targetEmail configured; skipping send.")
                        return
                    end if

                    set subjectStr to "Off Grid Digest (Missed calls only: " & (count of missedList) & ")"
                    set contentStr to bodyText & return

                    tell application "Mail"
                        set theMessage to make new outgoing message with properties {visible:false, subject:subjectStr, content:contentStr}
                        tell theMessage to make new to recipient at end of to recipients with properties {address:targetEmail}
                        send theMessage
                    end tell
                else
                    my logRun("No unread 1:1 messages and no missed calls (within window)")
                end if
            else
                my logRun("CallHistory DB not readable at: " & callDBPath)
            end if

            return
        end if

        -- Parse and bundle by conversation
        set AppleScript's text item delimiters to linefeed
        set rows to text items of raw

        set convNames to {}
        set convBlobs to {}
        set totalCount to 0
        set maxID to lastID
        set processedIDs to {}

        repeat with r in rows
            if r is not "" then
                set AppleScript's text item delimiters to " || "
                set cols to text items of r
                if (count of cols) ≥ 7 then
                    set rid to (item 1 of cols) as integer
                    set ts to item 2 of cols
                    set chatname to item 3 of cols
                    set sender to item 4 of cols
                    set body to item 5 of cols
                    set attachments to item 6 of cols
                    set ablob to item 7 of cols

                    -- Fallback to attributedBody if needed
                    if body is "" and ablob is not "" then
                        set fb to my extractFromAblob(ablob)
                        if fb is not "" then
                            set body to fb
                        else
                            set body to "[unparsed message]"
                        end if
                    end if

                    set lineText to ts & " - " & sender & ": " & body
                    if attachments is not "" then
                        set lineText to lineText & return & "    [Attachment: " & attachments & "]"
                    end if

                    set idx to my indexOfItem(chatname, convNames)
                    if idx = 0 then
                        set end of convNames to chatname
                        set end of convBlobs to lineText
                    else
                        set existing to item idx of convBlobs
                        set item idx of convBlobs to existing & return & lineText
                    end if

                    set totalCount to totalCount + 1
                    if rid > maxID then set maxID to rid
                    set end of processedIDs to rid
                end if
            end if
        end repeat

        -- Build email
        set headerLine to "New unread 1:1 messages: " & totalCount & " across " & (count of convNames) & " conversation" & (my pluralSuffix(count of convNames)) & return & return
        set bodyText to headerLine
        repeat with i from 1 to (count of convNames)
            set cname to item i of convNames
            set cblob to item i of convBlobs
            set bodyText to bodyText & "-- Conversation: " & cname & return & cblob & return & return
        end repeat
        set subjectStr to "Off Grid Digest Messages (" & totalCount & ") in " & (count of convNames) & " Conversation" & (my pluralSuffix(count of convNames))
        set contentStr to bodyText & return

        -- Missed calls section (append and add subject suffix)
        -- Missed calls section
        my ensureCallState()
        set lastCID to my readLastCallID()

        set callDBPath to my findCallDBPath()
do shell script "/usr/bin/whoami" --> capture and log this
my logRun("whoami=" & (result as text) & " callDBPath=" & callDBPath)

        set callDBPath to "$HOME/Library/Application Support/CallHistoryDB/CallHistory.storedata"

        if callDBPath is "" then
            my logRun("CallHistory DB not found/readable in known locations. Ensure Full Disk Access & FaceTime call history is available.")
        else
             if (do shell script "[ -r " & quoted form of callDBPath & " ] && echo 0 || echo 1") is "0" then
                set mc to my fetchMissedCallsSince(lastCID)
                set missedList to item 1 of mc
                set newMaxCID to item 2 of mc
                if (count of missedList) > 0 then
                    set contentStr to contentStr & "Missed calls:" & return
                    repeat with ln in missedList
                        set contentStr to contentStr & "  • " & (ln as text) & return
                    end repeat
                    my writeLastCallID(newMaxCID)
                else
                    my logRun("No new missed calls")
                end if
             else
               my logRun("CallHistory DB not readable at: " & callDBPath)
             end if
        end if

        -- If nothing to send, exit quietly
        if totalCount = 0 and (contentStr is headerLine & return) then
            my logRun("Parsed 0 rows after query - nothing to send (within window; likely group-only)")
            return
        end if

        -- Guard email address
        if targetEmail is "" then
            my logRun("No targetEmail configured; skipping send.")
            return
        end if

        -- Send via Mail
        tell application "Mail"
            set theMessage to make new outgoing message with properties {visible:false, subject:subjectStr, content:contentStr}
            tell theMessage to make new to recipient at end of to recipients with properties {address:targetEmail}
            send theMessage
        end tell

        -- Mark processed messages as read
        try
            set idsCSV to my listToCSV(processedIDs)
            if idsCSV is not "" then
                set upd to "BEGIN TRANSACTION; UPDATE message SET is_read = 1 WHERE ROWID IN (" & idsCSV & "); COMMIT;"
                do shell script "/usr/bin/sqlite3 " & quoted form of dbPath & " " & quoted form of upd
            end if
            my logRun("Marked read for " & (count of processedIDs) as text & " messages")
        on error errMsg number errNum
            my logRun("Warning: failed to mark messages read (" & errNum & "): " & errMsg)
        end try

        -- Persist last processed message id
        my writeLastID(maxID)

    on error errMsg number errNum
        my logRun("Error " & errNum & ": " & errMsg)
        do shell script "/usr/bin/logger -t ForwardMessagesToEmail 'Error " & errNum & ": " & my shQuote(errMsg) & "'"
    end try

    my logRun("Run complete")
end run

-- =========================
-- Helpers
on extractFromAblob(hexstr)
    if hexstr is "" then return ""
    -- Phase 1: decode → plutil → pick longest quoted string that's not framework noise
    try
        set cmd1 to "/usr/bin/printf %s " & quoted form of hexstr & " | " & ¬
            "/usr/bin/tr -d '\\n ' | /usr/bin/xxd -r -p | " & ¬
            "/usr/bin/plutil -p - 2>/dev/null | " & ¬
            "/usr/bin/awk -F '\"' 'BEGIN{IGNORECASE=1} " & ¬
                "{for(i=2;i<=NF;i+=2){s=$i; " & ¬
                " if(s!~/^(NS|CF|__kIM|archiver|objects|keys|public\\.|com\\.apple\\.|streamtyped)$/ && " & ¬
                "    s!~/^(NS|CF)[A-Za-z0-9_.-]+$/ && s!~/^[[:space:]]*$/) print length(s) \"\\t\" s}}' | " & ¬
            "/usr/bin/sort -nr | /usr/bin/head -n1 | /usr/bin/cut -f2-"
        set out1 to do shell script cmd1
        if out1 is not "" then return out1
    end try

    -- Phase 2: strings with filters; choose longest human-looking line
    try
        set cmd2 to "/usr/bin/printf %s " & quoted form of hexstr & " | " & ¬
            "/usr/bin/tr -d '\\n ' | /usr/bin/xxd -r -p | /usr/bin/strings - | " & ¬
            "/usr/bin/awk 'BEGIN{IGNORECASE=1} " & ¬
                "$0!~/^(NS|CF|__kIM|archiver|streamtyped|public\\.|com\\.apple\\.)/ && " & ¬
                "$0!~/^(NS|CF)[A-Za-z0-9_.-]+$/ && $0!~/^[[:space:]]*$/ { print length($0) \"\\t\" $0 }' | " & ¬
            "/usr/bin/sort -nr | /usr/bin/head -n1 | /usr/bin/cut -f2-"
        set out2 to do shell script cmd2
        if out2 is not "" then return out2
    end try

    -- Phase 3: absolute fallback—return the longest printable token (no filters)
    try
        set cmd3 to "/usr/bin/printf %s " & quoted form of hexstr & " | " & ¬
            "/usr/bin/tr -d '\\n ' | /usr/bin/xxd -r -p | /usr/bin/strings - | " & ¬
            "/usr/bin/awk '{ print length($0) \"\\t\" $0 }' | /usr/bin/sort -nr | /usr/bin/head -n1 | /usr/bin/cut -f2-"
        return do shell script cmd3
    on error
        return ""
    end try
end extractFromAblob

on isWithinWindow(nowEpoch, startStr, endStr)
    try
        set startOK to true
        set endOK to true
        if startStr is not "" then
            set startEpoch to (do shell script "/bin/date -j -f '%Y-%m-%d %H:%M:%S' " & quoted form of startStr & " +%s") as integer
            if nowEpoch < startEpoch then set startOK to false
        end if
        if endStr is not "" then
            set endEpoch to (do shell script "/bin/date -j -f '%Y-%m-%d %H:%M:%S' " & quoted form of endStr & " +%s") as integer
            if nowEpoch > endEpoch then set endOK to false
        end if
        return (startOK and endOK)
    on error errMsg number errNum
        my logRun("Window parse error (" & errNum & "): " & errMsg & " - allowing run by default")
        return true
    end try
end isWithinWindow

on ensureStateFile()
    do shell script "/bin/mkdir -p " & quoted form of stateDir & " ; /usr/bin/touch " & quoted form of stateFile
    if (do shell script "/usr/bin/test -s " & quoted form of stateFile & " ; echo $?") is "1" then
        do shell script "/bin/echo 0 > " & quoted form of stateFile
    end if
end ensureStateFile

on readLastID()
    try
        return (do shell script "/bin/cat " & quoted form of stateFile) as integer
    on error
        return 0
    end try
end readLastID

on readLastCallID()
    try
        return (do shell script "/bin/cat " & quoted form of callStateFile) as integer
    on error
        return 0
    end try
end readLastCallID


on writeLastID(n)
    do shell script "/bin/echo " & (n as text) & " > " & quoted form of stateFile
end writeLastID

on indexOfItem(x, L)
    repeat with i from 1 to (count of L)
        if item i of L is x then return i
    end repeat
    return 0
end indexOfItem

on listToCSV(L)
    if (count of L) = 0 then return ""
    set AppleScript's text item delimiters to ","
    return (L as text)
end listToCSV

on pluralSuffix(n)
    if n = 1 then return ""
    return "s"
end pluralSuffix

on shQuote(t)
    return "'" & (do shell script "/usr/bin/printf %s " & quoted form of t) & "'"
end shQuote

on logRun(msg)
    set logsDir to POSIX path of (path to library folder from user domain) & "Logs/"
    do shell script "/bin/mkdir -p " & quoted form of logsDir
    set logFile to logsDir & "ForwardMessages.log"
    set ts to do shell script "date '+%Y-%m-%d %H:%M:%S'"
    do shell script "/bin/echo " & quoted form of (ts & " - " & msg) & " >> " & quoted form of logFile
end logRun


on replaceText(theText, findStr, replStr)
    set oldTID to AppleScript's text item delimiters
    set AppleScript's text item delimiters to findStr
    set parts to every text item of theText
    set AppleScript's text item delimiters to replStr
    set out to parts as text
    set AppleScript's text item delimiters to oldTID
    return out
end replaceText

on trimBoth(t)
    set s to (t as text)
    -- trim leading spaces/tabs
    repeat while (s starts with " " or s starts with tab)
        if s = "" then exit repeat
        set s to text 2 thru -1 of s
    end repeat
    -- trim trailing spaces/tabs
    repeat while (s ends with " " or s ends with tab)
        if s = "" then exit repeat
        set s to text 1 thru -2 of s
    end repeat
    return s
end trimBoth

on startsWith(t, prefix)
    try
        return (text 1 thru (length of prefix) of t) is prefix
    on error
        return false
    end try
end startsWith

on iequals(a, b)
    ignoring case
        return (a as text) is (b as text)
    end ignoring
end iequals

on ensureCallState()
    do shell script "/bin/mkdir -p " & quoted form of stateDir & " ; /usr/bin/touch " & quoted form of callStateFile
    if (do shell script "/usr/bin/test -s " & quoted form of callStateFile & " ; echo $?") is "1" then
        do shell script "/bin/echo 0 > " & quoted form of callStateFile
    end if
end ensureCallState


