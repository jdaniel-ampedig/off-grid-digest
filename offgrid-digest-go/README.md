# Off-Grid Digest Go Helper

This is the Go backend for Off-Grid Digest. It reads unread 1-to-1 Messages, missed calls, and the local config file, then sends a digest through Apple Mail.

The Swift menu bar app is the frontend. This Go helper can also be built and run directly from the command line.

## Build

```bash
go mod tidy
go build -o offgrid-digest ./cmd/offgrid-digest
```

## Config Location

The helper reads `config.ini` from the same directory as the executable.

For command-line development from this folder, use the single source config in `../Support Files/config.ini`:

```text
offgrid-digest-go/offgrid-digest
Support Files/config.ini
offgrid-digest-go/OffGridDigest.log
```

For the Swift-installed LaunchAgent:

```text
~/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/offgrid-digest
~/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/config.ini
~/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/OffGridDigest.log
```

## Commands

Print the parsed config from an executable-adjacent config:

```bash
./offgrid-digest --print-config
```

Print the parsed project seed config:

```bash
./offgrid-digest --config "../Support Files/config.ini" --print-config
```

Run once:

```bash
./offgrid-digest --config "../Support Files/config.ini"
```

Dry run, without sending email, marking messages read, or updating state files:

```bash
./offgrid-digest --config "../Support Files/config.ini" --dry-run
```

Watch mode, checking every 60 seconds by default:

```bash
./offgrid-digest --config "../Support Files/config.ini" --watch
```

Watch with a custom interval:

```bash
./offgrid-digest --config "../Support Files/config.ini" --watch --interval=30s
```

Watch dry-run mode:

```bash
./offgrid-digest --config "../Support Files/config.ini" --watch --interval=10s --dry-run
```

## Example Config

```ini
enabled=true
offgridStart=2026-06-21 18:44:19
offgridEnd=2026-08-10 18:46:20
forwardingEmail=josh.daniel@zoleo.com
zoleoNumber=17282215812
senderEmail=josh.daniel@ampedig.com
```

## Logs

The helper writes `OffGridDigest.log` next to the executable.

Command-line development:

```bash
tail -f ./OffGridDigest.log
```

Swift-installed LaunchAgent:

```bash
tail -f "$HOME/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/OffGridDigest.log"
```

## Gemini Key

The helper expects the Gemini API key in Keychain under service `OGD_GEMINI_KEY`:

```bash
security add-generic-password -a "$USER" -s OGD_GEMINI_KEY -w 'YOUR_KEY_HERE' -U
```

## Permissions

The process running this helper needs macOS Full Disk Access to read:

- `~/Library/Messages/chat.db`
- `~/Library/Application Support/CallHistoryDB/...`

During development, grant Full Disk Access to Terminal, VS Code, or Xcode depending on how you run it. For the LaunchAgent path, grant Full Disk Access to the installed `offgrid-digest` binary.

Apple Mail automation permission may be requested the first time a real send happens.

## Sending

Email sending currently uses Apple Mail via a small `osascript` bridge. If SMTP settings are added later, Apple Mail should remain the fallback sender.
