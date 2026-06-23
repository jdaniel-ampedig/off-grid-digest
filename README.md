# Off-Grid Digest for macOS

Off-Grid Digest is a lightweight macOS utility that forwards unread 1-to-1 iMessages/SMS and missed calls to your ZOLEO email address while you are off grid.

The current architecture is:

- **Swift menu bar app**: lightweight frontend for config, enable/disable, and helper control.
- **Go helper**: backend engine that watches Messages and CallHistory, builds digests, and sends through Apple Mail.
- **LaunchAgent**: keeps the Go helper running in watch mode.

## Features

- Unread-only forwarding for 1-to-1 conversations.
- Group chat messages are filtered out.
- Optional off-grid start/end window.
- Missed call digest support.
- Local config file.
- Local logs.
- Apple Mail sending, with SMTP planned as a future optional sender.

## Project Structure

```text
Off Grid Digest.xcodeproj/       Xcode project for the Swift menu bar app
Off Grid Digest/                 SwiftUI menu bar frontend
offgrid-digest-go/               Go backend/helper engine
Support Files/                   Active seed config used by Xcode and CLI examples
Legacy AppleScript/              Reference-only AppleScript implementation
Documentation/                   User-facing docs and release notes
Diagrams/                        Architecture diagrams
.vscode/launch.json              VS Code debug configs for the Go helper
```

The `Legacy AppleScript` files are reference material now. The active forwarding engine is the Go helper in `offgrid-digest-go/`.

## Running From Xcode

Open `Off Grid Digest.xcodeproj` and run the app.

The Xcode build phase:

1. Builds the Go helper from `offgrid-digest-go`.
2. Installs it to the app container support folder.
3. Writes a LaunchAgent at `~/Library/LaunchAgents/com.ampedig.off-grid-digest.helper.plist`.
4. Starts the Go helper with:

```bash
offgrid-digest --watch --interval=60s
```

Tail the helper log with:

```bash
tail -f "$HOME/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/OffGridDigest.log"
```

## Running The Go Helper Directly

The Go helper can run without the Swift app:

```bash
cd offgrid-digest-go
go build -o offgrid-digest ./cmd/offgrid-digest
./offgrid-digest --print-config
./offgrid-digest --dry-run
./offgrid-digest --watch --interval=60s --config "../Support Files/config.ini"
```

When run this way, `OffGridDigest.log` lives next to the executable. The source config lives at `Support Files/config.ini`; pass it with `--config` unless you intentionally copy it beside the executable.

See [offgrid-digest-go/README.md](offgrid-digest-go/README.md) for the command-line details.

## Permissions

macOS Full Disk Access is required for whichever process reads Messages and CallHistory.

During development, grant Full Disk Access to:

- Xcode, when running the Swift app.
- Visual Studio Code or Terminal, when debugging/running the Go helper directly.
- The installed Go helper binary, when using the LaunchAgent:

```text
~/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/offgrid-digest
```

Apple Mail automation may also require macOS automation permission the first time the helper sends a digest.

## Config

Example `config.ini`:

```ini
enabled=true
offgridStart=2026-06-21 18:44:19
offgridEnd=2026-08-10 18:46:20
forwardingEmail=your_zoleo_email@zoleo.com
zoleoNumber=17282215812
senderEmail=josh.daniel@ampedig.com
```

The Swift app writes config into its app support folder. The Go helper reads `config.ini` next to the executable it is running from.

## Developer Notes

Useful Go debug commands:

```bash
cd offgrid-digest-go
./offgrid-digest --print-config
./offgrid-digest --config "../Support Files/config.ini" --dry-run
./offgrid-digest --config "../Support Files/config.ini" --watch --interval=10s --dry-run
```

Useful launchd commands:

```bash
launchctl print gui/$(id -u)/com.ampedig.off-grid-digest.helper
launchctl kickstart -kp gui/$(id -u)/com.ampedig.off-grid-digest.helper
launchctl bootout gui/$(id -u)/com.ampedig.off-grid-digest.helper
```

## Support

For issues, open a ticket on GitHub or contact the project maintainer.
