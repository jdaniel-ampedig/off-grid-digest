package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"

	_ "modernc.org/sqlite"
)

type Config struct {
	Enabled         bool
	OffgridStart    *time.Time
	OffgridEnd      *time.Time
	ForwardingEmail string
	ZoleoNumber     string
	SenderEmail     string
}

type Message struct {
	RowID       int64
	Timestamp   string
	ChatName    string
	Sender      string
	Body        string
	Attachments string
	ABlobHex    string
}

type MissedCall struct {
	CID       int64
	Timestamp string
	Address   string
	Duration  int64
}

type AppPaths struct {
	Home           string
	StateDir       string
	ConfigPath     string
	LogPath        string
	LastRowIDPath  string
	LastCallIDPath string
	MessagesDB     string
}

func main() {
	dryRun := flag.Bool("dry-run", false, "print digest and do not send or mark messages read")
	printConfig := flag.Bool("print-config", false, "print parsed config and exit")
	watch := flag.Bool("watch", false, "keep running and check for messages repeatedly")
	interval := flag.Duration("interval", time.Minute, "check interval when --watch is set")
	configPath := flag.String("config", "", "path to config.ini; defaults to config.ini next to the executable")
	flag.Parse()

	paths, err := defaultPaths()
	if err != nil {
		fatalLog(nil, "failed to get paths: %v", err)
	}
	if *configPath != "" {
		paths.ConfigPath = *configPath
	}

	logger := func(format string, args ...any) {
		logRun(paths.LogPath, format, args...)
	}

	cfg, err := readConfig(paths.ConfigPath)
	if err != nil {
		logger("readConfig error: %v", err)
		cfg = Config{Enabled: true}
	}

	cfg.ZoleoNumber = normalizePhoneNumber(cfg.ZoleoNumber)

	if *printConfig {
		fmt.Printf("ConfigPath=%s\nEnabled=%v\nForwardingEmail=%s\nSenderEmail=%s\nZoleoNumber=%s\nStart=%v\nEnd=%v\n",
			paths.ConfigPath, cfg.Enabled, cfg.ForwardingEmail, cfg.SenderEmail, cfg.ZoleoNumber, cfg.OffgridStart, cfg.OffgridEnd)
		return
	}

	ctx := context.Background()
	if *watch {
		runWatch(ctx, paths, cfg, *dryRun, *interval, logger)
		return
	}

	if err := runOnce(ctx, paths, cfg, *dryRun, logger); err != nil {
		logger("Error: %v", err)
		os.Exit(1)
	}
}

func runWatch(ctx context.Context, paths AppPaths, cfg Config, dryRun bool, interval time.Duration, logf func(string, ...any)) {
	if interval <= 0 {
		interval = time.Minute
	}
	logf("Watch mode starting. interval=%s dryRun=%v", interval, dryRun)
	if dryRun {
		fmt.Printf("Watch mode: checking every %s. Press Ctrl+C to stop.\n", interval)
	}

	for {
		if err := runOnce(ctx, paths, cfg, dryRun, logf); err != nil {
			logf("Error: %v", err)
			if dryRun {
				fmt.Printf("Dry run error: %v\n", err)
			}
		}

		select {
		case <-ctx.Done():
			logf("Watch mode stopping: %v", ctx.Err())
			return
		case <-time.After(interval):
		}
	}
}

func runOnce(ctx context.Context, paths AppPaths, cfg Config, dryRun bool, logf func(string, ...any)) error {
	logf("Run starting. targetEmail=%s senderEmail=%s zoleoNumber=%s", cfg.ForwardingEmail, cfg.SenderEmail, cfg.ZoleoNumber)
	if dryRun {
		fmt.Println("Dry run: no email will be sent, messages will not be marked read, and state files will not be updated.")
		fmt.Printf("Config: targetEmail=%s senderEmail=%s zoleoNumber=%s\n", cfg.ForwardingEmail, cfg.SenderEmail, cfg.ZoleoNumber)
		fmt.Printf("Window: start=%s end=%s\n", fmtTimePtr(cfg.OffgridStart), fmtTimePtr(cfg.OffgridEnd))
	}

	if !cfg.Enabled {
		logf("Disabled via config; skipping run.")
		if dryRun {
			fmt.Println("Dry run: disabled via config; skipping run.")
		}
		return nil
	}

	now := time.Now()
	if !withinWindow(now, cfg.OffgridStart, cfg.OffgridEnd) {
		logf("Outside off-grid window; skipping run. Start=%s End=%s", fmtTimePtr(cfg.OffgridStart), fmtTimePtr(cfg.OffgridEnd))
		if dryRun {
			fmt.Printf("Dry run: outside off-grid window at %s; skipping run.\n", now.Format("2006-01-02 15:04:05"))
		}
		return nil
	}

	if err := os.MkdirAll(paths.StateDir, 0o755); err != nil {
		return err
	}

	lastRowID := readIntFile(paths.LastRowIDPath)
	lastCallID := readIntFile(paths.LastCallIDPath)

	messages, maxRowID, err := fetchUnreadMessages(paths.MessagesDB, lastRowID, cfg.OffgridStart, cfg.OffgridEnd)
	if err != nil {
		logf("Messages query failed: %v", err)
		if dryRun {
			fmt.Printf("Dry run: messages query failed for %s: %v\n", paths.MessagesDB, err)
		}
		messages = nil
		maxRowID = lastRowID
	}
	logf("Messages fetched: %d", len(messages))
	if dryRun {
		fmt.Printf("Messages fetched: %d\n", len(messages))
	}

	var digest strings.Builder
	processedIDs := make([]int64, 0, len(messages))

	for _, msg := range messages {
		body := msg.Body
		if body == "" && msg.ABlobHex != "" {
			body = extractFromAblob(msg.ABlobHex)
			if body == "" {
				body = "[unparsed message]"
			}
		}

		lineText := fmt.Sprintf("%s - %s: %s", msg.Timestamp, msg.Sender, body)

		if cfg.ZoleoNumber != "" && normalizePhoneNumber(msg.Sender) == cfg.ZoleoNumber {
			prompt := "Answer the following question in 160 characters or less. Be direct.\nQuestion: " + body
			aiNote := runGemini(ctx, prompt, logf)
			aiNote = limitText(aiNote, 160)
			if aiNote != "" {
				lineText = fmt.Sprintf("[Q]: %s\n[AI]: %s", body, aiNote)
			}
		}

		if msg.Attachments != "" {
			lineText += "\n    [Attachment: " + msg.Attachments + "]"
		}

		digest.WriteString(lineText)
		digest.WriteString("\n")
		processedIDs = append(processedIDs, msg.RowID)
	}

	callDBPath := findCallDBPath(paths.Home, logf)
	missedCalls := []MissedCall{}
	newMaxCallID := lastCallID
	if callDBPath == "" {
		logf("CallHistory DB not found/readable in known locations. Ensure Full Disk Access & FaceTime call history is available.")
		if dryRun {
			fmt.Println("Dry run: CallHistory DB not found/readable in known locations.")
		}
	} else {
		missedCalls, newMaxCallID, err = fetchMissedCalls(callDBPath, lastCallID, cfg.OffgridStart, cfg.OffgridEnd)
		if err != nil {
			logf("Missed-calls query failed: %v", err)
			if dryRun {
				fmt.Printf("Dry run: missed-calls query failed for %s: %v\n", callDBPath, err)
			}
			missedCalls = nil
			newMaxCallID = lastCallID
		}
		logf("Missed calls fetched: %d", len(missedCalls))
		if dryRun {
			fmt.Printf("Missed calls fetched: %d\n", len(missedCalls))
		}
	}

	if len(messages) == 0 && len(missedCalls) == 0 {
		logf("No unread messages and no missed calls; nothing to send.")
		if dryRun {
			fmt.Println("Dry run: no unread messages and no missed calls; nothing would be sent.")
		}
		return nil
	}

	var body strings.Builder
	body.WriteString(fmt.Sprintf("New unread messages: %d\n\n", len(messages)))
	body.WriteString(digest.String())
	body.WriteString("\n")

	if len(missedCalls) > 0 {
		body.WriteString("Missed calls:\n")
		for _, c := range missedCalls {
			body.WriteString(fmt.Sprintf("  • %s - Missed call from %s (%ds)\n", c.Timestamp, c.Address, c.Duration))
		}
	}

	subject := fmt.Sprintf("Off-Grid Digest (%d message%s", len(messages), pluralSuffix(len(messages)))
	if len(missedCalls) > 0 {
		subject += fmt.Sprintf(", %d missed call%s", len(missedCalls), pluralSuffix(len(missedCalls)))
	}
	subject += ")"

	if dryRun {
		fmt.Println("Subject:", subject)
		fmt.Println("---")
		fmt.Print(body.String())
		logf("Dry run complete; not sending or marking read.")
		return nil
	}

	if cfg.ForwardingEmail == "" {
		return errors.New("forwardingEmail is blank; cannot send digest")
	}

	if err := sendViaAppleMail(cfg.ForwardingEmail, cfg.SenderEmail, subject, body.String()); err != nil {
		return fmt.Errorf("sendViaAppleMail failed: %w", err)
	}
	logf("Email sent.")

	if len(processedIDs) > 0 {
		if err := markMessagesRead(paths.MessagesDB, processedIDs); err != nil {
			logf("Warning: failed to mark messages read: %v", err)
		} else {
			logf("Marked read for %d messages", len(processedIDs))
		}
	}

	if maxRowID > lastRowID {
		if err := writeIntFile(paths.LastRowIDPath, maxRowID); err != nil {
			logf("Warning: failed to write last row id: %v", err)
		}
	}

	if newMaxCallID > lastCallID {
		if err := writeIntFile(paths.LastCallIDPath, newMaxCallID); err != nil {
			logf("Warning: failed to write last call id: %v", err)
		}
	}

	logf("Run complete.")
	return nil
}

func defaultPaths() (AppPaths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return AppPaths{}, err
	}
	exe, err := os.Executable()
	if err != nil {
		return AppPaths{}, err
	}
	exeDir := filepath.Dir(exe)
	stateDir := filepath.Join(home, "Library", "Application Support", "MsgForward")
	return AppPaths{
		Home:           home,
		StateDir:       stateDir,
		ConfigPath:     filepath.Join(exeDir, "config.ini"),
		LogPath:        filepath.Join(exeDir, "OffGridDigest.log"),
		LastRowIDPath:  filepath.Join(stateDir, "last_rowid.txt"),
		LastCallIDPath: filepath.Join(stateDir, "auto_last_callid.txt"),
		MessagesDB:     filepath.Join(home, "Library", "Messages", "chat.db"),
	}, nil
}

func readConfig(path string) (Config, error) {
	cfg := Config{Enabled: true}
	b, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}

	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.ToLower(strings.TrimSpace(k))
		v = strings.TrimSpace(v)
		v = strings.TrimSuffix(v, "%")

		switch k {
		case "enabled":
			vl := strings.ToLower(v)
			cfg.Enabled = vl == "true" || vl == "1" || vl == "yes"
		case "offgridstart":
			cfg.OffgridStart = parseLocalConfigTimePtr(v)
		case "offgridend":
			cfg.OffgridEnd = parseLocalConfigTimePtr(v)
		case "forwardingemail":
			cfg.ForwardingEmail = v
		case "zoleonumber":
			cfg.ZoleoNumber = v
		case "senderemail":
			cfg.SenderEmail = v
		}
	}
	return cfg, nil
}

func parseLocalConfigTimePtr(s string) *time.Time {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	t, err := time.ParseInLocation("2006-01-02 15:04:05", s, time.Local)
	if err != nil {
		return nil
	}
	return &t
}

func fmtTimePtr(t *time.Time) string {
	if t == nil {
		return ""
	}
	return t.Format("2006-01-02 15:04:05")
}

func withinWindow(now time.Time, start, end *time.Time) bool {
	if start != nil && now.Before(*start) {
		return false
	}
	if end != nil && now.After(*end) {
		return false
	}
	return true
}

func fetchUnreadMessages(dbPath string, lastID int64, start, end *time.Time) ([]Message, int64, error) {
	db, err := sql.Open("sqlite", sqliteURI(dbPath, "ro"))
	if err != nil {
		return nil, lastID, err
	}
	defer db.Close()

	args := []any{lastID}
	timePred := ""
	if start != nil {
		timePred += " AND ((m.date/1000000000) + 978307200) >= ?"
		args = append(args, start.Unix())
	}
	if end != nil {
		timePred += " AND ((m.date/1000000000) + 978307200) <= ?"
		args = append(args, end.Unix())
	}

	query := `
WITH msgs AS (
  SELECT
    m.ROWID AS rid,
    strftime('%Y-%m-%d %H:%M:%S', (m.date/1000000000) + 978307200, 'unixepoch','localtime') AS ts,
    COALESCE(c.display_name, c.chat_identifier, 'Unknown Chat') AS chatname,
    COALESCE(h.id, 'Unknown') AS sender,
    REPLACE(COALESCE(NULLIF(m.text,''), ''), char(10), '⏎') AS body,
    COALESCE((
      SELECT GROUP_CONCAT(
        COALESCE(a.transfer_name, a.filename, 'file')
        || CASE WHEN a.mime_type IS NOT NULL AND a.mime_type <> '' THEN ' (' || a.mime_type || ')' ELSE '' END,
        ', '
      )
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = m.ROWID
    ), '') AS attachments,
    HEX(m.attributedBody) AS ablob
  FROM message m
  LEFT JOIN handle h         ON h.ROWID = m.handle_id
  JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
  JOIN chat c                ON c.ROWID = cmj.chat_id
  WHERE m.is_from_me = 0
    AND m.is_read = 0
    AND m.ROWID > ?
    AND (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) = 1
` + timePred + `
)
SELECT rid, ts, chatname, sender, body, attachments, ablob
FROM msgs
ORDER BY rid ASC
LIMIT 500;
`

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, lastID, err
	}
	defer rows.Close()

	out := []Message{}
	maxID := lastID
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.RowID, &m.Timestamp, &m.ChatName, &m.Sender, &m.Body, &m.Attachments, &m.ABlobHex); err != nil {
			return out, maxID, err
		}
		if m.RowID > maxID {
			maxID = m.RowID
		}
		out = append(out, m)
	}
	return out, maxID, rows.Err()
}

func markMessagesRead(dbPath string, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	db, err := sql.Open("sqlite", sqliteURI(dbPath, "rw"))
	if err != nil {
		return err
	}
	defer db.Close()

	placeholders := make([]string, len(ids))
	args := make([]any, len(ids))
	for i, id := range ids {
		placeholders[i] = "?"
		args[i] = id
	}

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	_, err = tx.Exec("UPDATE message SET is_read = 1 WHERE ROWID IN ("+strings.Join(placeholders, ",")+")", args...)
	if err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

func findCallDBPath(home string, logf func(string, ...any)) string {
	candidates := []string{
		filepath.Join(home, "Library", "Application Support", "CallHistoryDB", "CallHistory.storedata"),
		filepath.Join(home, "Library", "Application Support", "CallHistoryDB", "CallHistoryV2.sqlite"),
		filepath.Join(home, "Library", "Application Support", "CallHistoryTransactions", "CallHistory.storedata"),
		filepath.Join(home, "Library", "Application Support", "com.apple.CallHistoryDB", "CallHistory.storedata"),
	}

	for _, p := range candidates {
		st, err := os.Stat(p)
		if err != nil || st.Size() == 0 {
			if logf != nil {
				logf("findCallDBPath: not found or empty -> %s", p)
			}
			continue
		}

		db, err := sql.Open("sqlite", sqliteURI(p, "ro"))
		if err != nil {
			if logf != nil {
				logf("findCallDBPath: open failed for %s: %v", p, err)
			}
			continue
		}
		var schemaVersion int
		err = db.QueryRow("PRAGMA schema_version;").Scan(&schemaVersion)
		_ = db.Close()
		if err == nil {
			if logf != nil {
				logf("findCallDBPath: using -> %s", p)
			}
			return p
		}
		if logf != nil {
			logf("findCallDBPath: sqlite probe failed for %s: %v", p, err)
		}
	}

	return ""
}

func fetchMissedCalls(dbPath string, lastCID int64, start, end *time.Time) ([]MissedCall, int64, error) {
	db, err := sql.Open("sqlite", sqliteURI(dbPath, "ro"))
	if err != nil {
		return nil, lastCID, err
	}
	defer db.Close()

	args := []any{lastCID}
	timePred := ""
	if start != nil {
		timePred += " AND (zdate + 978307200) >= ?"
		args = append(args, start.Unix())
	}
	if end != nil {
		timePred += " AND (zdate + 978307200) <= ?"
		args = append(args, end.Unix())
	}

	query := `
WITH rec AS (
  SELECT
    zr.Z_PK AS cid,
    strftime('%Y-%m-%d %H:%M:%S', zr.ZDATE + 978307200, 'unixepoch','localtime') AS ts,
    COALESCE(zr.ZADDRESS, '') AS addr,
    zr.ZANSWERED AS answered,
    zr.ZORIGINATED AS originated,
    COALESCE(zr.ZDURATION,0) AS dur,
    zr.ZDATE AS zdate
  FROM ZCALLRECORD zr
)
SELECT cid, ts, addr, dur
FROM rec
WHERE cid > ?
  AND originated = 0
  AND answered = 0
` + timePred + `
ORDER BY cid ASC
LIMIT 200;
`

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, lastCID, err
	}
	defer rows.Close()

	out := []MissedCall{}
	maxCID := lastCID
	for rows.Next() {
		var c MissedCall
		if err := rows.Scan(&c.CID, &c.Timestamp, &c.Address, &c.Duration); err != nil {
			return out, maxCID, err
		}
		if c.CID > maxCID {
			maxCID = c.CID
		}
		out = append(out, c)
	}
	return out, maxCID, rows.Err()
}

func sqliteURI(path string, mode string) string {
	u := url.URL{Scheme: "file", Path: path}
	q := u.Query()
	q.Set("mode", mode)
	q.Set("_pragma", "query_only(1)")
	if mode == "rw" {
		q.Del("_pragma")
	}
	u.RawQuery = q.Encode()
	return u.String()
}

func runGemini(ctx context.Context, prompt string, logf func(string, ...any)) string {
	apiKey, err := keychainPassword("OGD_GEMINI_KEY")
	if err != nil || apiKey == "" {
		logf("Gemini skipped: keychain service OGD_GEMINI_KEY not found: %v", err)
		return ""
	}

	modelName := "gemini-2.5-flash"
	endpoint := "https://generativelanguage.googleapis.com/v1beta/models/" + modelName + ":generateContent?key=" + url.QueryEscape(apiKey)

	payload := map[string]any{
		"contents": []map[string]any{
			{"parts": []map[string]string{{"text": prompt}}},
		},
	}
	b, _ := json.Marshal(payload)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(b))
	if err != nil {
		logf("Gemini request build failed: %v", err)
		return ""
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 20 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		logf("Gemini HTTP failed: %v", err)
		return ""
	}
	defer res.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		logf("Gemini bad status %d: %s", res.StatusCode, string(body))
		return ""
	}

	var parsed struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text string `json:"text"`
				} `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
		PromptFeedback struct {
			BlockReason string `json:"blockReason"`
		} `json:"promptFeedback"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		logf("Gemini JSON parse failed: %v", err)
		return ""
	}
	if len(parsed.Candidates) == 0 {
		if parsed.PromptFeedback.BlockReason != "" {
			return "[Blocked: " + parsed.PromptFeedback.BlockReason + "]"
		}
		return ""
	}
	var parts []string
	for _, p := range parsed.Candidates[0].Content.Parts {
		if strings.TrimSpace(p.Text) != "" {
			parts = append(parts, strings.TrimSpace(p.Text))
		}
	}
	return strings.Join(parts, "\n\n")
}

func keychainPassword(service string) (string, error) {
	cmd := exec.Command("/usr/bin/security", "find-generic-password", "-w", "-s", service)
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func sendViaAppleMail(to, sender, subject, content string) error {
	script := `
on run argv
    set targetEmail to item 1 of argv
    set senderEmail to item 2 of argv
    set subjectStr to item 3 of argv
    set contentStr to item 4 of argv

    tell application "Mail"
        set theMessage to make new outgoing message with properties {visible:false, subject:subjectStr, content:contentStr}
        if senderEmail is not "" then
            set sender of theMessage to senderEmail
        end if
        tell theMessage to make new to recipient at end of to recipients with properties {address:targetEmail}
        send theMessage
    end tell
end run
`
	cmd := exec.Command("/usr/bin/osascript", "-e", script, to, sender, subject, content)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func extractFromAblob(hexstr string) string {
	hexstr = strings.TrimSpace(strings.ReplaceAll(hexstr, "\n", ""))
	if hexstr == "" {
		return ""
	}
	b, err := hex.DecodeString(hexstr)
	if err != nil {
		return ""
	}

	candidates := printableRuns(b)
	best := ""
	for _, s := range candidates {
		s = strings.TrimSpace(s)
		if s == "" || isFrameworkNoise(s) {
			continue
		}
		if len([]rune(s)) > len([]rune(best)) {
			best = s
		}
	}
	return best
}

func printableRuns(b []byte) []string {
	var out []string
	var cur []rune
	flush := func() {
		if len(cur) >= 2 {
			out = append(out, string(cur))
		}
		cur = nil
	}

	for _, x := range b {
		r := rune(x)
		if r == '\n' || r == '\r' || r == '\t' || (r >= 32 && r <= 126) || unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.IsPunct(r) || unicode.IsSpace(r) {
			cur = append(cur, r)
		} else {
			flush()
		}
	}
	flush()
	return out
}

func isFrameworkNoise(s string) bool {
	prefixes := []string{"NS", "CF", "__kIM", "archiver", "objects", "keys", "public.", "com.apple.", "streamtyped"}
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

func normalizePhoneNumber(raw string) string {
	var b strings.Builder
	for _, r := range raw {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	d := b.String()
	if len(d) >= 10 {
		return d[len(d)-10:]
	}
	return d
}

func limitText(s string, max int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) <= max {
		return string(r)
	}
	if max <= 1 {
		return string(r[:max])
	}
	return string(r[:max-1]) + "…"
}

func readIntFile(path string) int64 {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func writeIntFile(path string, n int64) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(fmt.Sprintf("%d\n", n)), 0o644)
}

func logRun(logPath string, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	_ = os.MkdirAll(filepath.Dir(logPath), 0o755)
	line := fmt.Sprintf("%s - %s\n", time.Now().Format("2006-01-02 15:04:05"), msg)
	fmt.Print(line)
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprint(os.Stderr, line)
		return
	}
	defer f.Close()
	_, _ = f.WriteString(line)
}

func fatalLog(logPath *string, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	if logPath != nil {
		logRun(*logPath, "%s", msg)
	}
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(1)
}

func pluralSuffix(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
