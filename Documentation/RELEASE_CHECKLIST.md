# Off‑Grid Digest — Release Checklist

> Paste this in your repo under `docs/RELEASE_CHECKLIST.md`

## 0) Versioning
- [ ] Update **CFBundleShortVersionString** (marketing) and **CFBundleVersion** (build).
- [ ] Update `CHANGELOG.md` with highlights.

## 1) App build settings
- [ ] Signing: **Developer ID Application**.
- [ ] Hardened Runtime: **Enabled**.
- [ ] Disable App Sandbox (we write to `~/Library` and call system tools).
- [ ] Info.plist: add `NSAppleEventsUsageDescription` with a clear reason.
- [ ] Verify bundle includes:
  - [ ] `ForwardMessagesToEmailWhileOffGrid.scpt` (Copy Bundle Resources)
  - [ ] `com.yourco.forward-messages.plist` (template LaunchAgent) (Copy Bundle Resources)

## 2) First‑run installer code
- [ ] Copy `.scpt` → `~/Library/Scripts/ForwardMessagesToEmailWhileOffGrid.scpt`
- [ ] Copy/edit `.plist` → `~/Library/LaunchAgents/com.yourco.forward-messages.plist`
  - [ ] Set `ProgramArguments`: `/usr/bin/osascript`, `~/Library/Scripts/ForwardMessagesToEmailWhileOffGrid.scpt`
  - [ ] Set `StartInterval`: `300` (5 min)
- [ ] Write config file on first run if missing:
  - [ ] `~/Library/Application Support/MsgForward/config.ini` with keys:
    - `enabled=true`
    - `offgridStart=` (optional `yyyy-MM-dd HH:mm:ss`)
    - `offgridEnd=`   (optional `yyyy-MM-dd HH:mm:ss`)
    - `forwardingEmail=`
- [ ] Buttons in menu:
  - [ ] **Install Helper** (optional) or perform install automatically on first run
  - [ ] **Reload LaunchAgent** → `launchctl bootout/bootstrap`
  - [ ] **Kick Now** → `launchctl kickstart -kp gui/$(id -u)/com.yourco.forward-messages`
  - [ ] **Open Config** / **Open Log** convenience

## 3) Permissions (document for users)
- [ ] Full Disk Access (FDA): add the following in System Settings → Privacy & Security → Full Disk Access:
  - `/usr/bin/osascript`
  - `/usr/bin/sqlite3`
- [ ] Apple Events prompt will appear on first send. (Reason shown from `NSAppleEventsUsageDescription`.)

## 4) QA on a clean user
- [ ] Fresh macOS user account (no prior config).
- [ ] First run creates config and installs helper files.
- [ ] UI can edit **enabled**, **start**, **end**, **forwardingEmail**.
- [ ] LaunchAgent reload works and shows in `launchctl list`.
- [ ] Digest email arrives during window with correct message bodies + missed calls.
- [ ] Logs written to `~/Library/Logs/ForwardMessages.log`.

## 5) Archive / Notarize
- [ ] **Product → Archive** in Xcode.
- [ ] **Distribute App → Developer ID** (Upload) — wait for notarization to complete.
- [ ] Alternatively (CLI): zip, `xcrun notarytool submit --wait`, `xcrun stapler staple`.

## 6) Package
- [ ] ZIP or DMG created from notarized `.app`.
- [ ] Verify Gatekeeper open (no quarantine errors).

## 7) Website / Docs
- [ ] Update one‑pager with download link.
- [ ] Publish **Getting Started** (HTML/PDF) and **Troubleshooting**.
- [ ] Include **Uninstall** instructions.

## 8) Support
- [ ] Provide support email and known limitations:
  - AppleScript relies on local Messages DB format (may change across macOS releases)
  - Call history DB location/format can vary; feature is best‑effort
  - Requires user‑granted FDA and Mail access

---

### Uninstall Script (for docs)
```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.yourco.forward-messages.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.yourco.forward-messages.plist
rm -f ~/Library/Scripts/ForwardMessagesToEmailWhileOffGrid.scpt
rm -rf ~/Library/Application\ Support/MsgForward
rm -f  ~/Library/Logs/ForwardMessages.log
echo 'Off‑Grid Digest helper removed.'
```
