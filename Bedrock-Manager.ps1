#Requires -Version 5.1
<#
.SYNOPSIS
    Minecraft Bedrock Server Manager — GUI Edition

.DESCRIPTION
    WPF/XAML GUI for first-time setup, auto-update, and management of
    Minecraft Bedrock Dedicated Server on Windows.
    Now features a DUAL CONSOLE layout:
      - PowerShell / Manager console (left): manager-side logs
      - Server console (right): wrapped bedrock_server.exe stdin/stdout via .NET
        Process redirection — supports sending custom commands from the GUI.
    Optimized for long-term stability (weeks/months of uptime).

.VERSION
    28.4

.CHANGES from 28.3
    - Fixed: ContentRendered called Get-AppliedVersion/Set-AppliedVersion which
      were only defined in the background helper runspace, causing silent
      CommandNotFoundException errors on startup. Replaced with inline file ops.
    - Fixed: Auto-launch race condition + UI freeze. ContentRendered no longer
      Start-Sleeps on the GUI thread; periodic check and auto-launch are chained
      in the same background work block.
    - Fixed: Process adoption verified exe Path matches our installation,
      preventing adoption of bedrock_server instances from other directories.
    - Fixed: StandardInput writes now guarded by a shared lock
      (StdInWriteLock) to prevent concurrent stream writes from tick handler,
      Stop-GameServer, and window closing handler.
    - Fixed: BedrockProcessReader C# type compilation guarded by TypeCompileLock
      to prevent race across concurrent background runspaces.
    - Fixed: Window closing now waits up to 10s for graceful 'stop', then
      force-kills if needed. Prevents world corruption on close.
    - Fixed: Background jobs cleaned up on window close (stop + dispose
      runspaces).
    - Fixed: Version comparison now uses proper semver numeric comparison
      (Compare-BedrockVersion) instead of string equality.
    - Fixed: try/catch around Process.StartTime access (can throw
      Win32Exception for elevated processes).
    - Fixed: Firewall rule verified for adopted processes.
    - Fixed: ArrayLists in sharedState now use [ArrayList]::Synchronized().
    - Fixed: Backup zip overwrite safety (delete existing before create).
    - Fixed: Crash detection checks process by PID when available, not just name.
    - Fixed: DispatcherTimer guarded against tick after window closed.
    - Added: Path validation on root path change.
    - Added: PendingProgress read as single atomic snapshot in tick handler.
#>

param(
    [string]$RootPath = "",
    [switch]$ApplyStaticIp
)

# ─── Pre-GUI Admin Logic & Dependencies ───────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-VcRedistInstalled {
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64"
    )
    foreach ($p in $regPaths) {
        if (Test-Path $p) {
            $val = (Get-ItemProperty $p -Name "Installed" -ErrorAction SilentlyContinue).Installed
            if ($val -eq 1) { return $true }
        }
    }
    return $false
}

function Get-ActiveNetworkAdapter {
    try {
        $netAdapters = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
            $_.IPv4Address -ne $null -and
            $_.InterfaceAlias -notmatch "Loopback" -and
            $_.InterfaceAlias -notmatch "VMware" -and
            $_.InterfaceAlias -notmatch "VirtualBox" -and
            $_.InterfaceAlias -notmatch "vEthernet" -and
            $_.IPv4Address.IPAddress -notlike "169.*" -and
            $_.IPv4Address.IPAddress -ne "127.0.0.1"
        }
        return ($netAdapters | Select-Object -First 1)
    } catch { }
    return $null
}

function Get-DhcpAdapterInfo {
    $net = Get-ActiveNetworkAdapter
    if (-not $net) { return $null }
    $alias = $net.interfaceAlias
    $ipAddr = $net.IPv4Address.IPAddress
    $dhcpStatus = (Get-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
    if ($dhcpStatus -eq 'Enabled') {
        $prefix = (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).PrefixLength
        $gateway = (Get-NetRoute -InterfaceAlias $alias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        $dns = (Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        return @{ Alias = $alias; Ip = $ipAddr; Prefix = $prefix; Gateway = $gateway; Dns = $dns }
    }
    return $null
}

function Set-StaticIpFromDhcp {
    param([hashtable]$DhcpInfo)
    try {
        Set-NetIPInterface -InterfaceAlias $DhcpInfo.Alias -Dhcp Disabled -ErrorAction Stop
        if ($DhcpInfo.Gateway) {
            New-NetIPAddress -InterfaceAlias $DhcpInfo.Alias -IPAddress $DhcpInfo.Ip -PrefixLength $DhcpInfo.Prefix -DefaultGateway $DhcpInfo.Gateway -ErrorAction Stop | Out-Null
        } else {
            New-NetIPAddress -InterfaceAlias $DhcpInfo.Alias -IPAddress $DhcpInfo.Ip -PrefixLength $DhcpInfo.Prefix -ErrorAction Stop | Out-Null
        }
        if ($DhcpInfo.Dns) {
            Set-DnsClientServerAddress -InterfaceAlias $DhcpInfo.Alias -ServerAddresses $DhcpInfo.Dns -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    }
}

if ($ApplyStaticIp -and (Test-IsAdmin)) {
    $dhcpInfo = Get-DhcpAdapterInfo
    if ($dhcpInfo) {
        $ok = Set-StaticIpFromDhcp -DhcpInfo $dhcpInfo
        if ($ok) {
            [System.Windows.Forms.MessageBox]::Show("Static IP configured successfully on adapter '$($dhcpInfo.Alias)'!", "Static IP Applied", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [System.Windows.Forms.MessageBox]::Show("Failed to set static IP. See event logs for details.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
} else {
    $needsElevation = $false
    $reasons = @()
    if (-not (Test-VcRedistInstalled)) { $reasons += "Install missing Visual C++ Redistributable"; $needsElevation = $true }
    $dhcpInfo = Get-DhcpAdapterInfo
    if ($dhcpInfo) { $reasons += "Set static IP for adapter '$($dhcpInfo.Alias)'"; $needsElevation = $true }

    if ($needsElevation) {
        if (-not (Test-IsAdmin)) {
            $msg = "The Bedrock Server Manager recommends the following actions that require Administrator privileges:`n`n"
            foreach ($r in $reasons) { $msg += " • $r`n" }
            $msg += "`nWould you like to restart the manager as Administrator now?`n`n(Any currently running Minecraft server will be safely stopped first.)"
            $result = [System.Windows.Forms.MessageBox]::Show($msg, "Administrator Privileges Needed", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                Stop-Process -Name "bedrock_server" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                $scriptPath = $PSCommandPath
                try {
                    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`" -RootPath `"$RootPath`" -ApplyStaticIp"
                    exit
                } catch {
                    [System.Windows.Forms.MessageBox]::Show("Failed to relaunch as Administrator. You can configure these manually.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                }
            }
        } else {
            if (-not (Test-VcRedistInstalled)) {
                try {
                    $url = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
                    $tempFile = Join-Path $env:TEMP "vc_redist.x64.exe"
                    Write-Host "Downloading Visual C++ Redistributable..."
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing
                    Write-Host "Installing Visual C++ Redistributable..."
                    $proc = Start-Process -FilePath $tempFile -ArgumentList "/install", "/passive", "/norestart" -Wait -PassThru
                    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                        [System.Windows.Forms.MessageBox]::Show("Visual C++ Redistributable installed successfully!", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                    } else {
                        [System.Windows.Forms.MessageBox]::Show("Installation failed or was cancelled.", "Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    }
                    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                } catch {
                    [System.Windows.Forms.MessageBox]::Show("Failed to download or install the dependency: $($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                }
            }
            if ($dhcpInfo) {
                $msg = "Your active network adapter '$($dhcpInfo.Alias)' (IP: $($dhcpInfo.Ip)) is using DHCP (dynamic IP).`n`nFor a stable Minecraft server, a static IP is highly recommended so players don't have to update their IP address when your PC restarts.`n`nWould you like to apply a static IP now using your current settings?"
                $result = [System.Windows.Forms.MessageBox]::Show($msg, "Static IP Recommendation", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $ok = Set-StaticIpFromDhcp -DhcpInfo $dhcpInfo
                    if ($ok) {
                        [System.Windows.Forms.MessageBox]::Show("Static IP configured successfully!", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                    } else {
                        [System.Windows.Forms.MessageBox]::Show("Failed to set static IP.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                    }
                }
            }
        }
    }
}

# ─── Load Assemblies ──────────────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ─── Shared State ─────────────────────────────────────────────────────────────
$script:sharedState = [hashtable]::Synchronized(@{
    RootPath            = if ($RootPath -ne "") { $RootPath } else { "C:\Bedrock" }
    ApiUrl              = "https://net-secondary.web.minecraft-services.net/api/v1.0/download/links"
    ServerExecutable    = "bedrock_server.exe"
    FilesToBackup       = @("server.properties", "allowlist.json", "permissions.json")
    StartAfterUpdate    = $true
    AutoLaunchOnStart   = $false
    CrashProtection     = $true
    AutoApplyUpdates    = $false
    AutoCheckUpdates    = $true
    UpdateCheckHours    = 24
    MaxBackups          = 3
    LogRetentionDays    = 30
    ServerStopTimeout   = 15
    DownloadTimeout     = 180
    LatestUrl           = $null
    LatestFilename      = $null
    LatestVersion       = $null
    InstalledVersion    = $null
    IsBusy              = $false
    IsInstalled         = $false
    IsRunning           = $false
    UpdateAvailable     = $false
    ExpectedToRun       = $false
    ServerStartTime     = $null
    PendingMessages     = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    PendingStatus       = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    PendingButtons      = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    StopRequested       = $false
    GuiReady            = $false
    WindowClosed        = $false
    ServerProcess       = $null
    ServerConsoleMessages = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    PendingServerCommands = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    ServerConsoleHistory  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    MaxServerConsoleLines = 2000
    ServerOutputReader  = $null
    ServerProcessId     = $null
    FirewallRuleVerified = $false
    RestoreZipPath      = $null
    StdInWriteLock      = [Object]::new()
    TypeCompileLock     = [Object]::new()
    ProgressLock        = [Object]::new()
    PendingProgress     = @{ Type = "none"; Value = 0 }
})

$script:sharedState.ServerPath     = Join-Path $script:sharedState.RootPath "Server"
$script:sharedState.BackupPath     = Join-Path $script:sharedState.RootPath "Backups"
$script:sharedState.LogsPath       = Join-Path $script:sharedState.RootPath "Logs"
$script:sharedState.UpdateTempPath = Join-Path $script:sharedState.RootPath "UpdateTemp"

# ─── XAML ─────────────────────────────────────────────────────────────────────
$xamlString = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Minecraft Bedrock Server Manager v28.4"
    Width="1280" Height="780"
    MinWidth="1000" MinHeight="600"
    WindowStartupLocation="CenterScreen"
    WindowState="Maximized"
    Background="#F0F2F5">

    <Window.Resources>
        <SolidColorBrush x:Key="AccentGreen"    Color="#2E7D32"/>
        <SolidColorBrush x:Key="AccentBlue"     Color="#1565C0"/>
        <SolidColorBrush x:Key="AccentRed"      Color="#C62828"/>
        <SolidColorBrush x:Key="AccentOrange"   Color="#E65100"/>
        <SolidColorBrush x:Key="AccentGray"     Color="#546E7A"/>

        <SolidColorBrush x:Key="BgCard"         Color="#FFFFFF"/>
        <SolidColorBrush x:Key="BgInput"        Color="#FAFAFA"/>
        <SolidColorBrush x:Key="BorderDefault"  Color="#E0E0E0"/>
        <SolidColorBrush x:Key="TextPrimary"    Color="#212121"/>
        <SolidColorBrush x:Key="TextSecondary"  Color="#616161"/>
        <SolidColorBrush x:Key="TextMuted"      Color="#9E9E9E"/>

        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize"   Value="11"/>
            <Setter Property="Padding"    Value="12,6"/>
            <Setter Property="Margin"     Value="3,3"/>
            <Setter Property="Cursor"     Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="border" Property="Opacity" Value="0.85"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="border" Property="Opacity" Value="0.40"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="border" Property="Opacity" Value="0.70"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background"      Value="{StaticResource BgCard}"/>
            <Setter Property="BorderBrush"     Value="{StaticResource BorderDefault}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius"    Value="5"/>
            <Setter Property="Padding"         Value="10,8"/>
            <Setter Property="Margin"          Value="3,3"/>
        </Style>

        <Style x:Key="StatLabel" TargetType="TextBlock">
            <Setter Property="FontSize" Value="9"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="Margin" Value="0,0,0,2"/>
        </Style>

        <Style x:Key="StatValue" TargetType="TextBlock">
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
        </Style>

        <Style x:Key="InfoKey" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <Style x:Key="InfoVal" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <Style x:Key="LightTextBox" TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource BgInput}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderDefault}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="CaretBrush" Value="{StaticResource TextPrimary}"/>
            <Setter Property="SelectionBrush" Value="#1565C0"/>
        </Style>

        <Style x:Key="SettingsCheckBox" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Margin" Value="0,0,15,0"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
    </Window.Resources>

    <Grid Margin="12,10,12,10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- 0 HEADER -->
        <Grid Grid.Row="0" Margin="2,0,2,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock Text="Minecraft Bedrock Server Manager" FontSize="18" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                <TextBlock Text="v28.4 — Dual Console Edition" FontSize="10" Foreground="{StaticResource TextMuted}" Margin="0,2,0,0"/>
            </StackPanel>
            <Border Grid.Column="1" Background="{StaticResource BgCard}" BorderBrush="{StaticResource BorderDefault}" BorderThickness="1" CornerRadius="4" Padding="8,5" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="dotPeriodic" Width="8" Height="8" Fill="{StaticResource AccentGray}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <TextBlock x:Name="lblNextCheck" Text="Auto-check: —" Foreground="{StaticResource TextSecondary}" FontSize="10.5" VerticalAlignment="Center"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- 1 ROOT PATH BAR -->
        <Border Grid.Row="1" Style="{StaticResource Card}">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Root Directory" Style="{StaticResource InfoKey}" Margin="0,0,10,0"/>
                <TextBox Grid.Column="1" x:Name="txtRootPath" Style="{StaticResource LightTextBox}"/>
                <Button Grid.Column="2" x:Name="btnBrowse" Content="Browse…" Background="{StaticResource AccentGray}" Style="{StaticResource ActionButton}"/>
                <Button Grid.Column="3" x:Name="btnOpenFolder" Content="Explorer" Background="{StaticResource AccentGray}" Style="{StaticResource ActionButton}"/>
            </Grid>
        </Border>

        <!-- 2 STAT CARDS -->
        <Grid Grid.Row="2" Margin="3,3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="1.2*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Style="{StaticResource Card}">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="VERSIONS" Style="{StaticResource StatLabel}"/>
                    <TextBlock Grid.Row="1" Grid.Column="0" Text="Installed: " FontSize="11" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center" Margin="0,3,0,0"/>
                    <TextBlock Grid.Row="1" Grid.Column="1" x:Name="lblInstalled" Text="—" Style="{StaticResource StatValue}" Margin="0,3,0,0"/>
                    <TextBlock Grid.Row="2" Grid.Column="0" Text="Latest: " FontSize="11" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center" Margin="0,4,0,0"/>
                    <TextBlock Grid.Row="2" Grid.Column="1" x:Name="lblLatest" Text="—" Style="{StaticResource StatValue}" Foreground="{StaticResource AccentBlue}" Margin="0,4,0,0"/>
                </Grid>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource Card}">
                <StackPanel>
                    <TextBlock Text="SYSTEM STATUS" Style="{StaticResource StatLabel}"/>
                    <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
                        <TextBlock Text="Status: " FontSize="11" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center"/>
                        <TextBlock x:Name="lblServerStatus" Text="—" Style="{StaticResource StatValue}" Foreground="{StaticResource AccentOrange}"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                        <TextBlock Text="Setup: " FontSize="11" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center"/>
                        <TextBlock x:Name="lblSetupStatus" Text="—" Style="{StaticResource StatValue}"/>
                    </StackPanel>
                </StackPanel>
            </Border>
            <Border Grid.Column="2" Style="{StaticResource Card}">
                <StackPanel>
                    <TextBlock Text="CONNECTION" Style="{StaticResource StatLabel}"/>
                    <TextBlock x:Name="lblHostname" Text="—" Style="{StaticResource StatValue}" Margin="0,3,0,0"/>
                    <TextBlock x:Name="lblIpPort" Text="—" Style="{StaticResource StatValue}" Foreground="{StaticResource AccentBlue}" Margin="0,4,0,0"/>
                </StackPanel>
            </Border>
            <Border Grid.Column="3" Style="{StaticResource Card}">
                <StackPanel>
                    <TextBlock Text="UPDATE STATUS" Style="{StaticResource StatLabel}"/>
                    <TextBlock x:Name="lblUpdateStatus" Text="—" Style="{StaticResource StatValue}" Foreground="{StaticResource AccentGray}" Margin="0,3,0,0"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- 3 INFO / PATHS / SYSTEM CARD -->
        <Border Grid.Row="3" Style="{StaticResource Card}">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0" Grid.Column="0" Margin="0,0,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Server Dir:" Style="{StaticResource InfoKey}"/>
                    <TextBlock Grid.Column="1" x:Name="lblInstallDir" Text="—" Style="{StaticResource InfoVal}" Foreground="{StaticResource AccentBlue}" TextDecorations="Underline" Cursor="Hand"/>
                </Grid>
                <Rectangle Grid.Row="0" Grid.Column="1" Fill="{StaticResource BorderDefault}" Width="1" HorizontalAlignment="Center"/>
                <Grid Grid.Row="0" Grid.Column="2" Margin="0,0,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="PC Uptime:" Style="{StaticResource InfoKey}"/>
                    <TextBlock Grid.Column="1" x:Name="lblPcUptime" Text="—" Style="{StaticResource InfoVal}"/>
                </Grid>
                <Grid Grid.Row="1" Grid.Column="0" Margin="0,0,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Backups Dir:" Style="{StaticResource InfoKey}"/>
                    <TextBlock Grid.Column="1" x:Name="lblBackupDir" Text="—" Style="{StaticResource InfoVal}" Foreground="{StaticResource AccentBlue}" TextDecorations="Underline" Cursor="Hand"/>
                </Grid>
                <Rectangle Grid.Row="1" Grid.Column="1" Fill="{StaticResource BorderDefault}" Width="1" HorizontalAlignment="Center"/>
                <Grid Grid.Row="1" Grid.Column="2" Margin="0,0,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Server Up:" Style="{StaticResource InfoKey}"/>
                    <TextBlock Grid.Column="1" x:Name="lblServerUptime" Text="—" Style="{StaticResource InfoVal}"/>
                </Grid>
                <Grid Grid.Row="2" Grid.Column="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Logs Dir:" Style="{StaticResource InfoKey}"/>
                    <TextBlock Grid.Column="1" x:Name="lblLogFile" Text="—" Style="{StaticResource InfoVal}" Foreground="{StaticResource AccentBlue}" TextDecorations="Underline" Cursor="Hand"/>
                </Grid>
                <Rectangle Grid.Row="2" Grid.Column="1" Fill="{StaticResource BorderDefault}" Width="1" HorizontalAlignment="Center"/>
                <Grid Grid.Row="2" Grid.Column="2">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Last Backup:" Style="{StaticResource InfoKey}"/>
                    <TextBlock Grid.Column="1" x:Name="lblLastBackup" Text="—" Style="{StaticResource InfoVal}"/>
                </Grid>
            </Grid>
        </Border>

        <!-- 4 SETTINGS BAR -->
        <Border Grid.Row="4" Style="{StaticResource Card}">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <WrapPanel Grid.Column="0" VerticalAlignment="Center">
                    <CheckBox x:Name="chkAutoStart" Content="Auto-start after update" Style="{StaticResource SettingsCheckBox}" IsChecked="True"/>
                    <CheckBox x:Name="chkAutoLaunch" Content="Auto-launch on GUI start" Style="{StaticResource SettingsCheckBox}" IsChecked="False"/>
                    <CheckBox x:Name="chkCrashProtect" Content="Crash Protection" Style="{StaticResource SettingsCheckBox}" IsChecked="True"/>
                    <CheckBox x:Name="chkAutoCheckUpdates" Content="Check every:" Style="{StaticResource SettingsCheckBox}" IsChecked="True"/>
                    <TextBox x:Name="txtInterval" Width="35" Text="24" VerticalAlignment="Center" Style="{StaticResource LightTextBox}" Padding="3,4"/>
                    <TextBlock Text="hrs" VerticalAlignment="Center" Margin="4,0,15,0" Foreground="{StaticResource TextSecondary}" FontSize="11"/>
                    <CheckBox x:Name="chkAutoApplyUpdates" Content="Auto-apply" Style="{StaticResource SettingsCheckBox}" IsChecked="False"/>
                    <TextBlock Text="Keep Backups:" VerticalAlignment="Center" Margin="15,0,4,0" Foreground="{StaticResource TextSecondary}" FontSize="11"/>
                    <TextBox x:Name="txtMaxBackups" Width="35" Text="3" VerticalAlignment="Center" Style="{StaticResource LightTextBox}" Padding="3,4"/>
                </WrapPanel>
                <Button Grid.Column="1" x:Name="btnApplySettings" Content="Apply Settings" Background="{StaticResource AccentBlue}" Style="{StaticResource ActionButton}"/>
            </Grid>
        </Border>

        <!-- 5 BUTTON BAR -->
        <Border Grid.Row="5" Style="{StaticResource Card}" Margin="3,3,3,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <WrapPanel Grid.Column="0" VerticalAlignment="Center" HorizontalAlignment="Center">
                    <Button x:Name="btnFirstSetup" Content="⬇ Setup / Install" Background="{StaticResource AccentBlue}" Style="{StaticResource ActionButton}"/>
                    <Button x:Name="btnCheckUpdate" Content="🔍 Check Updates" Background="{StaticResource AccentBlue}" Style="{StaticResource ActionButton}"/>
                    <Button x:Name="btnUpdate" Content="⬆ Download and Update" Background="{StaticResource AccentGreen}" Style="{StaticResource ActionButton}" IsEnabled="False"/>
                    <Button x:Name="btnStartServer" Content="▶ Start Server" Background="{StaticResource AccentGreen}" Style="{StaticResource ActionButton}"/>
                    <Button x:Name="btnStopServer" Content="■ Stop Server" Background="{StaticResource AccentRed}" Style="{StaticResource ActionButton}"/>
                    <Button x:Name="btnRefresh" Content="↻ Refresh Status" Background="{StaticResource AccentOrange}" Style="{StaticResource ActionButton}"/>
                    <Button x:Name="btnBackupNow" Content="💾 Backup Now" Background="{StaticResource AccentGray}" Style="{StaticResource ActionButton}" IsEnabled="False"/>
                    <Button x:Name="btnRestoreBackup" Content="⏪ Restore Backup" Background="{StaticResource AccentGray}" Style="{StaticResource ActionButton}" IsEnabled="False"/>
                </WrapPanel>
                <TextBlock Grid.Column="1" x:Name="lblFooter" Text="v28.4" Foreground="{StaticResource TextMuted}" FontSize="10" VerticalAlignment="Center" Margin="10,0,0,0"/>
            </Grid>
        </Border>

        <!-- 6 PROGRESS -->
        <Grid Grid.Row="6" Margin="3,2,3,2">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <ProgressBar x:Name="progressBar" Grid.Row="0" Height="4" Minimum="0" Maximum="100" Value="0" Background="#E0E0E0" Foreground="{StaticResource AccentGreen}" BorderThickness="0"/>
            <TextBlock x:Name="lblProgressText" Grid.Row="1" Text="" FontSize="10" Foreground="{StaticResource TextMuted}" Margin="4,2,0,0" Visibility="Collapsed"/>
        </Grid>

        <!-- 7 DUAL CONSOLES -->
        <Grid Grid.Row="7" Margin="3,3,3,3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="5"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- LEFT: PowerShell / Manager Console -->
            <Border Grid.Column="0" BorderBrush="{StaticResource BorderDefault}" BorderThickness="1" CornerRadius="5">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" Background="{StaticResource BgCard}" CornerRadius="5,5,0,0" Padding="10,6" BorderBrush="{StaticResource BorderDefault}" BorderThickness="0,0,0,1">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="PowerShell Console (Manager)" Foreground="{StaticResource TextPrimary}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" Margin="5,0,0,0"/>
                            <Button Grid.Column="1" x:Name="btnClearLog" Content="Clear" Background="{StaticResource AccentGray}" Style="{StaticResource ActionButton}" Padding="10,4"/>
                        </Grid>
                    </Border>
                    <RichTextBox x:Name="rtbLog" Grid.Row="1" Background="#012456" Foreground="#EEEEEE" BorderThickness="0" IsReadOnly="True" VerticalScrollBarVisibility="Auto" FontFamily="Consolas,Courier New" FontSize="11" Padding="8,6">
                        <RichTextBox.Resources>
                            <Style TargetType="Paragraph">
                                <Setter Property="Margin" Value="0,1,0,1"/>
                                <Setter Property="LineHeight" Value="14"/>
                            </Style>
                        </RichTextBox.Resources>
                    </RichTextBox>
                </Grid>
            </Border>

            <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Background="{StaticResource BorderDefault}"/>

            <!-- RIGHT: Server stdin/stdout Console (.NET Wrapper) -->
            <Border Grid.Column="2" BorderBrush="{StaticResource BorderDefault}" BorderThickness="1" CornerRadius="5">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" Background="{StaticResource BgCard}" CornerRadius="5,5,0,0" Padding="10,6" BorderBrush="{StaticResource BorderDefault}" BorderThickness="0,0,0,1">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="Server Console (stdin/stdout)" Foreground="{StaticResource TextPrimary}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" Margin="5,0,0,0"/>
                            <Button Grid.Column="1" x:Name="btnClearServerLog" Content="Clear" Background="{StaticResource AccentGray}" Style="{StaticResource ActionButton}" Padding="10,4"/>
                        </Grid>
                    </Border>
                    <RichTextBox x:Name="rtbServerLog" Grid.Row="1" Background="#1E1E1E" Foreground="#DCDCDC" BorderThickness="0" IsReadOnly="True" VerticalScrollBarVisibility="Auto" FontFamily="Consolas,Courier New" FontSize="11" Padding="8,6">
                        <RichTextBox.Resources>
                            <Style TargetType="Paragraph">
                                <Setter Property="Margin" Value="0,1,0,1"/>
                                <Setter Property="LineHeight" Value="14"/>
                            </Style>
                        </RichTextBox.Resources>
                    </RichTextBox>
                    <Border Grid.Row="2" Background="{StaticResource BgCard}" BorderBrush="{StaticResource BorderDefault}" BorderThickness="0,1,0,0" Padding="6,5">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text=">" FontWeight="Bold" Foreground="{StaticResource AccentGreen}" VerticalAlignment="Center" Margin="4,0,6,0" FontFamily="Consolas"/>
                            <TextBox Grid.Column="1" x:Name="txtServerCommand" Style="{StaticResource LightTextBox}" Tag="Type a server command and press Enter (e.g. say hello, list, stop)"/>
                            <Button Grid.Column="2" x:Name="btnSendCommand" Content="Send" Background="{StaticResource AccentGreen}" Style="{StaticResource ActionButton}" Padding="14,4"/>
                        </Grid>
                    </Border>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Window>
"@

# ─── GUI Runspace ─────────────────────────────────────────────────────────────
$guiRunspace = [RunspaceFactory]::CreateRunspace()
$guiRunspace.ApartmentState = "STA"
$guiRunspace.ThreadOptions  = "ReuseThread"
$guiRunspace.Open()
$guiRunspace.SessionStateProxy.SetVariable("sharedState", $script:sharedState)
$guiRunspace.SessionStateProxy.SetVariable("xamlString",  $xamlString)

$guiPowerShell = [PowerShell]::Create()
$guiPowerShell.Runspace = $guiRunspace

$guiPowerShell.AddScript({

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    [xml]$xaml = $xamlString
    $reader    = [System.Xml.XmlNodeReader]::new($xaml)
    $window    = [Windows.Markup.XamlReader]::Load($reader)

    # ── Config Persistence (INI) ────────────────────────────────────────────
    $configDir  = Join-Path $env:APPDATA "BedrockServerManager"
    $configPath = Join-Path $configDir "config.ini"

    function Save-Config {
        if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
        $lines = @(
            "[Settings]",
            "RootPath=$($sharedState.RootPath)",
            "StartAfterUpdate=$($sharedState.StartAfterUpdate)",
            "AutoLaunchOnStart=$($sharedState.AutoLaunchOnStart)",
            "CrashProtection=$($sharedState.CrashProtection)",
            "AutoCheckUpdates=$($sharedState.AutoCheckUpdates)",
            "UpdateCheckHours=$($sharedState.UpdateCheckHours)",
            "AutoApplyUpdates=$($sharedState.AutoApplyUpdates)",
            "LogRetentionDays=$($sharedState.LogRetentionDays)",
            "MaxBackups=$($sharedState.MaxBackups)"
        )
        $lines | Set-Content -Path $configPath -Force -ErrorAction SilentlyContinue
    }

    function Load-Config {
        if (Test-Path $configPath) {
            try {
                $content = Get-Content -Path $configPath -ErrorAction Stop
                foreach ($line in $content) {
                    if ($line -match "^\s*([^=]+)\s*=\s*(.*)$") {
                        $key = $matches[1].Trim()
                        $val = $matches[2].Trim()
                        switch ($key) {
                            "RootPath"            { $sharedState.RootPath = $val }
                            "StartAfterUpdate"    { $sharedState.StartAfterUpdate = ($val -eq 'True') }
                            "AutoLaunchOnStart"   { $sharedState.AutoLaunchOnStart = ($val -eq 'True') }
                            "CrashProtection"     { $sharedState.CrashProtection = ($val -eq 'True') }
                            "AutoCheckUpdates"    { $sharedState.AutoCheckUpdates = ($val -eq 'True') }
                            "UpdateCheckHours"    { $sharedState.UpdateCheckHours = [int]$val }
                            "AutoApplyUpdates"    { $sharedState.AutoApplyUpdates = ($val -eq 'True') }
                            "LogRetentionDays"    { $sharedState.LogRetentionDays = [int]$val }
                            "MaxBackups"          { $sharedState.MaxBackups = [int]$val }
                        }
                    }
                }
            } catch { }
        }
        $sharedState.ServerPath     = Join-Path $sharedState.RootPath "Server"
        $sharedState.BackupPath     = Join-Path $sharedState.RootPath "Backups"
        $sharedState.LogsPath       = Join-Path $sharedState.RootPath "Logs"
        $sharedState.UpdateTempPath = Join-Path $sharedState.RootPath "UpdateTemp"
    }

    Load-Config

    # Control References
    $txtRootPath         = $window.FindName("txtRootPath")
    $btnBrowse           = $window.FindName("btnBrowse")
    $btnOpenFolder       = $window.FindName("btnOpenFolder")
    $lblInstalled        = $window.FindName("lblInstalled")
    $lblLatest           = $window.FindName("lblLatest")
    $lblServerStatus     = $window.FindName("lblServerStatus")
    $lblHostname         = $window.FindName("lblHostname")
    $lblIpPort           = $window.FindName("lblIpPort")
    $lblSetupStatus      = $window.FindName("lblSetupStatus")
    $lblUpdateStatus     = $window.FindName("lblUpdateStatus")
    $lblInstallDir       = $window.FindName("lblInstallDir")
    $lblBackupDir        = $window.FindName("lblBackupDir")
    $lblPcUptime         = $window.FindName("lblPcUptime")
    $lblLogFile          = $window.FindName("lblLogFile")
    $lblServerUptime     = $window.FindName("lblServerUptime")
    $lblLastBackup       = $window.FindName("lblLastBackup")
    $lblNextCheck        = $window.FindName("lblNextCheck")
    $dotPeriodic         = $window.FindName("dotPeriodic")
    $progressBar         = $window.FindName("progressBar")
    $lblProgressText     = $window.FindName("lblProgressText")
    $chkAutoStart        = $window.FindName("chkAutoStart")
    $chkAutoLaunch       = $window.FindName("chkAutoLaunch")
    $chkCrashProtect     = $window.FindName("chkCrashProtect")
    $chkAutoCheckUpdates = $window.FindName("chkAutoCheckUpdates")
    $chkAutoApplyUpdates = $window.FindName("chkAutoApplyUpdates")
    $txtInterval         = $window.FindName("txtInterval")
    $txtMaxBackups       = $window.FindName("txtMaxBackups")
    $btnApplySettings    = $window.FindName("btnApplySettings")

    $rtbLog              = $window.FindName("rtbLog")
    $rtbServerLog        = $window.FindName("rtbServerLog")
    $txtServerCommand    = $window.FindName("txtServerCommand")
    $btnSendCommand      = $window.FindName("btnSendCommand")
    $btnClearLog         = $window.FindName("btnClearLog")
    $btnClearServerLog   = $window.FindName("btnClearServerLog")

    $btnFirstSetup       = $window.FindName("btnFirstSetup")
    $btnCheckUpdate      = $window.FindName("btnCheckUpdate")
    $btnUpdate           = $window.FindName("btnUpdate")
    $btnStartServer      = $window.FindName("btnStartServer")
    $btnStopServer       = $window.FindName("btnStopServer")
    $btnRefresh          = $window.FindName("btnRefresh")
    $btnBackupNow        = $window.FindName("btnBackupNow")
    $btnRestoreBackup    = $window.FindName("btnRestoreBackup")

    # Sync UI with loaded config
    $txtRootPath.Text             = $sharedState.RootPath
    $chkAutoStart.IsChecked       = $sharedState.StartAfterUpdate
    $chkAutoLaunch.IsChecked      = $sharedState.AutoLaunchOnStart
    $chkCrashProtect.IsChecked    = $sharedState.CrashProtection
    $chkAutoCheckUpdates.IsChecked = $sharedState.AutoCheckUpdates
    $chkAutoApplyUpdates.IsChecked = $sharedState.AutoApplyUpdates
    $txtInterval.Text             = $sharedState.UpdateCheckHours
    $txtMaxBackups.Text           = $sharedState.MaxBackups

    $lblHostname.Text = [System.Net.Dns]::GetHostName()

    $lblInstallDir.Add_MouseLeftButtonUp({ $p = $sharedState.ServerPath; if (Test-Path $p) { Start-Process explorer.exe -ArgumentList """$p""" } })
    $lblBackupDir.Add_MouseLeftButtonUp({ $p = $sharedState.BackupPath; if (Test-Path $p) { Start-Process explorer.exe -ArgumentList """$p""" } else { [System.Windows.MessageBox]::Show("Backup folder does not exist yet.", "Not Found", "OK", "Information") | Out-Null } })
    $lblLogFile.Add_MouseLeftButtonUp({ $p = Join-Path $sharedState.LogsPath "BedrockServerManager_$(Get-Date -Format 'yyyyMMdd').log"; if (Test-Path $p) { Start-Process notepad.exe -ArgumentList """$p""" } else { [System.Windows.MessageBox]::Show("Log file does not exist yet.", "Not Found", "OK", "Information") | Out-Null } })

    function Update-PathLabels {
        $lblInstallDir.Text = $sharedState.ServerPath
        $lblBackupDir.Text  = $sharedState.BackupPath
        $lblLogFile.Text    = Join-Path $sharedState.LogsPath "BedrockServerManager_$(Get-Date -Format 'yyyyMMdd').log"
    }
    Update-PathLabels

    $colourMap = @{
        "INFO"     = "#EEEEEE"
        "WARN"     = "#FFB347"
        "ERROR"    = "#FF6B6B"
        "SUCCESS"  = "#2ECC71"
        "HEADER"   = "#5DADE2"
        "SYSTEM"   = "#A0A0A0"
        "PERIODIC" = "#BB8FCE"
    }
    $statusColourMap = @{
        "green"  = "#2E7D32"
        "blue"   = "#1565C0"
        "red"    = "#C62828"
        "orange" = "#E65100"
        "gray"   = "#546E7A"
        "white"  = "#212121"
    }
    $serverColourMap = @{
        "INFO"    = "#DCDCDC"
        "WARN"    = "#FFD27F"
        "ERROR"   = "#FF7B7B"
        "SUCCESS" = "#9CCC65"
        "CMD"     = "#80CBC4"
        "SYSTEM"  = "#90A4AE"
    }

    $brushCache = @{}
    foreach ($key in $colourMap.Keys) {
        $br = [System.Windows.Media.BrushConverter]::new().ConvertFromString($colourMap[$key]); $br.Freeze(); $brushCache[$key] = $br
    }
    $statusBrushCache = @{}
    foreach ($key in $statusColourMap.Keys) {
        $br = [System.Windows.Media.BrushConverter]::new().ConvertFromString($statusColourMap[$key]); $br.Freeze(); $statusBrushCache[$key] = $br
    }
    $serverBrushCache = @{}
    foreach ($key in $serverColourMap.Keys) {
        $br = [System.Windows.Media.BrushConverter]::new().ConvertFromString($serverColourMap[$key]); $br.Freeze(); $serverBrushCache[$key] = $br
    }

    function Update-ButtonStates {
        if ($sharedState.IsBusy) {
            $btnFirstSetup.IsEnabled  = $false
            $btnCheckUpdate.IsEnabled = $false
            $btnUpdate.IsEnabled      = $false
            $btnStartServer.IsEnabled = $false
            $btnStopServer.IsEnabled  = $false
            $btnRefresh.IsEnabled     = $false
            $btnBrowse.IsEnabled      = $false
            $btnOpenFolder.IsEnabled  = $false
            $txtRootPath.IsEnabled    = $false
            $btnApplySettings.IsEnabled = $false
            $btnBackupNow.IsEnabled   = $false
            $btnRestoreBackup.IsEnabled = $false
        } else {
            $btnFirstSetup.IsEnabled  = -not $sharedState.IsInstalled
            $btnCheckUpdate.IsEnabled = $sharedState.IsInstalled
            $btnUpdate.IsEnabled      = $sharedState.UpdateAvailable -and -not $sharedState.AutoApplyUpdates
            $btnStartServer.IsEnabled = $sharedState.IsInstalled -and -not $sharedState.IsRunning
            $btnStopServer.IsEnabled  = $sharedState.IsRunning
            $btnRefresh.IsEnabled     = $true
            $btnBrowse.IsEnabled      = $true
            $btnOpenFolder.IsEnabled  = $true
            $txtRootPath.IsEnabled    = $true
            $btnApplySettings.IsEnabled = $true
            $canBackupRestore = $sharedState.IsInstalled -and -not $sharedState.IsRunning
            $btnBackupNow.IsEnabled     = $canBackupRestore
            $btnRestoreBackup.IsEnabled = $canBackupRestore
        }
        $canSendCmd = $sharedState.IsRunning -and $sharedState.ServerProcess -and -not $sharedState.ServerProcess.HasExited
        $txtServerCommand.IsEnabled = $canSendCmd
        $btnSendCommand.IsEnabled   = $canSendCmd
    }

    $script:activeJobs = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    $script:nextUpdateCheck = [datetime]::Now.AddHours($sharedState.UpdateCheckHours)
    $script:lastGcTime = [datetime]::Now
    $script:pcBootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $script:tickCount = 0
    $script:commandHistoryIdx = -1

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({

        # Guard: don't process if window is closed
        if ($sharedState.WindowClosed) { return }

        # 1. Process Pending Manager Messages
        $msgCount = [Math]::Min(50, $sharedState.PendingMessages.Count)
        if ($msgCount -gt 0) {
            $msgs = @()
            [System.Threading.Monitor]::Enter($sharedState.PendingMessages.SyncRoot)
            try {
                $msgs = $sharedState.PendingMessages.GetRange(0, $msgCount).ToArray()
                $sharedState.PendingMessages.RemoveRange(0, $msgCount)
            } catch {
                $msgs = $sharedState.PendingMessages.ToArray()
                $sharedState.PendingMessages.Clear()
            } finally {
                [System.Threading.Monitor]::Exit($sharedState.PendingMessages.SyncRoot)
            }
            foreach ($m in $msgs) {
                $c = if ($brushCache.ContainsKey($m.Level)) { $brushCache[$m.Level] } else { $brushCache["INFO"] }
                $para = New-Object System.Windows.Documents.Paragraph
                $run  = New-Object System.Windows.Documents.Run($m.Text)
                $run.Foreground = $c
                $para.Inlines.Add($run)
                $rtbLog.Document.Blocks.Add($para)
            }
            while ($rtbLog.Document.Blocks.Count -gt 500) {
                $block = $rtbLog.Document.Blocks.FirstBlock
                $rtbLog.Document.Blocks.Remove($block)
                if ($block) { $block.Clear() }
            }
            $rtbLog.ScrollToEnd()
        }

        # 1b. Process Pending Manager Server Console Messages
        $srvCount = [Math]::Min(100, $sharedState.ServerConsoleMessages.Count)
        if ($srvCount -gt 0) {
            $smsgs = @()
            [System.Threading.Monitor]::Enter($sharedState.ServerConsoleMessages.SyncRoot)
            try {
                $smsgs = $sharedState.ServerConsoleMessages.GetRange(0, $srvCount).ToArray()
                $sharedState.ServerConsoleMessages.RemoveRange(0, $srvCount)
            } catch {
                $smsgs = $sharedState.ServerConsoleMessages.ToArray()
                $sharedState.ServerConsoleMessages.Clear()
            } finally {
                [System.Threading.Monitor]::Exit($sharedState.ServerConsoleMessages.SyncRoot)
            }
            foreach ($m in $smsgs) {
                $c = if ($serverBrushCache.ContainsKey($m.Level)) { $serverBrushCache[$m.Level] } else { $serverBrushCache["INFO"] }
                $para = New-Object System.Windows.Documents.Paragraph
                $run  = New-Object System.Windows.Documents.Run($m.Text)
                $run.Foreground = $c
                $para.Inlines.Add($run)
                $rtbServerLog.Document.Blocks.Add($para)
            }
            while ($rtbServerLog.Document.Blocks.Count -gt $sharedState.MaxServerConsoleLines) {
                $block = $rtbServerLog.Document.Blocks.FirstBlock
                $rtbServerLog.Document.Blocks.Remove($block)
                if ($block) { $block.Clear() }
            }
            $rtbServerLog.ScrollToEnd()
        }

        # 1c. Process Native Server Output Queues
        $currentReader = $sharedState.ServerOutputReader
        if ($currentReader) {
            $hasOutput = $false
            $queue = $currentReader.OutputQueue
            $readCount = 0
            while ($readCount -lt 100) {
                $line = ""
                if (-not $queue.TryDequeue([ref]$line)) { break }
                
                $level = "INFO"
                if ($line -match "ERROR|FATAL|crashed") { $level = "ERROR" }
                elseif ($line -match "WARN|Warning") { $level = "WARN" }
                elseif ($line -match "Player connected|Player disconnected|Server started|done") { $level = "SUCCESS" }
                
                $c = if ($serverBrushCache.ContainsKey($level)) { $serverBrushCache[$level] } else { $serverBrushCache["INFO"] }
                $para = New-Object System.Windows.Documents.Paragraph
                $run  = New-Object System.Windows.Documents.Run($line)
                $run.Foreground = $c
                $para.Inlines.Add($run)
                $rtbServerLog.Document.Blocks.Add($para)
                $readCount++
                $hasOutput = $true
            }
            
            $errQueue = $currentReader.ErrorQueue
            while ($true) {
                $line = ""
                if (-not $errQueue.TryDequeue([ref]$line)) { break }
                
                $para = New-Object System.Windows.Documents.Paragraph
                $run  = New-Object System.Windows.Documents.Run($line)
                $run.Foreground = $serverBrushCache["ERROR"]
                $para.Inlines.Add($run)
                $rtbServerLog.Document.Blocks.Add($para)
                $hasOutput = $true
            }

            if ($hasOutput) {
                while ($rtbServerLog.Document.Blocks.Count -gt $sharedState.MaxServerConsoleLines) {
                    $block = $rtbServerLog.Document.Blocks.FirstBlock
                    $rtbServerLog.Document.Blocks.Remove($block)
                    if ($block) { $block.Clear() }
                }
                $rtbServerLog.ScrollToEnd()
            }
        }

        # 1d. Process Pending Server Commands (typed in GUI)
        if ($sharedState.PendingServerCommands.Count -gt 0) {
            $cmds = @()
            [System.Threading.Monitor]::Enter($sharedState.PendingServerCommands.SyncRoot)
            try { $cmds = $sharedState.PendingServerCommands.ToArray(); $sharedState.PendingServerCommands.Clear() }
            finally { [System.Threading.Monitor]::Exit($sharedState.PendingServerCommands.SyncRoot) }
            foreach ($c in $cmds) {
                $sp = $sharedState.ServerProcess
                if ($sp -and -not $sp.HasExited) {
                    try {
                        [System.Threading.Monitor]::Enter($sharedState.StdInWriteLock)
                        try {
                            $sp.StandardInput.WriteLine($c)
                            $sp.StandardInput.Flush()
                        } finally { [System.Threading.Monitor]::Exit($sharedState.StdInWriteLock) }
                        [System.Threading.Monitor]::Enter($sharedState.ServerConsoleMessages.SyncRoot)
                        try { $sharedState.ServerConsoleMessages.Add(@{ Text = "> $c"; Level = "CMD" }) | Out-Null }
                        finally { [System.Threading.Monitor]::Exit($sharedState.ServerConsoleMessages.SyncRoot) }

                        # Handle 'stop' command to prevent crash protection from triggering
                        if ($c.Trim().ToLower() -eq "stop") {
                            $sharedState.ExpectedToRun = $false
                        }
                    } catch {
                        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        [System.Threading.Monitor]::Enter($sharedState.PendingMessages.SyncRoot)
                        try { $sharedState.PendingMessages.Add(@{ Text = "$ts [ERROR  ] Failed to send command '$c': $($_.Exception.Message)"; Level = "ERROR" }) | Out-Null }
                        finally { [System.Threading.Monitor]::Exit($sharedState.PendingMessages.SyncRoot) }
                    }
                }
            }
        }

        # 2. Status Updates
        if ($sharedState.PendingStatus.Count -gt 0) {
            $updates = @()
            [System.Threading.Monitor]::Enter($sharedState.PendingStatus.SyncRoot)
            try { $updates = $sharedState.PendingStatus.ToArray(); $sharedState.PendingStatus.Clear() }
            finally { [System.Threading.Monitor]::Exit($sharedState.PendingStatus.SyncRoot) }
            foreach ($u in $updates) {
                $ctrl = $window.FindName($u.Control)
                if ($ctrl) {
                    $ctrl.Text = $u.Text
                    try {
                        if ($statusBrushCache.ContainsKey($u.Colour)) { $ctrl.Foreground = $statusBrushCache[$u.Colour] }
                        else {
                            $dynBr = [System.Windows.Media.BrushConverter]::new().ConvertFromString($u.Colour); $dynBr.Freeze(); $ctrl.Foreground = $dynBr
                        }
                    } catch { }
                }
                if ($u.Control -eq "lblInstallDir" -or $u.Control -eq "txtRootPath") { Update-PathLabels }
            }
        }

        # 3. Progress Bar — read as single atomic snapshot
        [System.Threading.Monitor]::Enter($sharedState.ProgressLock)
        try { $prog = @{ Type = $sharedState.PendingProgress.Type; Value = $sharedState.PendingProgress.Value } }
        finally { [System.Threading.Monitor]::Exit($sharedState.ProgressLock) }
        switch ($prog.Type) {
            "indeterminate" { $progressBar.IsIndeterminate = $true; $lblProgressText.Visibility = [System.Windows.Visibility]::Collapsed }
            "value" {
                $progressBar.IsIndeterminate = $false
                $progressBar.Value = $prog.Value
                $lblProgressText.Text = "$($prog.Value)%"
                $lblProgressText.Visibility = [System.Windows.Visibility]::Visible
            }
            "reset" {
                $progressBar.IsIndeterminate = $false
                $progressBar.Value = 0
                $lblProgressText.Visibility = [System.Windows.Visibility]::Collapsed
                [System.Threading.Monitor]::Enter($sharedState.ProgressLock)
                try { $sharedState.PendingProgress = @{ Type = "none"; Value = 0 } }
                finally { [System.Threading.Monitor]::Exit($sharedState.ProgressLock) }
            }
        }

        # 4. Button State
        if ($sharedState.PendingButtons.Count -gt 0) {
            $btnUpds = @()
            [System.Threading.Monitor]::Enter($sharedState.PendingButtons.SyncRoot)
            try { $btnUpds = $sharedState.PendingButtons.ToArray(); $sharedState.PendingButtons.Clear() }
            finally { [System.Threading.Monitor]::Exit($sharedState.PendingButtons.SyncRoot) }
            foreach ($b in $btnUpds) {
                if ($b.Action -eq "busy") { $sharedState.IsBusy = $true }
                elseif ($b.Action -eq "free") { $sharedState.IsBusy = $false }
            }
        }
        
        # 4b. Check if server process exited and handle cleanup/crash detection
        $sp = $sharedState.ServerProcess
        if ($sp -and $sp.HasExited -and -not $sharedState.IsBusy) {
            $code = $sp.ExitCode
            $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            
            [System.Threading.Monitor]::Enter($sharedState.ServerConsoleMessages.SyncRoot)
            try { $sharedState.ServerConsoleMessages.Add(@{ Text = "[Process exited with code $code]"; Level = "SYSTEM" }) | Out-Null }
            finally { [System.Threading.Monitor]::Exit($sharedState.ServerConsoleMessages.SyncRoot) }

            [System.Threading.Monitor]::Enter($sharedState.PendingMessages.SyncRoot)
            try { $sharedState.PendingMessages.Add(@{ Text = "$ts [WARN   ] Server process exited with code $code."; Level = "WARN" }) | Out-Null }
            finally { [System.Threading.Monitor]::Exit($sharedState.PendingMessages.SyncRoot) }

            if (-not $sharedState.ExpectedToRun) {
                # Graceful exit via 'stop' command or Stop-GameServer
                $sharedState.ServerProcess = $null
                $sharedState.ServerProcessId = $null
                $sharedState.ServerOutputReader = $null
                $sharedState.IsRunning = $false
                $sharedState.ServerStartTime = $null
                $lblServerStatus.Text = "STOPPED"
                $lblServerStatus.Foreground = $statusBrushCache["red"]
                $lblIpPort.Text = "—"
                $lblIpPort.Foreground = $statusBrushCache["gray"]
                Update-ButtonStates
            } else {
                # If ExpectedToRun is true, Crash protection will catch it in the next block.
                # Just clear ServerProcess so we don't loop this message.
                $sharedState.ServerProcess = $null
                $sharedState.ServerProcessId = $null
                $sharedState.ServerOutputReader = $null
            }
        }

        Update-ButtonStates

        # 5. Dashboard Updates (Every ~5 seconds / ~17 ticks @ 300ms)
        $script:tickCount++
        if ($script:tickCount % 17 -eq 0) {
            if ($script:pcBootTime) {
                $pcUp = [timespan]([datetime]::Now - $script:pcBootTime)
                $lblPcUptime.Text = "{0}d {1}h {2}m" -f $pcUp.Days, $pcUp.Hours, $pcUp.Minutes
            }
            if ($sharedState.IsRunning -and $sharedState.ServerStartTime) {
                try {
                    $srvUp = [timespan]([datetime]::Now - $sharedState.ServerStartTime)
                    $lblServerUptime.Text = "{0}d {1}h {2}m" -f $srvUp.Days, $srvUp.Hours, $srvUp.Minutes
                } catch { $lblServerUptime.Text = "—" }
            } else { $lblServerUptime.Text = "—" }
            $backupRoot = $sharedState.BackupPath
            if (Test-Path $backupRoot) {
                $latestZip = Get-ChildItem $backupRoot -Filter "full_backup_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latestZip) { $lblLastBackup.Text = $latestZip.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") } else { $lblLastBackup.Text = "None" }
            } else { $lblLastBackup.Text = "None" }
        }

        # 6. Crash Protection — check by PID if available, fall back to name
        if (-not $sharedState.IsBusy -and $sharedState.ExpectedToRun -and $sharedState.CrashProtection) {
            $exeName = [System.IO.Path]::GetFileNameWithoutExtension($sharedState.ServerExecutable)
            $exePath = Join-Path $sharedState.ServerPath $sharedState.ServerExecutable
            if (Test-Path $exePath) {
                $procFound = $false
                if ($sharedState.ServerProcessId) {
                    try {
                        $byId = Get-Process -Id $sharedState.ServerProcessId -ErrorAction SilentlyContinue
                        if ($byId -and -not $byId.HasExited) { $procFound = $true }
                    } catch { }
                }
                if (-not $procFound) {
                    # Fallback: check by name + path match
                    $byName = Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object {
                        try { $_.Path -eq $exePath } catch { $false }
                    } | Select-Object -First 1
                    if ($byName -and -not $byName.HasExited) {
                        $procFound = $true
                        $sharedState.ServerProcessId = $byName.Id
                    }
                }
                if (-not $procFound -and $sharedState.IsRunning) {
                    $sharedState.IsRunning = $false
                    $sharedState.ServerStartTime = $null
                    $sharedState.ServerProcess = $null
                    $sharedState.ServerProcessId = $null
                    $sharedState.ServerOutputReader = $null
                    $errBrush = $brushCache["ERROR"]
                    $redBrush = $statusBrushCache["red"]
                    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                    $para = New-Object System.Windows.Documents.Paragraph
                    $run  = New-Object System.Windows.Documents.Run("$ts [ERROR  ] Crash detected! Server process missing. Attempting recovery...")
                    $run.Foreground = $errBrush
                    $para.Inlines.Add($run)
                    $rtbLog.Document.Blocks.Add($para)
                    $rtbLog.ScrollToEnd()
                    $lblServerStatus.Text = "CRASHED - RECOVERING"
                    $lblServerStatus.Foreground = $redBrush
                    Start-BackgroundWork -Work { Start-ServerProcess }
                }
            }
        }

        # 7. Periodic Update Check
        if ($sharedState.AutoCheckUpdates -and -not $sharedState.IsBusy) {
            $ts = $script:nextUpdateCheck - [datetime]::Now
            if ($ts.TotalSeconds -le 0) {
                $script:nextUpdateCheck = [datetime]::Now.AddHours($sharedState.UpdateCheckHours)
                $dotPeriodic.Fill = $statusBrushCache["orange"]
                Start-BackgroundWork -Work {
                    Set-Busy $true
                    try { Periodic-StatusCheck } finally { Set-Busy $false }
                }
            } else {
                $hrs = [int]$ts.TotalHours
                $mins = $ts.Minutes
                $lblNextCheck.Text = "Next check: {0}h {1}m" -f $hrs, $mins
                $dotPeriodic.Fill = if ($ts.TotalHours -lt 1) { $statusBrushCache["red"] } else { $statusBrushCache["green"] }
            }
        } else {
            $lblNextCheck.Text = if ($sharedState.AutoCheckUpdates) { "Checking…" } else { "Auto-check: off" }
            $dotPeriodic.Fill = $statusBrushCache["gray"]
        }

        # 8. Cleanup background jobs
        if ($script:activeJobs.Count -gt 0) {
            $completed = @()
            foreach ($job in $script:activeJobs) {
                if ($job.Handle.IsCompleted) {
                    try { $job.PS.EndInvoke($job.Handle) } catch { }
                    try { $job.PS.Dispose() } catch { }
                    try { $job.RS.Close() } catch { }
                    try { $job.RS.Dispose() } catch { }
                    $completed += $job
                }
            }
            if ($completed.Count -gt 0) {
                [System.Threading.Monitor]::Enter($script:activeJobs.SyncRoot)
                try { $completed | ForEach-Object { $script:activeJobs.Remove($_) | Out-Null } }
                finally { [System.Threading.Monitor]::Exit($script:activeJobs.SyncRoot) }
            }
        }

        # 9. GC (Every 5 minutes)
        if (([datetime]::Now - $script:lastGcTime).TotalMinutes -ge 5) {
            $script:lastGcTime = [datetime]::Now
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }

        if ($lblInstallDir.Text -ne $sharedState.ServerPath) { Update-PathLabels }
    })
    $timer.Start()

    # Path / Settings handlers
    $txtRootPath.Add_TextChanged({
        $newPath = $txtRootPath.Text
        # Validate path characters
        $invalid = [System.IO.Path]::GetInvalidPathChars()
        $hasInvalid = $false
        foreach ($c in $invalid) { if ($newPath.Contains($c)) { $hasInvalid = $true; break } }
        if (-not $hasInvalid -and $newPath.Trim() -ne "") {
            $sharedState.RootPath = $newPath
            $sharedState.ServerPath     = Join-Path $sharedState.RootPath "Server"
            $sharedState.BackupPath     = Join-Path $sharedState.RootPath "Backups"
            $sharedState.LogsPath       = Join-Path $sharedState.RootPath "Logs"
            $sharedState.UpdateTempPath = Join-Path $sharedState.RootPath "UpdateTemp"
            Update-PathLabels
        }
    })

    $btnApplySettings.Add_Click({
        $valHrs = 0; $valBak = 0
        if ([int]::TryParse($txtInterval.Text, [ref]$valHrs) -and $valHrs -ge 1 -and
            [int]::TryParse($txtMaxBackups.Text, [ref]$valBak) -and $valBak -ge 1) {
            $sharedState.UpdateCheckHours    = $valHrs
            $script:nextUpdateCheck          = [datetime]::Now.AddHours($valHrs)
            $sharedState.MaxBackups          = $valBak
            $sharedState.StartAfterUpdate    = $chkAutoStart.IsChecked
            $sharedState.AutoLaunchOnStart   = $chkAutoLaunch.IsChecked
            $sharedState.CrashProtection     = $chkCrashProtect.IsChecked
            $sharedState.AutoCheckUpdates    = $chkAutoCheckUpdates.IsChecked
            $sharedState.AutoApplyUpdates    = $chkAutoApplyUpdates.IsChecked
            $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            [System.Threading.Monitor]::Enter($sharedState.PendingMessages.SyncRoot)
            try { $sharedState.PendingMessages.Add(@{ Text = "$ts [SYSTEM ] Settings applied successfully."; Level = "SUCCESS" }) | Out-Null }
            finally { [System.Threading.Monitor]::Exit($sharedState.PendingMessages.SyncRoot) }
            Update-ButtonStates
            Save-Config
        } else {
            [System.Windows.MessageBox]::Show("All numeric fields must be valid integers >= 1.", "Invalid Input", "OK", "Warning")
        }
    })

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description         = "Select root directory (e.g. C:\Bedrock)"
        $dlg.SelectedPath        = $txtRootPath.Text
        $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtRootPath.Text     = $dlg.SelectedPath
            $sharedState.RootPath = $dlg.SelectedPath
            $sharedState.ServerPath     = Join-Path $sharedState.RootPath "Server"
            $sharedState.BackupPath     = Join-Path $sharedState.RootPath "Backups"
            $sharedState.LogsPath       = Join-Path $sharedState.RootPath "Logs"
            $sharedState.UpdateTempPath = Join-Path $sharedState.RootPath "UpdateTemp"
            Update-PathLabels
            Save-Config
        }
    })

    $btnOpenFolder.Add_Click({
        $p = $sharedState.RootPath
        if (Test-Path $p) { Start-Process explorer.exe -ArgumentList """$p""" }
        else { [System.Windows.MessageBox]::Show("Folder does not exist yet.", "Folder Not Found", "OK", "Information") | Out-Null }
    })

    $btnClearLog.Add_Click({ $rtbLog.Document.Blocks.Clear() })
    $btnClearServerLog.Add_Click({ $rtbServerLog.Document.Blocks.Clear() })

    # ─── Server command input handlers ──────────────────────────────────────
    function Send-CommandFromTextBox {
        $cmd = $txtServerCommand.Text
        if ([string]::IsNullOrWhiteSpace($cmd)) { return }
        if (-not $sharedState.IsRunning -or -not $sharedState.ServerProcess) {
            [System.Windows.MessageBox]::Show("Server is not running or was adopted (no stdin available). Stop and restart from GUI to enable command input.", "Cannot send command", "OK", "Warning") | Out-Null
            return
        }
        [System.Threading.Monitor]::Enter($sharedState.PendingServerCommands.SyncRoot)
        try { $sharedState.PendingServerCommands.Add($cmd) | Out-Null }
        finally { [System.Threading.Monitor]::Exit($sharedState.PendingServerCommands.SyncRoot) }

        # Track command history (synchronized)
        [System.Threading.Monitor]::Enter($sharedState.ServerConsoleHistory.SyncRoot)
        try {
            $sharedState.ServerConsoleHistory.Add($cmd) | Out-Null
            $script:commandHistoryIdx = $sharedState.ServerConsoleHistory.Count
        } finally { [System.Threading.Monitor]::Exit($sharedState.ServerConsoleHistory.SyncRoot) }

        $txtServerCommand.Clear()
    }
    $btnSendCommand.Add_Click({ Send-CommandFromTextBox })
    $txtServerCommand.Add_KeyDown({
        if ($_.Key -eq [System.Windows.Input.Key]::Enter) {
            Send-CommandFromTextBox
            $_.Handled = $true
        } elseif ($_.Key -eq [System.Windows.Input.Key]::Up) {
            [System.Threading.Monitor]::Enter($sharedState.ServerConsoleHistory.SyncRoot)
            try {
                if ($sharedState.ServerConsoleHistory.Count -gt 0) {
                    if ($script:commandHistoryIdx -gt 0) { $script:commandHistoryIdx-- }
                    $txtServerCommand.Text = $sharedState.ServerConsoleHistory[$script:commandHistoryIdx]
                    $txtServerCommand.CaretIndex = $txtServerCommand.Text.Length
                }
            } finally { [System.Threading.Monitor]::Exit($sharedState.ServerConsoleHistory.SyncRoot) }
            $_.Handled = $true
        } elseif ($_.Key -eq [System.Windows.Input.Key]::Down) {
            [System.Threading.Monitor]::Enter($sharedState.ServerConsoleHistory.SyncRoot)
            try {
                if ($sharedState.ServerConsoleHistory.Count -gt 0) {
                    if ($script:commandHistoryIdx -lt ($sharedState.ServerConsoleHistory.Count - 1)) {
                        $script:commandHistoryIdx++
                        $txtServerCommand.Text = $sharedState.ServerConsoleHistory[$script:commandHistoryIdx]
                    } else {
                        $script:commandHistoryIdx = $sharedState.ServerConsoleHistory.Count
                        $txtServerCommand.Text = ""
                    }
                    $txtServerCommand.CaretIndex = $txtServerCommand.Text.Length
                }
            } finally { [System.Threading.Monitor]::Exit($sharedState.ServerConsoleHistory.SyncRoot) }
            $_.Handled = $true
        }
    })

    function Append-LogLine {
        param([string]$text, [string]$Level = "INFO")
        [System.Threading.Monitor]::Enter($sharedState.PendingMessages.SyncRoot)
        try { $sharedState.PendingMessages.Add(@{ Text = $text; Level = $Level }) | Out-Null }
        finally { [System.Threading.Monitor]::Exit($sharedState.PendingMessages.SyncRoot) }
    }

    function Append-ServerLine {
        param([string]$text, [string]$Level = "INFO")
        [System.Threading.Monitor]::Enter($sharedState.ServerConsoleMessages.SyncRoot)
        try { $sharedState.ServerConsoleMessages.Add(@{ Text = $text; Level = $Level }) | Out-Null }
        finally { [System.Threading.Monitor]::Exit($sharedState.ServerConsoleMessages.SyncRoot) }
    }

    function Start-BackgroundWork {
        param([ScriptBlock]$Work)
        $bgRS = [RunspaceFactory]::CreateRunspace()
        $bgRS.ApartmentState = "MTA"
        $bgRS.Open()
        $bgRS.SessionStateProxy.SetVariable("state", $sharedState)
        $bgPS = [PowerShell]::Create()
        $bgPS.Runspace = $bgRS

        $helperScript = {

            # ── Compile C# class for process output queue (avoids PS event stalling) ──
            # Guarded by TypeCompileLock to prevent race across concurrent background runspaces
            if (-not ("BedrockProcessReader" -as [type])) {
                [System.Threading.Monitor]::Enter($state.TypeCompileLock)
                try {
                    if (-not ("BedrockProcessReader" -as [type])) {
                        Add-Type -TypeDefinition @"
                        using System;
                        using System.Diagnostics;
                        using System.Collections.Concurrent;

                        public class BedrockProcessReader
                        {
                            public ConcurrentQueue<string> OutputQueue = new ConcurrentQueue<string>();
                            public ConcurrentQueue<string> ErrorQueue = new ConcurrentQueue<string>();
                            
                            public void Attach(Process p)
                            {
                                p.OutputDataReceived += (s, e) => {
                                    if (e.Data != null) OutputQueue.Enqueue(e.Data);
                                };
                                p.ErrorDataReceived += (s, e) => {
                                    if (e.Data != null) ErrorQueue.Enqueue(e.Data);
                                };
                            }
                        }
"@
                    }
                } finally { [System.Threading.Monitor]::Exit($state.TypeCompileLock) }
            }

            function Write-Log {
                param([string]$Message, [string]$Level = "INFO")
                $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $entry = "$ts [$($Level.PadRight(7))] $Message"
                [System.Threading.Monitor]::Enter($state.PendingMessages.SyncRoot)
                try { $state.PendingMessages.Add(@{ Text = $entry; Level = $Level }) | Out-Null }
                finally { [System.Threading.Monitor]::Exit($state.PendingMessages.SyncRoot) }
                try {
                    $logFile = "BedrockServerManager_$(Get-Date -Format 'yyyyMMdd').log"
                    $logPath = Join-Path $state.LogsPath $logFile
                    $logDir  = Split-Path $logPath -Parent
                    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
                    Add-Content -Path $logPath -Value $entry -ErrorAction SilentlyContinue
                    Get-ChildItem -Path $logDir -Filter "BedrockServerManager_*.log" -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$state.LogRetentionDays) } |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                } catch { }
            }

            function Write-ServerConsole {
                param([string]$Message, [string]$Level = "INFO")
                [System.Threading.Monitor]::Enter($state.ServerConsoleMessages.SyncRoot)
                try { $state.ServerConsoleMessages.Add(@{ Text = $Message; Level = $Level }) | Out-Null }
                finally { [System.Threading.Monitor]::Exit($state.ServerConsoleMessages.SyncRoot) }
            }

            function Set-StatusLabel {
                param([string]$Control, [string]$Text, [string]$Colour)
                [System.Threading.Monitor]::Enter($state.PendingStatus.SyncRoot)
                try { $state.PendingStatus.Add(@{ Control=$Control; Text=$Text; Colour=$Colour }) | Out-Null }
                finally { [System.Threading.Monitor]::Exit($state.PendingStatus.SyncRoot) }
            }

            function Set-Busy {
                param([bool]$busy)
                $state.IsBusy = $busy
                [System.Threading.Monitor]::Enter($state.PendingButtons.SyncRoot)
                try { $state.PendingButtons.Add(@{ Action = if ($busy) { "busy" } else { "free" } }) | Out-Null }
                finally { [System.Threading.Monitor]::Exit($state.PendingButtons.SyncRoot) }
            }

            function Set-Progress {
                param([string]$Type, [int]$Value = 0)
                [System.Threading.Monitor]::Enter($state.ProgressLock)
                try { $state.PendingProgress = @{ Type = $Type; Value = $Value } }
                finally { [System.Threading.Monitor]::Exit($state.ProgressLock) }
            }

            # ── Semver-style version comparison for Bedrock version strings ──
            # Returns: 1 if v1 > v2, -1 if v1 < v2, 0 if equal
            function Compare-BedrockVersion {
                param([string]$v1, [string]$v2)
                if ([string]::IsNullOrWhiteSpace($v1) -and [string]::IsNullOrWhiteSpace($v2)) { return 0 }
                if ([string]::IsNullOrWhiteSpace($v1)) { return -1 }
                if ([string]::IsNullOrWhiteSpace($v2)) { return 1 }
                $parts1 = $v1.Split('.')
                $parts2 = $v2.Split('.')
                $maxLen = [Math]::Max($parts1.Count, $parts2.Count)
                for ($i = 0; $i -lt $maxLen; $i++) {
                    $p1 = 0; $p2 = 0
                    if ($i -lt $parts1.Count) { [int]::TryParse($parts1[$i], [ref]$p1) | Out-Null }
                    if ($i -lt $parts2.Count) { [int]::TryParse($parts2[$i], [ref]$p2) | Out-Null }
                    if ($p1 -gt $p2) { return 1 }
                    if ($p1 -lt $p2) { return -1 }
                }
                return 0
            }

            function Ensure-FirewallRule {
                param([string]$ExePath)
                if ($state.FirewallRuleVerified) { return }
                try {
                    $ruleName = "Minecraft Bedrock Server"
                    $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
                    if (-not $existingRule) {
                        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Program $ExePath -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
                    }
                } catch { }
                $state.FirewallRuleVerified = $true
            }

            function Get-RunningServer {
                $exeName = [System.IO.Path]::GetFileNameWithoutExtension($state.ServerExecutable)
                $exePath = Join-Path $state.ServerPath $state.ServerExecutable
                if ($state.ServerProcess -and -not $state.ServerProcess.HasExited) { return $state.ServerProcess }
                # Try by PID first (more reliable)
                if ($state.ServerProcessId) {
                    try {
                        $byId = Get-Process -Id $state.ServerProcessId -ErrorAction SilentlyContinue
                        if ($byId -and -not $byId.HasExited) { return $byId }
                    } catch { }
                }
                # Fallback: by name + path match
                $procs = Get-Process -Name $exeName -ErrorAction SilentlyContinue
                if (-not $procs) { return $null }
                $procList = @($procs)
                if ($procList.Count -eq 1) {
                    # Verify path if accessible
                    try { if ($procList[0].Path -and ($procList[0].Path -ne $exePath)) { return $null } } catch { }
                    return $procList[0]
                }
                foreach ($p in $procList) {
                    try { if ($p.Path -and ($p.Path -eq $exePath)) { return $p } } catch { }
                }
                return $null
            }

            function Get-AppliedVersion {
                $vPath = Join-Path $state.ServerPath "applied_version.txt"
                if (Test-Path $vPath) { return (Get-Content $vPath -ErrorAction SilentlyContinue).Trim() }
                return $null
            }
            function Set-AppliedVersion { param([string]$Version); Set-Content -Path (Join-Path $state.ServerPath "applied_version.txt") -Value $Version -Force -ErrorAction SilentlyContinue }
            function Get-InstalledVersion {
                $exe = Join-Path $state.ServerPath $state.ServerExecutable
                if (Test-Path $exe) {
                    $vi = (Get-Item $exe).VersionInfo
                    $v = $vi.ProductVersion; if (-not $v) { $v = $vi.FileVersion }
                    if ($v -and $v.Trim() -ne "") { return $v.Trim() }
                    $appliedVer = Get-AppliedVersion; if ($appliedVer) { return $appliedVer }
                }
                return $null
            }
            function Test-ServerInstalled { return (Test-Path (Join-Path $state.ServerPath $state.ServerExecutable)) }

            function Initialize-ServerDirectories {
                foreach ($d in @($state.RootPath, $state.ServerPath, $state.BackupPath, $state.LogsPath, $state.UpdateTempPath)) {
                    if (-not (Test-Path $d)) {
                        New-Item -ItemType Directory -Path $d -Force | Out-Null
                        Write-Log "Created directory: $d" -Level SYSTEM
                    }
                }
            }

            function Stop-GameServer {
                $proc = Get-RunningServer
                if (-not $proc) {
                    $state.IsRunning = $false
                    $state.ExpectedToRun = $false
                    $state.ServerStartTime = $null
                    $state.ServerProcess = $null
                    $state.ServerProcessId = $null
                    return
                }
                Write-Log "Stopping server (PID $($proc.Id))..." -Level WARN
                Set-StatusLabel "lblServerStatus" "STOPPING…" "orange"

                $sp = $state.ServerProcess
                if ($sp -and -not $sp.HasExited) {
                    try {
                        [System.Threading.Monitor]::Enter($state.StdInWriteLock)
                        try {
                            $sp.StandardInput.WriteLine("stop")
                            $sp.StandardInput.Flush()
                            Write-ServerConsole "> stop" "CMD"
                            Write-Log "Sent 'stop' command via stdin (graceful shutdown)." -Level SYSTEM
                        } finally { [System.Threading.Monitor]::Exit($state.StdInWriteLock) }
                    } catch {
                        Write-Log "Could not send stdin 'stop': $($_.Exception.Message)" -Level WARN
                    }
                }

                $elapsed = 0
                while ((Get-RunningServer) -and $elapsed -lt $state.ServerStopTimeout) {
                    Start-Sleep -Seconds 1; $elapsed++
                }
                if (Get-RunningServer) {
                    Write-Log "Server did not exit in $($state.ServerStopTimeout)s. Force-killing..." -Level WARN
                    try { Get-RunningServer | Stop-Process -Force -ErrorAction Stop } catch { Write-Log "Force-kill error: $($_.Exception.Message)" -Level WARN }
                    Start-Sleep -Seconds 2
                }

                if ($state.ServerProcess) {
                    try { $state.ServerProcess.Dispose() } catch { }
                    $state.ServerProcess = $null
                }
                $state.ServerProcessId = $null
                if ($state.ServerOutputReader) {
                    $state.ServerOutputReader = $null
                }

                $state.IsRunning = $false
                $state.ExpectedToRun = $false
                $state.ServerStartTime = $null
                Write-Log "Server stopped." -Level SUCCESS
                Set-StatusLabel "lblServerStatus" "STOPPED" "red"
                Set-StatusLabel "lblIpPort" "—" "gray"
            }

            function Backup-All {
                param([bool]$IsManual = $false)
                if (Get-RunningServer) { Write-Log "Cannot backup while server is running. Stop the server first." -Level ERROR; return }
                Write-Log "Starting full backup (Configs + Worlds)..." -Level SYSTEM
                $backupRoot = $state.BackupPath
                if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
                $timeStr = Get-Date -Format 'yyyyMMdd_HHmmssfff'
                $zipName = "full_backup_$timeStr.zip"
                $zipPath = Join-Path $backupRoot $zipName
                $stageDir = Join-Path $state.UpdateTempPath "backup_stage_$timeStr"
                if (-not (Test-Path $stageDir)) { New-Item -ItemType Directory -Path $stageDir -Force | Out-Null }
                try {
                    foreach ($f in $state.FilesToBackup) {
                        $src = Join-Path $state.ServerPath $f
                        if (Test-Path $src) { Copy-Item $src $stageDir -Force -ErrorAction SilentlyContinue }
                    }
                    $worldsDir = Join-Path $state.ServerPath "worlds"
                    if (Test-Path $worldsDir) { Copy-Item -Path $worldsDir -Destination $stageDir -Recurse -Force -ErrorAction SilentlyContinue }
                    else { Write-Log "No 'worlds' directory found. Backing up configs only." -Level WARN }
                    Write-Log "Compressing backup to $zipName... (This may take a moment)" -Level SYSTEM
                    # Delete existing zip if it somehow exists (collision safety)
                    if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
                    [System.IO.Compression.ZipFile]::CreateFromDirectory($stageDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
                    $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
                    Write-Log "Backup complete ($sizeMB MB)." -Level SUCCESS
                    $oldBackups = Get-ChildItem $backupRoot -Filter "full_backup_*.zip" | Sort-Object Name -Descending | Select-Object -Skip $state.MaxBackups
                    if ($oldBackups) {
                        Write-Log "Purging $($oldBackups.Count) old backup(s) to retain max $($state.MaxBackups)..." -Level SYSTEM
                        $oldBackups | Remove-Item -Force
                    }
                } catch { Write-Log "Backup failed: $($_.Exception.Message)" -Level ERROR }
                finally { if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue } }
            }

            function Restore-Backup {
                param([string]$ZipPath)
                if (Get-RunningServer) { Write-Log "Cannot restore while server is running. Stop the server first." -Level ERROR; return }
                Write-Log "Preparing to restore from $ZipPath..." -Level WARN
                try {
                    Write-Log "Extracting backup files..." -Level SYSTEM
                    # Use .NET ZipFile for better handling of read-only files
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
                    try {
                        foreach ($entry in $zip.Entries) {
                            $destPath = Join-Path $state.ServerPath $entry.FullName
                            $destDir = Split-Path $destPath -Parent
                            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                            # Skip directory entries
                            if ($entry.FullName.EndsWith("/") -or $entry.FullName.EndsWith("\")) { continue }
                            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
                        }
                    } finally { $zip.Dispose() }
                    $n = 0
                    foreach ($f in $state.FilesToBackup) { $d = Join-Path $state.ServerPath $f; if (Test-Path $d) { $n++ } }
                    Write-Log "Restore complete. $n config file(s) verified." -Level SUCCESS
                } catch { Write-Log "Restore failed: $($_.Exception.Message)" -Level ERROR }
            }

            function Fetch-LatestVersion {
                Write-Log "Contacting Minecraft API…" -Level SYSTEM
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $headers = @{ "User-Agent" = "Mozilla/5.0"; "Accept" = "application/json" }
                $maxRetries = 3; $retryCount = 0; $resp = $null
                while ($retryCount -lt $maxRetries) {
                    try { $resp = Invoke-RestMethod -Uri $state.ApiUrl -Method Get -Headers $headers -TimeoutSec 15; break }
                    catch {
                        $retryCount++
                        if ($retryCount -lt $maxRetries) {
                            Write-Log "API call failed (Attempt $retryCount/$maxRetries): $($_.Exception.Message). Retrying in 5 seconds..." -Level WARN
                            Start-Sleep -Seconds 5
                        } else { throw "Failed to contact Minecraft API after $maxRetries attempts: $($_.Exception.Message)" }
                    }
                }
                $link = $resp.result.links | Where-Object { $_.downloadType -eq "serverBedrockWindows" } | Select-Object -First 1
                if (-not $link -or -not $link.downloadUrl) { throw "API did not return a valid download URL." }
                return @{ Url = $link.downloadUrl; Filename = [System.IO.Path]::GetFileName($link.downloadUrl) }
            }
            function Extract-VersionFromFilename { param([string]$Filename); if ($Filename -match "bedrock-server-(.+?)\.zip") { return $matches[1] }; return $Filename }

            function Get-ServerPort {
                $port = "19132"
                $propsPath = Join-Path $state.ServerPath "server.properties"
                if (Test-Path $propsPath) {
                    $portLine = Get-Content $propsPath -ErrorAction SilentlyContinue | Where-Object { $_ -match "^server-port=" } | Select-Object -First 1
                    if ($portLine -match "^server-port=(\d+)") { $port = $matches[1] }
                }
                return $port
            }

            function Get-ServerConnectionInfo {
                $port = Get-ServerPort
                $ip = "127.0.0.1"
                try {
                    $netAdapters = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
                        $_.IPv4Address -ne $null -and
                        $_.InterfaceAlias -notmatch "Loopback" -and
                        $_.InterfaceAlias -notmatch "VMware" -and
                        $_.InterfaceAlias -notmatch "VirtualBox" -and
                        $_.InterfaceAlias -notmatch "vEthernet" -and
                        $_.IPv4Address.IPAddress -notlike "169.*" -and
                        $_.IPv4Address.IPAddress -ne "127.0.0.1"
                    } | Select-Object -First 1
                    if ($netAdapters) { $ip = $netAdapters.IPv4Address.IPAddress }
                } catch { }
                $hostname = [System.Net.Dns]::GetHostName()
                return @{ Hostname = $hostname; IpPort = "$($ip):$($port)" }
            }

            function Start-ServerProcess {
                $exe = Join-Path $state.ServerPath $state.ServerExecutable
                if (-not (Test-Path $exe)) { Write-Log "Executable not found at $exe" -Level ERROR; return }

                # 1. Adopt already-running process if present — verify Path matches our installation
                $exeName = [System.IO.Path]::GetFileNameWithoutExtension($state.ServerExecutable)
                $existingProc = Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object {
                    try { $_.Path -eq $exe } catch { $false }
                } | Select-Object -First 1

                if ($existingProc -and (-not $state.ServerProcess -or $state.ServerProcess.HasExited)) {
                    # Ensure firewall rule exists for the exe even if we're adopting
                    Ensure-FirewallRule -ExePath $exe
                    $state.IsRunning = $true
                    $state.ExpectedToRun = $true
                    $state.ServerProcess = $null
                    $state.ServerProcessId = $existingProc.Id
                    try { $state.ServerStartTime = $existingProc.StartTime } catch { $state.ServerStartTime = [datetime]::Now }
                    Set-StatusLabel "lblServerStatus" "RUNNING (PID $($existingProc.Id) — adopted, no stdin)" "green"
                    $connStr = Get-ServerConnectionInfo
                    Set-StatusLabel "lblHostname" $connStr.Hostname "white"
                    Set-StatusLabel "lblIpPort" $connStr.IpPort "blue"
                    Write-Log "Server is already running (PID $($existingProc.Id)). Adopted process — stdin wrapper unavailable for this instance." -Level WARN
                    Write-ServerConsole "[Adopted process — input not available. Stop and restart to enable command input.]" "SYSTEM"
                    return
                }
                if ($state.ServerProcess -and -not $state.ServerProcess.HasExited) {
                    Write-Log "Server already running through wrapper (PID $($state.ServerProcess.Id))." -Level WARN
                    return
                }

                # 2. Firewall rule — silent one-time check (never logged)
                Ensure-FirewallRule -ExePath $exe

                Write-Log "Starting server with stdin/stdout wrapper…" -Level SYSTEM
                Set-StatusLabel "lblServerStatus" "STARTING…" "orange"

                # 3. Build ProcessStartInfo with redirected IO
                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName               = $exe
                $startInfo.WorkingDirectory       = $state.ServerPath
                $startInfo.UseShellExecute        = $false
                $startInfo.RedirectStandardInput  = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError  = $true
                $startInfo.CreateNoWindow         = $true
                $startInfo.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden
                $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $startInfo.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $startInfo
                $proc.EnableRaisingEvents = $true

                # 4. Wire up native stdout / stderr handlers via C# ConcurrentQueue
                $reader = New-Object BedrockProcessReader
                $reader.Attach($proc)
                $state.ServerOutputReader = $reader

                try {
                    $started = $proc.Start()
                } catch {
                    Write-Log "Failed to start server process: $($_.Exception.Message)" -Level ERROR
                    Set-StatusLabel "lblServerStatus" "START FAILED" "red"
                    $state.ServerOutputReader = $null
                    return
                }
                if (-not $started) {
                    Write-Log "Failed to start server process (Start() returned false)." -Level ERROR
                    Set-StatusLabel "lblServerStatus" "START FAILED" "red"
                    $state.ServerOutputReader = $null
                    return
                }

                $proc.BeginOutputReadLine()
                $proc.BeginErrorReadLine()

                $state.ServerProcess = $proc
                $state.ServerProcessId = $proc.Id

                # 5. Wait for it to spin up
                Write-Log "Waiting for server to initialize (up to 45 seconds)..." -Level SYSTEM
                $runningProc = $null
                for ($i = 0; $i -lt 15; $i++) {
                    Start-Sleep -Seconds 3
                    if ($proc.HasExited) {
                        Write-Log "Server process exited prematurely (code $($proc.ExitCode))." -Level ERROR
                        $runningProc = $null
                        break
                    }
                    $check = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
                    if ($check -and -not $check.HasExited) { $runningProc = $check; break }
                }

                if ($runningProc) {
                    $state.IsRunning = $true
                    $state.ExpectedToRun = $true
                    try { $state.ServerStartTime = $runningProc.StartTime } catch { $state.ServerStartTime = [datetime]::Now }
                    Set-StatusLabel "lblServerStatus" "RUNNING (PID $($runningProc.Id))" "green"
                    $connStr = Get-ServerConnectionInfo
                    Set-StatusLabel "lblHostname" $connStr.Hostname "white"
                    Set-StatusLabel "lblIpPort" $connStr.IpPort "blue"
                    Write-Log "Server is listening on $($connStr.Hostname) ($($connStr.IpPort))" -Level SUCCESS
                    Write-ServerConsole "[Server process started — PID $($runningProc.Id). stdin wrapper active.]" "SYSTEM"
                } else {
                    $state.IsRunning = $false
                    $state.ExpectedToRun = $false
                    try { if ($proc) { $proc.Dispose() } } catch { }
                    $state.ServerProcess = $null
                    $state.ServerProcessId = $null
                    $state.ServerOutputReader = $null
                    Set-StatusLabel "lblServerStatus" "START FAILED" "red"
                    Write-Log "Server process exited or did not respond in time. Check server console panel for errors." -Level ERROR
                }
            }

            function Refresh-InstalledLabel {
                $ver = Get-InstalledVersion
                if ($ver) { Set-StatusLabel "lblInstalled" $ver "white"; $state.InstalledVersion = $ver }
            }

            function Download-AndInstall {
                param([string]$Url, [string]$Filename, [bool]$IsFirstSetup)
                $updateDir = $state.UpdateTempPath
                $zipPath   = Join-Path $updateDir $Filename
                Initialize-ServerDirectories
                Set-Progress "value" 5
                if (-not $IsFirstSetup) { Stop-GameServer }
                Set-Progress "value" 12
                if (Test-ServerInstalled) { Backup-All }
                Set-Progress "value" 22
                Write-Log "Downloading: $Filename …"
                $ProgressPreference = "SilentlyContinue"
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $Url -OutFile $zipPath -TimeoutSec $state.DownloadTimeout
                if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 1MB) { throw "Download failed or file is too small (corrupt)." }
                Write-Log "Verifying archive integrity..." -Level SYSTEM
                try {
                    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
                    $entries = $zipArchive.Entries.Count
                    $zipArchive.Dispose()
                    if ($entries -lt 5) { throw "Archive seems empty or invalid." }
                    Write-Log "Archive verified ($entries entries)." -Level SUCCESS
                } catch { throw "Downloaded ZIP archive is corrupt or invalid: $($_.Exception.Message)" }
                $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
                Write-Log "Download complete ($sizeMB MB)." -Level SUCCESS
                Set-Progress "value" 58
                Write-Log "Extracting server files to $($state.ServerPath)…"
                try { Expand-Archive -LiteralPath $zipPath -DestinationPath $state.ServerPath -Force }
                catch { throw "Extraction failed: $($_.Exception.Message)" }
                $extractedExe = Join-Path $state.ServerPath $state.ServerExecutable
                if (-not (Test-Path $extractedExe)) { throw "Extraction verification failed: $state.ServerExecutable not found." }
                Write-Log "Extraction complete & verified." -Level SUCCESS
                Set-Progress "value" 80
                Write-Log "Configs and Worlds preserved via archive backup." -Level SYSTEM
                Set-Progress "value" 90
                $verLatest = Extract-VersionFromFilename $Filename
                Set-AppliedVersion -Version $verLatest
                if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue; Write-Log "Cleaned up downloaded archive." -Level SYSTEM }
                Refresh-InstalledLabel
                Set-StatusLabel "lblLatest"       $verLatest    "blue"
                Set-StatusLabel "lblSetupStatus"  "INSTALLED"   "green"
                Set-StatusLabel "lblUpdateStatus" "UP TO DATE"  "green"
                $state.IsInstalled = $true
                $state.UpdateAvailable = $false
                if ($state.StartAfterUpdate) { Start-ServerProcess }
                else { Set-StatusLabel "lblServerStatus" "STOPPED" "red" }
                Set-Progress "value" 100
                [System.GC]::Collect()
            }

            function Periodic-StatusCheck {
                Write-Log "── Periodic status check ──" -Level PERIODIC
                if (Test-ServerInstalled) {
                    $state.IsInstalled = $true
                    $appliedVer = Get-AppliedVersion
                    if (-not $appliedVer) { $exeVer = Get-InstalledVersion; if ($exeVer) { Set-AppliedVersion -Version $exeVer; $appliedVer = $exeVer } }
                    Refresh-InstalledLabel
                    Set-StatusLabel "lblSetupStatus" "INSTALLED" "green"
                } else {
                    $state.IsInstalled = $false
                    Set-StatusLabel "lblInstalled"   "Not installed" "red"
                    Set-StatusLabel "lblSetupStatus" "NOT INSTALLED" "red"
                    return
                }
                $proc = Get-RunningServer
                if ($proc) {
                    $state.IsRunning = $true
                    $state.ExpectedToRun = $true
                    try { $state.ServerStartTime = $proc.StartTime } catch { $state.ServerStartTime = [datetime]::Now }
                    Set-StatusLabel "lblServerStatus" "RUNNING (PID $($proc.Id))" "green"
                    $connStr = Get-ServerConnectionInfo
                    Set-StatusLabel "lblHostname" $connStr.Hostname "white"
                    Set-StatusLabel "lblIpPort" $connStr.IpPort "blue"
                } else {
                    $state.IsRunning = $false
                    Set-StatusLabel "lblServerStatus" "STOPPED" "red"
                    Set-StatusLabel "lblIpPort" "—" "gray"
                }
                try {
                    $latest  = Fetch-LatestVersion
                    $state.LatestUrl      = $latest.Url
                    $state.LatestFilename = $latest.Filename
                    $verLatest = Extract-VersionFromFilename $latest.Filename
                    $state.LatestVersion  = $verLatest
                    Set-StatusLabel "lblLatest" $verLatest "blue"
                    $currentVer = Get-AppliedVersion
                    if (-not $currentVer) {
                        Write-Log "Installed version unknown. Syncing tracking file to latest ($verLatest) to prevent false update loops." -Level WARN
                        Set-AppliedVersion -Version $verLatest
                        $currentVer = $verLatest
                    }
                    # Use semver comparison instead of string equality
                    $cmp = Compare-BedrockVersion $currentVer $verLatest
                    if ($cmp -eq 0) {
                        $state.UpdateAvailable = $false
                        Set-StatusLabel "lblUpdateStatus" "UP TO DATE" "green"
                    } else {
                        $state.UpdateAvailable = $true
                        Set-StatusLabel "lblUpdateStatus" "UPDATE AVAILABLE" "orange"
                        Write-Log "New version available: $verLatest (current: $currentVer)" -Level WARN
                        if ($state.AutoApplyUpdates) {
                            Write-Log "Auto-apply enabled. Starting update process..." -Level SYSTEM
                            Download-AndInstall -Url $latest.Url -Filename $latest.Filename -IsFirstSetup $false
                        }
                    }
                } catch { Write-Log "Periodic update check failed: $($_.Exception.Message)" -Level WARN }
                Write-Log "── Periodic check done ──" -Level PERIODIC
            }
        }

        $bgPS.AddScript($helperScript).AddScript($Work).AddScript({ [System.GC]::Collect() })
        $handle = $bgPS.BeginInvoke()
        $job = @{ PS = $bgPS; RS = $bgRS; Handle = $handle }
        [System.Threading.Monitor]::Enter($script:activeJobs.SyncRoot)
        try { $script:activeJobs.Add($job) | Out-Null }
        finally { [System.Threading.Monitor]::Exit($script:activeJobs.SyncRoot) }
    }

    # ── Button click handlers ─────────────────────────────────────────────────
    $btnFirstSetup.Add_Click({
        if ($sharedState.IsBusy) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true; Set-Progress "indeterminate"
            try {
                if (Test-ServerInstalled) { Write-Log "Server is already installed. Use 'Download and Update' instead." -Level WARN; Set-Progress "reset"; return }
                Write-Log "═══════════════════════════════════════════" -Level HEADER
                Write-Log "  FIRST-TIME SETUP / FRESH INSTALL"         -Level HEADER
                Write-Log "═══════════════════════════════════════════" -Level HEADER
                Initialize-ServerDirectories
                $latest = Fetch-LatestVersion
                $state.LatestUrl      = $latest.Url
                $state.LatestFilename = $latest.Filename
                $ver = Extract-VersionFromFilename $latest.Filename
                $state.LatestVersion  = $ver
                Set-StatusLabel "lblLatest" $ver "blue"
                Download-AndInstall -Url $latest.Url -Filename $latest.Filename -IsFirstSetup $true
                Refresh-InstalledLabel
                Write-Log "═══════════════════════════════════════════" -Level HEADER
                Write-Log "  Setup completed successfully!"             -Level SUCCESS
                Write-Log "═══════════════════════════════════════════" -Level HEADER
            } catch {
                Write-Log "Setup FAILED: $($_.Exception.Message)" -Level ERROR
                Set-StatusLabel "lblSetupStatus" "SETUP FAILED" "red"
                Set-Progress "reset"
            } finally { Set-Busy $false }
        }
    })

    $btnCheckUpdate.Add_Click({
        if ($sharedState.IsBusy) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true; Set-Progress "indeterminate"
            try {
                Write-Log "Checking for updates…"
                if (-not (Test-ServerInstalled)) { Write-Log "No installation found." -Level WARN; return }
                Refresh-InstalledLabel
                $latest = Fetch-LatestVersion
                $state.LatestUrl      = $latest.Url
                $state.LatestFilename = $latest.Filename
                $ver = Extract-VersionFromFilename $latest.Filename
                $state.LatestVersion  = $ver
                Set-StatusLabel "lblLatest" $ver "blue"
                $appliedVer = Get-AppliedVersion
                if (-not $appliedVer) { Write-Log "Installed version unknown. Syncing tracking file to latest ($ver) to prevent false update loops." -Level WARN; Set-AppliedVersion -Version $ver; $appliedVer = $ver }
                # Use semver comparison
                $cmp = Compare-BedrockVersion $appliedVer $ver
                if ($cmp -eq 0) {
                    $state.UpdateAvailable = $false
                    Write-Log "Already up to date." -Level SUCCESS
                    Set-StatusLabel "lblUpdateStatus" "UP TO DATE" "green"
                } else {
                    $state.UpdateAvailable = $true
                    Write-Log "Update available: $ver (current: $appliedVer)" -Level WARN
                    Set-StatusLabel "lblUpdateStatus" "UPDATE AVAILABLE" "orange"
                }
                $proc = Get-RunningServer
                if ($proc) { $state.IsRunning = $true; Set-StatusLabel "lblServerStatus" "RUNNING (PID $($proc.Id))" "green" }
                else { $state.IsRunning = $false; Set-StatusLabel "lblServerStatus" "STOPPED" "red" }
            } catch { Write-Log "Error checking for updates: $($_.Exception.Message)" -Level ERROR }
            finally { Set-Progress "reset"; Set-Busy $false }
        }
    })

    $btnUpdate.Add_Click({
        if ($sharedState.IsBusy -or -not $sharedState.UpdateAvailable -or $sharedState.AutoApplyUpdates) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true
            try {
                $url  = $state.LatestUrl
                $file = $state.LatestFilename
                if (-not $url -or -not $file) { Write-Log "No update URL cached." -Level ERROR; return }
                Write-Log "═══════════════════════════════════════════" -Level HEADER
                Write-Log "  STARTING UPDATE PROCESS"                  -Level HEADER
                Write-Log "═══════════════════════════════════════════" -Level HEADER
                Download-AndInstall -Url $url -Filename $file -IsFirstSetup $false
                Refresh-InstalledLabel
                Write-Log "═══════════════════════════════════════════" -Level HEADER
                Write-Log "  Update completed successfully!"            -Level SUCCESS
                Write-Log "═══════════════════════════════════════════" -Level HEADER
                Set-StatusLabel "lblUpdateStatus" "UP TO DATE" "green"
                $state.UpdateAvailable = $false
            } catch {
                Write-Log "Update FAILED: $($_.Exception.Message)" -Level ERROR
                Set-StatusLabel "lblUpdateStatus" "UPDATE FAILED" "red"
                Set-Progress "reset"
            } finally { Set-Busy $false }
        }
    })

    $btnStartServer.Add_Click({
        if ($sharedState.IsBusy -or $sharedState.IsRunning) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true
            try {
                if (-not (Test-ServerInstalled)) { Write-Log "Executable not found." -Level ERROR; return }
                Start-ServerProcess
            } catch { Write-Log "Error starting server: $($_.Exception.Message)" -Level ERROR }
            finally { Set-Busy $false }
        }
    })

    $btnStopServer.Add_Click({
        if ($sharedState.IsBusy -or -not $sharedState.IsRunning) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true
            try {
                if (-not (Get-RunningServer)) { return }
                Stop-GameServer
            } catch { Write-Log "Error stopping server: $($_.Exception.Message)" -Level ERROR }
            finally { Set-Busy $false }
        }
    })

    $btnRefresh.Add_Click({
        if ($sharedState.IsBusy) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true
            try {
                Write-Log "Refreshing status…" -Level SYSTEM
                if (Test-ServerInstalled) {
                    $state.IsInstalled = $true
                    if (-not (Get-AppliedVersion)) { $exeVer = Get-InstalledVersion; if ($exeVer) { Set-AppliedVersion -Version $exeVer } }
                    Refresh-InstalledLabel
                    Set-StatusLabel "lblSetupStatus" "INSTALLED" "green"
                } else {
                    $state.IsInstalled = $false
                    Set-StatusLabel "lblInstalled"   "Not installed" "red"
                    Set-StatusLabel "lblSetupStatus" "NOT INSTALLED" "red"
                }
                $proc = Get-RunningServer
                if ($proc) {
                    $state.IsRunning = $true; $state.ExpectedToRun = $true
                    try { $state.ServerStartTime = $proc.StartTime } catch { $state.ServerStartTime = [datetime]::Now }
                    Set-StatusLabel "lblServerStatus" "RUNNING (PID $($proc.Id))" "green"
                } else {
                    $state.IsRunning = $false
                    Set-StatusLabel "lblServerStatus" "STOPPED" "red"
                }
                Write-Log "Status refreshed." -Level SUCCESS
            } catch { Write-Log "Error refreshing: $($_.Exception.Message)" -Level ERROR }
            finally { Set-Busy $false }
        }
    })

    $btnBackupNow.Add_Click({
        if ($sharedState.IsBusy -or -not $sharedState.IsInstalled -or $sharedState.IsRunning) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true; Set-Progress "indeterminate"
            try { Initialize-ServerDirectories; Backup-All -IsManual $true }
            catch { Write-Log "Manual backup failed: $($_.Exception.Message)" -Level ERROR }
            finally { Set-Progress "reset"; Set-Busy $false }
        }
    })

    $btnRestoreBackup.Add_Click({
        if ($sharedState.IsBusy -or -not $sharedState.IsInstalled -or $sharedState.IsRunning) { return }
        $backupRoot = $sharedState.BackupPath
        if (-not (Test-Path $backupRoot)) { [System.Windows.MessageBox]::Show("Backup directory does not exist.", "Restore", "OK", "Information"); return }
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.InitialDirectory = $backupRoot
        $dlg.Filter = "Zip Archives (*.zip)|*.zip"
        $dlg.Title = "Select a backup to restore"
        if ($dlg.ShowDialog() -eq $true) {
            $selectedZip = $dlg.FileName
            $confirm = [System.Windows.MessageBox]::Show("WARNING: This will OVERWRITE all existing configs and worlds with the files from:`n`n$selectedZip`n`nAre you sure?", "Confirm Restore", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
                $sharedState.RestoreZipPath = $selectedZip
                Start-BackgroundWork -Work {
                    Set-Busy $true; Set-Progress "indeterminate"
                    try { Restore-Backup -ZipPath $state.RestoreZipPath }
                    catch { Write-Log "Restore failed: $($_.Exception.Message)" -Level ERROR }
                    finally { Set-Progress "reset"; Set-Busy $false }
                }
            }
        }
    })

    $window.Add_Closing({
        param($s, $e)
        if ($sharedState.IsBusy) {
            $msg = [System.Windows.MessageBox]::Show("A background task is currently running. Closing the manager may interrupt it and corrupt files. Are you sure you want to exit?", "Confirm Exit", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($msg -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true; return }
        }
        # Try a graceful stdin 'stop' before window closes — only for our wrapper process
        $sp = $sharedState.ServerProcess
        if ($sp -and -not $sp.HasExited) {
            try {
                [System.Threading.Monitor]::Enter($sharedState.StdInWriteLock)
                try {
                    $sp.StandardInput.WriteLine("stop")
                    $sp.StandardInput.Flush()
                } finally { [System.Threading.Monitor]::Exit($sharedState.StdInWriteLock) }
            } catch { }
            # Wait up to 10 seconds for graceful shutdown
            $waited = 0
            while (-not $sp.HasExited -and $waited -lt 50) {
                Start-Sleep -Milliseconds 200
                $waited++
            }
            # Force kill if still alive
            if (-not $sp.HasExited) {
                try { $sp.Kill() } catch { }
                Start-Sleep -Seconds 1
            }
        }
    })

    $window.Add_Closed({
        $timer.Stop()
        $sharedState.WindowClosed = $true
        Save-Config

        # Cleanup background jobs — stop and dispose all runspaces
        if ($script:activeJobs.Count -gt 0) {
            $jobsCopy = @()
            [System.Threading.Monitor]::Enter($script:activeJobs.SyncRoot)
            try { $jobsCopy = $script:activeJobs.ToArray(); $script:activeJobs.Clear() }
            finally { [System.Threading.Monitor]::Exit($script:activeJobs.SyncRoot) }
            foreach ($job in $jobsCopy) {
                try {
                    if (-not $job.Handle.IsCompleted) { $job.PS.Stop() }
                    $job.PS.EndInvoke($job.Handle)
                } catch { }
                try { $job.PS.Dispose() } catch { }
                try { $job.RS.Close() } catch { }
                try { $job.RS.Dispose() } catch { }
            }
        }
    })

    $window.Add_ContentRendered({
        $sharedState.GuiReady = $true
        Update-PathLabels

        $exe = Join-Path $sharedState.ServerPath $sharedState.ServerExecutable
        if (Test-Path $exe) {
            $sharedState.IsInstalled = $true
            $v = (Get-Item $exe).VersionInfo.ProductVersion
            if (-not $v) { $v = (Get-Item $exe).VersionInfo.FileVersion }
            # Inline version file operations (fix: Get-AppliedVersion/Set-AppliedVersion were
            # only defined in the background helper runspace, not accessible from GUI runspace)
            $appliedVerPath = Join-Path $sharedState.ServerPath "applied_version.txt"
            $appliedVer = $null
            if (Test-Path $appliedVerPath) { $appliedVer = (Get-Content $appliedVerPath -ErrorAction SilentlyContinue).Trim() }
            if (-not $v -or $v.Trim() -eq "") {
                if ($appliedVer) { $v = $appliedVer } else { $v = "Unknown" }
            } else {
                $v = $v.Trim()
                if (-not $appliedVer) { Set-Content -Path $appliedVerPath -Value $v -Force -ErrorAction SilentlyContinue }
            }
            $lblInstalled.Text = $v
            $lblInstalled.Foreground = $statusBrushCache["white"]
            $lblSetupStatus.Text = "INSTALLED"
            $lblSetupStatus.Foreground = $statusBrushCache["green"]

            # Check for already-running server — verify Path matches our installation
            $exeName = [System.IO.Path]::GetFileNameWithoutExtension($sharedState.ServerExecutable)
            $proc = Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object {
                try { $_.Path -eq $exe } catch { $false }
            } | Select-Object -First 1

            if ($proc) {
                # Verify/create firewall rule for adopted process
                try {
                    $ruleName = "Minecraft Bedrock Server"
                    $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
                    if (-not $existingRule) {
                        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Program $exe -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
                    }
                    $sharedState.FirewallRuleVerified = $true
                } catch { }

                $sharedState.IsRunning = $true
                $sharedState.ExpectedToRun = $true
                try { $sharedState.ServerStartTime = $proc.StartTime } catch { $sharedState.ServerStartTime = $null }
                $sharedState.ServerProcessId = $proc.Id
                $lblServerStatus.Text = "RUNNING (PID $($proc.Id) — adopted)"
                $lblServerStatus.Foreground = $statusBrushCache["green"]

                # Get port from server.properties
                $port = "19132"
                $propsPath = Join-Path $sharedState.ServerPath "server.properties"
                if (Test-Path $propsPath) {
                    $portLine = Get-Content $propsPath -ErrorAction SilentlyContinue | Where-Object { $_ -match "^server-port=" } | Select-Object -First 1
                    if ($portLine -match "^server-port=(\d+)") { $port = $matches[1] }
                }
                $ip = "127.0.0.1"
                try {
                    $netAdapters = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
                        $_.IPv4Address -ne $null -and
                        $_.InterfaceAlias -notmatch "Loopback" -and
                        $_.InterfaceAlias -notmatch "VMware" -and
                        $_.InterfaceAlias -notmatch "VirtualBox" -and
                        $_.InterfaceAlias -notmatch "vEthernet" -and
                        $_.IPv4Address.IPAddress -notlike "169.*" -and
                        $_.IPv4Address.IPAddress -ne "127.0.0.1"
                    } | Select-Object -First 1
                    if ($netAdapters) { $ip = $netAdapters.IPv4Address.IPAddress }
                } catch { }
                $lblIpPort.Text = "$($ip):$($port)"
                $lblIpPort.Foreground = $statusBrushCache["blue"]
                Append-ServerLine "[Detected already-running bedrock_server (PID $($proc.Id)). Stdin wrapper unavailable — stop and start from GUI to enable command input.]" "SYSTEM"
            } else {
                $sharedState.IsRunning = $false
                $lblServerStatus.Text = "STOPPED"
                $lblServerStatus.Foreground = $statusBrushCache["red"]
                $lblIpPort.Text = "—"
                $lblIpPort.Foreground = $statusBrushCache["gray"]
            }
        } else {
            $sharedState.IsInstalled = $false
            $sharedState.IsRunning = $false
            $lblInstalled.Text = "Not installed"
            $lblInstalled.Foreground = $statusBrushCache["red"]
            $lblSetupStatus.Text = "NOT INSTALLED"
            $lblSetupStatus.Foreground = $statusBrushCache["red"]
            $lblServerStatus.Text = "N/A"
            $lblServerStatus.Foreground = $statusBrushCache["orange"]
            $lblIpPort.Text = "—"
            $lblIpPort.Foreground = $statusBrushCache["gray"]
        }

        $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Append-LogLine "$now [SYSTEM ] ═══════════════════════════════════════════" "SYSTEM"
        Append-LogLine "$now [SYSTEM ]   Minecraft Bedrock Server Manager v28.4"    "SUCCESS"
        Append-LogLine "$now [SYSTEM ]   PowerShell $($PSVersionTable.PSVersion)"   "SYSTEM"
        Append-LogLine "$now [SYSTEM ] ═══════════════════════════════════════════" "SYSTEM"

        if (-not (Test-Path $exe)) {
            Append-LogLine "$now [WARN   ] No installation detected — click 'Setup / Install' to begin." "WARN"
        } else {
            Append-LogLine "$now [INFO   ] Installation found. Performing initial update check..." "INFO"
            # Chain periodic check and auto-launch in the same background work block.
            # This eliminates the race condition where IsBusy was set asynchronously
            # and the auto-launch check ran before IsBusy was visible, plus the
            # Start-Sleep that froze the GUI thread for 2 seconds.
            Start-BackgroundWork -Work {
                Set-Busy $true
                try {
                    Periodic-StatusCheck
                    if ($state.AutoLaunchOnStart -and -not $state.IsRunning) {
                        Start-ServerProcess
                    }
                } finally { Set-Busy $false }
            }
        }
        Update-ButtonStates
    })

    $window.ShowDialog() | Out-Null

}) | Out-Null

# ─── Launch GUI ───────────────────────────────────────────────────────────────
$guiHandle = $guiPowerShell.BeginInvoke()
try {
    while (-not $guiHandle.IsCompleted) { Start-Sleep -Milliseconds 200 }
} finally {
    $guiPowerShell.EndInvoke($guiHandle)
    $guiPowerShell.Dispose()
    $guiRunspace.Close()
    $guiRunspace.Dispose()
    [System.GC]::Collect()
}
