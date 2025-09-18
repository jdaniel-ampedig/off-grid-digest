
# Off-Grid Digest for macOS

**Off-Grid Digest** is a lightweight macOS utility that automatically forwards your unread 1-to-1 iMessages/SMS and missed calls to your ZOLEO email address while you're off the grid.  

It runs locally on your Mac, requires no cloud services, and can be scheduled to run only during your defined off-grid window.  

**Note:** In it's initial format this will be open source with no installer.  If you're not technically inclined i.e. understand what the code is doing and how launchd works please ask someone who does to assist.  There are near future plans to create a OSX installer.

---

## ✨ Features

- **Unread-Only:** Only forwards new unread 1-to-1 messages. _Group chat messages are filtered out_
- **Windowed Operation:** Runs only during your defined start/end window.
- **Missed Call Digest:** Includes missed calls during the same window.
- **Local & Private:** No cloud storage or third-party servers involved.
- **Simple Config:** Plain-text config file for start/end times, forwarding email, and enabling/disabling the service.
- **Automatic Scheduling:** Runs periodically via `launchd`.

---

## 📂 Project Structure

```
Off-Grid Digest/
├─ ForwardMessagesToEmailWhileOffGrid.scpt   # AppleScript that does the forwarding
├─ com.ampedig.forward-messages.plist        # LaunchAgent for scheduling
├─ config.ini                                # User config (start/end/email/etc.)
├─ OffGrid_DigestApp.swift                   # Optional SwiftUI menu bar app
└─ README.md
```

---

## ⚙️ Prerequisites

- **macOS 13+** (Full Disk Access required for Messages & Call History DBs)
- **Apple Mail** (used for sending the email digest)
- **SQLite3** (preinstalled on macOS)
- **ZOLEO email address** for receiving digests

---

## 🛠 Installation

1. **Clone or copy** the project folder to your Mac:
   ```bash
   git clone https://github.com/your-repo/off-grid-digest.git
   ```

2. **Grant Full Disk Access** for:
   - `/usr/bin/osascript`
   - `/usr/bin/sqlite3`
   - Your Terminal or Xcode (for testing/debugging)

3. **Place the LaunchAgent**:
   ```bash
   mkdir -p ~/Library/LaunchAgents
   cp com.ampedig.forward-messages.plist ~/Library/LaunchAgents/
   ```

4. **Configure your settings** in:
   ```bash
   ~/Library/Application Support/MsgForward/config.ini
   ```
   Example:
   ```
   enabled=true
   offgridStart=2025-09-10 18:44:19
   offgridEnd=2025-09-11 18:44:19
   forwardingEmail=your_zoleo_email@zoleo.com
   ```

---

## 🚀 Running

### Test manually
```bash
osascript ForwardMessagesToEmailWhileOffGrid.scpt
```

### Load with launchd
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.jdaniel.forward-messages.plist
launchctl enable gui/$(id -u)/com.jdaniel.forward-messages
launchctl kickstart -k gui/$(id -u)/com.ampedig.forward-messages
```

### Unload if needed
```bash
launchctl bootout gui/$(id -u)/com.ampedig.forward-messages
```

---

## 🐞 Debugging

- **Log output:**  
  ```
  tail -f ~/Library/Logs/ForwardMessages.log
  ```
- **Standard output/error:**  
  ```
  /tmp/forward-messages.out
  /tmp/forward-messages.err
  ```
- **Force run now:**  
  ```bash
  osascript ForwardMessagesToEmailWhileOffGrid.scpt
  ```

---

## 🖥 Menu Bar App

A SwiftUI menu bar app (`OffGrid_DigestApp.swift`) is included to:
- Toggle forwarding on/off  
- Edit the config file  
- Set start/end times interactively  

To build:
1. Open the Xcode project
2. Run or build as usual
3. Tail the log file to see all my terrible debug message `tail -f Library/Logs/ForwardMessages.log`

<img height="500" alt="image" src="https://github.com/user-attachments/assets/a8fb451a-9608-445b-ae82-653aaee4f7e2" />


## 🖼️ In Zoleo app Screenshots 

<img height="1000" alt="image" src="https://github.com/user-attachments/assets/f188059a-a46d-4723-9b31-968444e0c914" />
<img height="1000" alt="image" src="https://github.com/user-attachments/assets/dd16bd2c-3504-4898-bf27-30d30397516f" />


---

## High-level diagram

<img width="1136" height="908" alt="image" src="https://github.com/user-attachments/assets/fdbf856a-d5ce-42cc-80da-ec05abc68342" />

---

## 🙋 Support

For issues, open a ticket on GitHub or contact the project maintainer.
