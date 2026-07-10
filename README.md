# Minecraft Bedrock Server Manager

## What It Is
The **Minecraft Bedrock Server Manager** is a standalone, lightweight PowerShell script that deploys a native WPF/XAML graphical user interface (GUI) to manage a Minecraft Bedrock Dedicated Server on Windows. It requires zero third party dependencies or installations just standard Windows PowerShell 5.1. 

<img width="40%" alt="2026-07-05_164913" src="https://github.com/user-attachments/assets/d8be13de-2960-40ca-ae21-2755145ebd61" />
<img width="33%" alt="2026-07-09_192324" src="https://github.com/user-attachments/assets/13eb8660-6859-43d9-9291-7343f114f97a" />


---

## What It Does
This tool automates the entire lifecycle of running a Windows Bedrock server. From the initial click, it reaches out to the official Mojang/Minecraft API, downloads the latest dedicated server files, and configures a clean local directory structure. Once running, it monitors the server process, handles graceful shutdowns, tracks PC and server uptime, and provides a real time console log of system events.

It operates using a strict, clean folder hierarchy (defaulting to `C:\Bedrock`):

* `\Server` - The active Minecraft server binaries and world data.
* `\Backups` - Compressed `.zip` archives of your worlds and configurations.
* `\Logs` - Daily rolling manager logs.
* `\UpdateTemp` - Temporary staging for safe updates.
* `\Config` - Settings are stored in a configuration `.ini` file.

Includes Bedrock Server Configurator HTML file to quickly setup your server.properties file.

## Why You Should Use It
Running a vanilla Minecraft Bedrock server manually requires constant maintenance. Updates are frequent, and missing one means players on updated clients cannot join. Furthermore, command-line execution lacks native crash monitoring, and backing up world data usually requires writing custom scripts. 

You should use this manager if you want a "set it and forget it" solution optimized for long term stability (weeks or months of uptime). It takes the manual labor out of server hosting by providing an intuitive dashboard that handles backups, crash recovery, updates, and live console interaction automatically, ensuring your server remains online, secure, and up-to-date with zero manual intervention.

---

## Features

### 🚀 Installation & Setup
* **Zero-Dependency Execution:** Runs entirely natively on Windows 10/11/Server using only built in PowerShell 5.1 and WPF/XAML (no Python, Node.js, or external libraries required).
* **One-Click Setup:** Automatically reaches out to the official Mojang/Minecraft API, downloads the latest Bedrock server `.zip`, and extracts it.
* **Clean Folder Hierarchy:** Automatically creates and manages a structured directory tree (`\Server`, `\Backups`, `\Logs`, `\UpdateTemp`, `\Config`) defaulting to `C:\Bedrock`.
* **Auto-Firewall Configuration:** Automatically creates and manages inbound Windows Firewall rules for `bedrock_server.exe` (requires Admin rights).
* **Static IP Auto-Configuration:** Detects if the active network adapter is using DHCP (dynamic IP) and offers to automatically convert it to a Static IP to ensure players can always find the server.
* **IPv6 Disabling:** Automatically disables IPv6 on the active adapter to force strict IPv4 usage, preventing network routing conflicts.
* **VC++ Redistributable Installer:** Detects if the Microsoft Visual C++ Redistributable is missing and silently downloads/installs it in the background.

### 🔄 Update Management
* **Automatic API Polling:** Periodically checks the official Mojang API for new server releases (customizable interval, defaults to 24 hours).
* **True Semantic Versioning:** Compares installed and latest versions using strict numeric SemVer math (e.g., `1.20.30` vs `1.20.31`), preventing false-positive update loops.
* **Auto-Apply Updates:** Can be configured to automatically download, backup, and apply updates the moment they are detected, requiring zero user interaction.
* **Safe Update Staging:** Downloads and verifies the integrity of the new server `.zip` before applying it. If the archive is corrupt or too small, it aborts the update.

### 🗄️ Backup & Restore
* **Pre-Update Auto-Backups:** Automatically creates a full backup of the `worlds` directory, `server.properties`, `allowlist.json`, and `permissions.json` before *any* update or overwrite occurs.
* **Manual 1-Click Backups:** Allows the user to manually trigger a full backup at any time (requires server to be stopped).
* **SHA256 Hash Verification:** Generates and stores a SHA256 checksum manifest for every single file in the backup.
* **1-Click Restore:** Allows users to select a previous `.zip` backup. It stages the files, verifies them against the SHA256 manifest, and only applies them if 100% of the checksums match, preventing corrupted restores.
* **Automated Backup Retention:** Automatically purges the oldest backups when the maximum backup limit is reached (customizable, defaults to 3).

### 🖥️ Interface & Dashboard
* **Native WPF/XAML GUI:** A modern dashboard that scales to maximize screen real estate.
* **Dual-Console Layout:** Splits logs into two panels:
  * **Left Console:** Tracks manager-side events (system logs, updates, crashes, settings applied).
  * **Right Console:** Real-time wrapper for native `bedrock_server.exe` stdout/stderr output.
* **Live Command Input:** Users can type native Minecraft commands (e.g., `say hello`, `list`, `stop`) directly into the GUI, which are securely piped to the server via stdin.
* **Command History Navigation:** Pressing the "Up" and "Down" arrow keys in the command input box cycles through previously sent commands.
* **Live Status Tracking:** Constantly displays PC Uptime, Server Uptime, Installed Version, Latest Version, Server Status, IP/Port, and the time of the last backup.
* **Color-Coded Logging:** System and Server logs utilize a dynamic color map (e.g., Green for Success, Red for Error, Orange for Warning) for easy visual parsing.
* **Daily Console Auto-Clear:** Automatically clears the GUI server console panel every 24 hours to prevent high memory usage and UI lag.
* **Active Progress Bars:** Displays an indeterminate or percentage based progress bar during downloads, extractions, and backups.

### ⏱️ Scheduled Reboots
* **Custom Scheduling Engine:** Allows users to configure automatic server restarts on a Daily, Weekly, Biweekly, or Monthly basis.
* **"Last Day" Monthly Logic:** If set to Monthly, users can select "Last Day," which dynamically calculates the final day of any given month (handling leap years and 30/31-day months automatically).
* **Missed Day Calculation:** If a specific day (like the 31st) doesn't exist in the current month, the engine skips to the next valid month rather than breaking.
* **Live Next-Reboot Indicator:** Displays a live countdown/status at the top of the GUI (e.g., `Reboot: Oct 31 03:00`).
* **Instant Auto-Save Settings:** Removed the manual "Apply" button. Any change to checkboxes, text boxes, or schedule dialogs instantly validates and saves to the `config.ini` file.

### 🛡️ Crash Protection & Process Management
* **Active PID Monitoring:** Monitors the server's Process ID (PID) and executable path. If the process dies unexpectedly, it instantly triggers recovery.
* **Smart Process Adoption:** If the GUI is opened while the server is already running, it adopts the existing PID, preventing dual instances and hijacking servers in other directories.
* **Intelligent Crash vs. Reboot Handling:** Crash detection explicitly suspends during a scheduled reboot, preventing false positive "Crash detected!" alerts in the console.
* **File Lock Safety Delays:** Both scheduled reboots and crash recovery routines enforce a strict 10 second delay between stopping the server and starting it back up, ensuring all world files and processes are fully released by the OS and preventing world corruption.
* **Graceful Shutdown (stdin):** Attempts to send the native `stop` command to the server via stdin to allow it to save worlds gracefully before falling back to a force kill.
* **Graceful Window Closing:** Closing the GUI intercepts the shutdown and grants the server a 10 second window to safely save worlds and halt before force killing the process.

### ⚙️ Under the Hood (Technical Stability)
* **Dual-Thread Architecture:** The GUI runs on a dedicated Single Threaded Apartment (STA) thread, ensuring the UI never freezes during heavy background tasks.
* **Background Runspaces:** Heavy lifting (downloading, extracting, hashing) is processed in isolated MTA Runspaces.
* **Thread-Safe Locks:** Implements `StdInWriteLock`, `TypeCompileLock`, and synchronized ArrayLists to completely eliminate race conditions across concurrent background tasks.
* **Concurrent Queue Reader:** Uses a custom C# wrapper (`BedrockProcessReader`) utilizing `ConcurrentQueue` to asynchronously read server stdout/stderr without blocking the UI thread.
* **Automated Garbage Collection:** The script actively monitors memory usage and triggers `[System.GC]::Collect()` every 5 minutes to ensure minimal resource consumption and prevent leaks over long uptimes.
* **Rolling Log Files:** Automatically generates daily log files in the `\Logs` directory and purges logs older than the configured retention period (defaults to 30 days).
* **Config Portability:** Automatically migrates legacy configurations from `AppData\BedrockServerManager` to the new local `C:\Bedrock\Config` directory, cleaning up old files behind it.

---

## Requirements

* Windows 10 / Windows 11 / Windows Server
* Windows PowerShell 5.1 (`#Requires -Version 5.1`)
* **Administrator privileges** (Optional, but required if you want the tool to automatically configure a Static IP, manage the Windows Firewall rules, or install missing VC++ runtime dependencies).

---

## How to Allow Players to Join

Once your Minecraft server has successfully started, follow these quick steps to let others connect:

1. Open your server console window on the right side of the manager.
2. Type the following command exactly as shown: `allowlist off`
3. Press **Enter**.

> **Note:** This disables the allowlist, meaning anyone with your server's IP address will now be able to join.
