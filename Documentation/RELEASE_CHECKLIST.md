# Off-Grid Digest — Release Checklist

## 0) Versioning
- [ ] Update `CFBundleShortVersionString` and `CFBundleVersion`.
- [ ] Update release notes / changelog.

## 1) App build settings
- [ ] Signing: Developer ID Application.
- [ ] Hardened Runtime: enabled.
- [ ] Confirm the app can write its Application Support files and LaunchAgent.
- [ ] Info.plist: add `NSAppleEventsUsageDescription` explaining Apple Mail send automation.
- [ ] Verify Xcode build phase:
  - [ ] Builds `offgrid-digest-go/cmd/offgrid-digest`.
  - [ ] Installs helper to:
    `~/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/offgrid-digest`
  - [ ] Copies seed config from `Support Files/config.ini` only if missing.
  - [ ] Writes `~/Library/LaunchAgents/com.ampedig.off-grid-digest.helper.plist`.
  - [ ] Bootstraps `com.ampedig.off-grid-digest.helper`.

## 2) First-run helper behavior
- [ ] Config exists at:
  `~/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/config.ini`
- [ ] Config supports:
  - `enabled=true`
  - `offgridStart=` optional `yyyy-MM-dd HH:mm:ss`
  - `offgridEnd=` optional `yyyy-MM-dd HH:mm:ss`
  - `forwardingEmail=`
  - `zoleoNumber=`
  - `senderEmail=`
- [ ] LaunchAgent runs:
  `offgrid-digest --watch --interval=60s`
- [ ] Menu buttons work:
  - [ ] Reload Go Helper
  - [ ] Kick Now

## 3) Permissions
- [ ] Full Disk Access: add the installed Go helper binary:
  `~/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/offgrid-digest`
- [ ] For development, Full Disk Access is granted to Xcode, VS Code, or Terminal as needed.
- [ ] Apple Mail automation prompt appears and can be accepted on first real send.

## 4) QA on a clean user
- [ ] Fresh macOS user account or clean app container.
- [ ] First run creates config and installs helper files.
- [ ] UI can edit enabled, start, end, forwarding email, ZOLEO number, and sender email.
- [ ] LaunchAgent shows as running:
  `launchctl print gui/$(id -u)/com.ampedig.off-grid-digest.helper`
- [ ] Helper log updates:
  `tail -f "$HOME/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward/OffGridDigest.log"`
- [ ] Dry-run from Go helper reports expected config and message count.
- [ ] Digest email arrives during the active window with message bodies and missed calls.
- [ ] Process does not forward group chats.
- [ ] Process marks forwarded messages read only after successful send.

## 5) Go command-line QA
```bash
cd offgrid-digest-go
go test ./...
go build -o offgrid-digest ./cmd/offgrid-digest
./offgrid-digest --config "../Support Files/config.ini" --print-config
./offgrid-digest --config "../Support Files/config.ini" --dry-run
```

## 6) Archive / Notarize
- [ ] Product → Archive in Xcode.
- [ ] Distribute App → Developer ID.
- [ ] Wait for notarization.
- [ ] Verify Gatekeeper opens the app cleanly.

## 7) Docs
- [ ] Update README.
- [ ] Update Getting Started HTML/PDF.
- [ ] Include uninstall instructions.
- [ ] Include Full Disk Access instructions for the installed helper binary.

## 8) Known limitations
- Messages and CallHistory database schemas may change across macOS releases.
- Call history DB location/format can vary.
- Apple Mail must be configured for the sender account.
- SMTP is not currently implemented; Apple Mail is the sender.

## Uninstall Commands
```bash
launchctl bootout gui/$(id -u)/com.ampedig.off-grid-digest.helper 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.ampedig.off-grid-digest.helper.plist"
rm -rf "$HOME/Library/Containers/com.ampedig.Off-Grid-Digest/Data/Library/Application Support/MsgForward"
echo "Off-Grid Digest helper removed."
```
