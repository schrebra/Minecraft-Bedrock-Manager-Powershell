# Minecraft Bedrock Server Manager

## What It Is

The **Minecraft Bedrock Server Manager** is a standalone, lightweight PowerShell script that deploys a native WPF/XAML graphical user interface (GUI) to manage a Minecraft Bedrock Dedicated Server on Windows. It requires zero third-party dependencies or installations—just standard Windows PowerShell 5.1. 

<img width="60%" alt="image" src="https://github.com/user-attachments/assets/29dd2833-da30-45f3-a8cf-3aa177d79c2b" />

## What It Does

This tool automates the entire lifecycle of running a Windows Bedrock server. From the initial click, it reaches out to the official Mojang/Minecraft API, downloads the latest dedicated server files, and configures a clean local directory structure. Once running, it monitors the server process, handles graceful shutdowns, tracks PC and server uptime, and provides a real-time console log of system events.

It operates using a strict, clean folder hierarchy (defaulting to `C:\Bedrock`):
* `\Server` - The active Minecraft server binaries and world data.
* `\Backups` - Compressed `.zip` archives of your worlds and configurations.
* `\Logs` - Daily rolling manager logs.
* `\UpdateTemp` - Temporary staging for safe updates.
* `\Config` - Settings are stored in a configuration ini file

## Why You Should Use It

Running a vanilla Minecraft Bedrock server manually requires constant maintenance. Updates are frequent, and missing one means players on updated clients cannot join. Furthermore, command-line execution lacks native crash monitoring, and backing up world data usually requires writing custom scripts. 

You should use this manager if you want a **"set it and forget it"** solution optimized for long-term stability (weeks or months of uptime). It takes the manual labor out of server hosting by providing an intuitive dashboard that handles backups, crash recovery, updates, and live console interaction automatically, ensuring your server remains online, secure, and up-to-date with zero manual intervention.

## What's New in Version 28.4

The latest production-ready release (Dual Console Edition) introduces deep stability enhancements, a brand new interface, and system intelligence automation:
* **Dual Console Layout:** Features two distinct log windows. The left tracks Manager/PowerShell system events, while the right displays real-time server output (stdin/stdout) via a custom .NET wrapper.
* **Live Command Input:** You can now send custom commands directly to the active Minecraft server right from the GUI dashboard!
* **Advanced Lock Safety & Threading:** Implemented `StdInWriteLock`, `TypeCompileLock`, and synchronized ArrayLists to completely eliminate race conditions across concurrent background tasks.
* **Smart Process Adoption:** Crash detection and auto-adoption now track by Process ID (PID) and rigorously verify the executable path, preventing the manager from hijacking servers running in other directories.
* **Graceful Window Closing:** Closing the GUI now intercepts the shutdown and grants the server a 10-second window to safely save worlds and halt before force-killing the process.
* **True Semantic Versioning:** Automated update checks now utilize full SemVer numeric math for perfectly accurate version comparisons.

## Features

* **One-Click Setup & Installation:** No need to manually download or extract `.zip` files from the official site. The manager fetches the latest production-ready version directly from Mojang.
* **Automated Updates:** Continuously polls the Minecraft API for new releases (customizable check intervals). It can notify you of updates or be configured to automatically download, backup, and apply them.
* **Dual-Console Live Dashboard:** A scrolling, color-coded internal log tracks system statuses and updates, alongside a fully interactive wrapper console for native bedrock server commands.
* **Smart Backups & Restore:** Automatically creates full `.zip` archives of your `worlds` folder and critical configurations (`server.properties`, `allowlist.json`, `permissions.json`) before any update. Includes automated retention policies and a 1-click restore function.
* **Active Crash Protection:** Monitors the `bedrock_server.exe` process. If the server crashes or closes unexpectedly, the manager instantly detects the failure and attempts a safe recovery/restart.
* **Static IP & Dependency Auto-Configuration:** Automatically detects DHCP configurations to apply Static IPs, and scans for missing Microsoft Visual C++ redistributables to silently install them.
* **Low Overhead:** Runs a minimized server process and utilizes highly optimized PowerShell garbage collection to ensure the GUI itself consumes minimal system resources over long uptimes.
* **Persistent Settings (INI Engine):** Dashboard configurations are saved permanently to a localized configuration profile (`C:\Bedrock\Config\config.ini`), preserving preferences between reboots.

## Requirements

* Windows 10 / Windows 11 / Windows Server
* Windows PowerShell 5.1 (`#Requires -Version 5.1`)
* Administrator privileges (Optional, but required if you want the tool to automatically configure a Static IP, manage the Windows Firewall rules, or install missing VC++ runtime dependencies).

## How to Allow Players to Join

Once your Minecraft server has successfully started, follow these quick steps to let others connect:

1. **Open** your server console window on the right side of the manager.
2. **Type** the following command exactly as shown: `allowlist off`
3. **Press** Enter.

> **Note:** This disables the allowlist, meaning anyone with your server's IP address will now be able to join!
