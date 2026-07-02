# Minecraft Bedrock Server Manager

A simple, graphical control panel for setting up, running, and maintaining a Minecraft Bedrock Dedicated Server on Windows. It replaces manual command-line tasks, manual file downloads, and messy configuration updates with an automated, easy-to-use desktop application interface.

<img width="60%" alt="image" src="https://github.com/user-attachments/assets/f821d38d-a260-470e-8698-20fd4dc9e519" />


## What It Is
Hosting a private multiplayer world for Minecraft Bedrock Edition (the version used on Windows 10/11, iOS, Android, and consoles) normally requires you to manually download ZIP archives from Mojang, track version changes, manage your own backups, and keep a simple command-line window open at all times. 

This PowerShell-based utility provides a visual dashboard to handle all of those background tasks automatically. It features a clean window with progress bars, status indicators, and a built-in server log reader so you can easily see what is happening with your server in real-time without having to type commands.

## Why You Should Use It
Managing a dedicated server manually can be tedious and prone to user error, especially when game updates release frequently. This manager is designed to let you set up your server once and let it run hands-off for weeks or months at a time.

### 1. Eliminates Version Mismatch Errors
Minecraft Bedrock is frequently updated, and if your server version does not exactly match your players' game version, they will be blocked from joining. The manager regularly checks the official Minecraft services for new server updates. You can set it to simply notify you, or have it automatically download, install, and restart the server with the new version so your friends are never locked out of the game.

### 2. Smart Crash Protection
If your server crashes, runs out of memory, or closes unexpectedly while you are asleep or away from your computer, your multiplayer world goes offline. The manager includes a Crash Protection feature that actively monitors the game in the background. If the server goes down, the utility instantly detects the failure and reboots it within seconds.

### 3. Safe, Automated Backups
When upgrading a server manually, it is very easy to accidentally overwrite your server settings or player allowlists. Whenever the manager applies a game update, it automatically creates a timestamped copy of your core configuration files (such as `server.properties`, `allowlist.json`, and `permissions.json`). It also manages your hard drive space by automatically deleting old backups once you reach a limit you configure.

### 4. Zero-Hassle Installation
First-time setup takes just one click. You simply choose a folder on your computer (for example, `C:\Bedrock`), and the manager will download the latest server files, verify them to ensure they aren't corrupted, extract them, and organize everything into a clean folder structure. It separates your game files, backups, and logs so your folders never become cluttered.

### 5. Customizable Settings
The interface allows you to tailor the automation to your needs:
* Choose exactly how often the program checks for game updates (e.g., every 12 or 24 hours).
* Toggle whether updates apply automatically or wait for your manual approval.
* Choose whether the server should automatically turn on when you open the manager application.
* Set how many days of server logs and backup files to keep on your hard drive before they are automatically cleaned up to save space.

## Requirements and Setup
* **Operating System:** Windows 10, Windows 11, or Windows Server.
* **Prerequisite:** PowerShell 5.1 (Built into modern Windows by default).

To use it, simply save the script to your computer, open PowerShell as an Administrator, and run the file. From the graphical window, select where you want your server saved, click "Setup / Install", and the manager will handle the rest.
