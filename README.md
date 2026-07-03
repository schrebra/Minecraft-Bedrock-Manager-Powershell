# Minecraft Bedrock Server Manager — GUI Edition

## What It Is

The **Minecraft Bedrock Server Manager** is a standalone, lightweight PowerShell script that deploys a native WPF/XAML graphical user interface (GUI) to manage a Minecraft Bedrock Dedicated Server on Windows. It requires zero third-party dependencies or installations—just standard Windows PowerShell 5.1. 

<img width="60%" alt="image" src="https://github.com/user-attachments/assets/2f071c9e-ad28-4010-84b5-7ea85fce6310" />

## What It Does

This tool automates the entire lifecycle of running a Windows Bedrock server. From the initial click, it reaches out to the official Mojang/Minecraft API, downloads the latest dedicated server files, and configures a clean local directory structure. Once running, it monitors the server process, handles graceful shutdowns, tracks PC and server uptime, and provides a real-time console log of system events.

It operates using a strict, clean folder hierarchy (defaulting to `C:\Bedrock`):
* `\Server` - The active Minecraft server binaries and world data.
* `\Backups` - Compressed `.zip` archives of your worlds and configurations.
* `\Logs` - Daily rolling manager logs.
* `\UpdateTemp` - Temporary staging for safe updates.

## Why You Should Use It

Running a vanilla Minecraft Bedrock server manually requires constant maintenance. Updates are frequent, and missing one means players on updated clients cannot join. Furthermore, command-line execution lacks native crash monitoring, and backing up world data usually requires writing custom scripts. 

You should use this manager if you want a **"set it and forget it"** solution optimized for long-term stability (weeks or months of uptime). It takes the manual labor out of server hosting by providing an intuitive dashboard that handles backups, crash recovery, and updates automatically, ensuring your server remains online, secure, and up-to-date with zero manual intervention.

## What's New in Version 27.4

The latest production-ready release introduces deep stability enhancements and system intelligence automation:
* **Automated Runtime Setup:** Automatically checks your registry for required Microsoft Visual C++ dependencies. If missing, it downloads and performs a silent installation so the server can boot flawlessly.
* **Intelligent Network Filtering:** The network configuration logic now intelligently filters out virtual adapters (VMware, VirtualBox, and Hyper-V vEthernet switches) to guarantee accurate connection status and static IP mapping.
* **Persistent Settings (INI Engine):** Your dashboard configurations are now saved permanently to a localized configuration profile (`%APPDATA%`), preserving your preferences between reboots.
* **Extended Boot-Grace Window:** Added an extended initialization safety buffer (up to 45 seconds) to accommodate slower hard drives and initial Windows Firewall permission checks without flagging a false startup failure.

## Features

* **One-Click Setup & Installation:** No need to manually download or extract `.zip` files from the official site. The manager fetches the latest production-ready version directly from Mojang.
* **Automated Updates:** Continuously polls the Minecraft API for new releases (customizable check intervals). It can notify you of updates or be configured to automatically download, backup, and apply them.
* **Smart Backups & Restore:** Automatically creates full `.zip` archives of your `worlds` folder and critical configurations (`server.properties`, `allowlist.json`, `permissions.json`) before any update. Includes automated retention policies (e.g., keep the last 3 backups) and a 1-click restore function.
* **Active Crash Protection:** Monitors the `bedrock_server.exe` process. If the server crashes or closes unexpectedly, the manager instantly detects the failure and attempts a safe recovery/restart.
* **Static IP Auto-Configuration:** Automatically detects if your host machine is using a dynamic (DHCP) IP address and can seamlessly elevate privileges to assign a Static IP, preventing player connection issues when your PC reboots.
* **Live Dashboard & Analytics:** Displays real-time metrics including installed vs. latest versions, PC uptime, Server uptime, active listening IP/Port, and the time of the last successful backup.
* **Built-in Console Logging:** Features a scrolling, color-coded internal log window to track system events, update statuses, and errors, automatically writing to daily rolling log files.
* **Low Overhead:** Runs a minimized server process and utilizes highly optimized PowerShell garbage collection to ensure the GUI itself consumes minimal system resources over long uptimes.

## Requirements

* Windows 10 / Windows 11 / Windows Server
* Windows PowerShell 5.1 (`#Requires -Version 5.1`)
* Administrator privileges (Optional, but required if you want the tool to automatically configure a Static IP, manage the Windows Firewall rules, or install missing VC++ runtime dependencies).

## How to Allow Players to Join

Once your Minecraft server has successfully started, follow these quick steps to let others connect:

1. **Open** your server console window.
2. **Type** the following command exactly as shown:
   `allowlist off`
3. **Press** Enter.

> **Note:** This disables the allowlist, meaning anyone with your server's IP address will now be able to join!
