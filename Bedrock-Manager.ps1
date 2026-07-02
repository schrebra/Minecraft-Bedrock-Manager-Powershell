#Requires -Version 5.1
<#
.SYNOPSIS
    Minecraft Bedrock Server Manager — GUI Edition

.DESCRIPTION
    WPF/XAML GUI for first-time setup, auto-update, and management of
    Minecraft Bedrock Dedicated Server on Windows.
    Optimized for long-term stability (weeks/months of uptime).
    Clean folder structure:
    C:\Bedrock\Server   (Minecraft Server Files)
    C:\Bedrock\Backup   (Configuration Revisions)
    C:\Bedrock\Logs     (Daily Manager Logs)
    C:\Bedrock\UpdateTemp (Temporary download/extraction files)


param(
    [string]$RootPath = ""
)

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
    MaxBackups          = 15
    LogRetentionDays    = 30
    ServerStopTimeout   = 10
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
    PendingMessages     = [System.Collections.ArrayList]::new()
    PendingStatus       = [System.Collections.ArrayList]::new()
    PendingProgress     = @{ Type = "none"; Value = 0 }
    PendingButtons      = [System.Collections.ArrayList]::new()
    StopRequested       = $false
    GuiReady            = $false
    WindowClosed        = $false
})

# Derived Paths
 $script:sharedState.ServerPath     = Join-Path $script:sharedState.RootPath "Server"
 $script:sharedState.BackupPath     = Join-Path $script:sharedState.RootPath "Backup"
 $script:sharedState.LogsPath       = Join-Path $script:sharedState.RootPath "Logs"
 $script:sharedState.UpdateTempPath = Join-Path $script:sharedState.RootPath "UpdateTemp"

# ─── XAML ─────────────────────────────────────────────────────────────────────
 $xamlString = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Minecraft Bedrock Server Manager v17.0"
    Width="1024" Height="680"
    MinWidth="800" MinHeight="500"
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

        <!-- ═══ 0 · HEADER ═════════════════════════════════════════════════ -->
        <Grid Grid.Row="0" Margin="2,0,2,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock Text="Minecraft Bedrock Server Manager" FontSize="18" FontWeight="Bold" Foreground="{StaticResource TextPrimary}"/>
                <TextBlock Text="v17.0 Production Ready" FontSize="10" Foreground="{StaticResource TextMuted}" Margin="0,2,0,0"/>
            </StackPanel>
            <Border Grid.Column="1" Background="{StaticResource BgCard}" BorderBrush="{StaticResource BorderDefault}" BorderThickness="1" CornerRadius="4" Padding="8,5" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="dotPeriodic" Width="8" Height="8" Fill="{StaticResource AccentGray}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <TextBlock x:Name="lblNextCheck" Text="Auto-check: —" Foreground="{StaticResource TextSecondary}" FontSize="10.5" VerticalAlignment="Center"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- ═══ 1 · ROOT PATH BAR ══════════════════════════════════════════ -->
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

        <!-- ═══ 2 · STAT CARDS ══════════════════════════════════════════════ -->
        <UniformGrid Grid.Row="2" Columns="5">
            <Border Style="{StaticResource Card}">
                <StackPanel>
                    <TextBlock Text="INSTALLED" Style="{StaticResource StatLabel}"/>
                    <TextBlock x:Name="lblInstalled" Text="—" Style="{StaticResource StatValue}"/>
                </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
                <StackPanel>
                    <TextBlock Text="LATEST" Style="{StaticResource StatLabel}"/>
                    <TextBlock x:Name="lblLatest" Text="—" Style="{StaticResource StatValue}" Foreground="{StaticResource AccentBlue}"/>
                </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
                <StackPanel>
                    <TextBlock Text="STATUS" Style="{StaticResource StatLabel}"/>
                    <TextBlock x:Name="lblServerStatus" Text="—" Style="{StaticResource StatValue}" Foreground="{StaticResource AccentOrange}"/>
                </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
                <StackPanel>
                    <TextBlock Text="SETUP" Style="{StaticResource StatLabel}"/>
                    <TextBlock x:Name="lblSetupStatus" Text="—" Style="{StaticResource StatValue}"/>
                </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
                <StackPanel>
                    <TextBlock Text="UPDATE" Style="{StaticResource StatLabel}"/>
                    <TextBlock x:Name="lblUpdateStatus" Text="—" Style="{StaticResource StatValue}" Foreground="{StaticResource AccentGray}"/>
                </StackPanel>
            </Border>
        </UniformGrid>

        <!-- ═══ 3 · INFO / PATHS CARD ══════════════════════════════════════ -->
        <Border Grid.Row="3" Style="{StaticResource Card}">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <Grid Margin="0,0,0,3">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="100"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Server Dir:" Style="{StaticResource InfoKey}"/>
                        <TextBlock Grid.Column="1" x:Name="lblInstallDir" Text="—" Style="{StaticResource InfoVal}" Foreground="{StaticResource AccentBlue}" TextDecorations="Underline" Cursor="Hand"/>
                    </Grid>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="100"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Backups Dir:" Style="{StaticResource InfoKey}"/>
                        <TextBlock Grid.Column="1" x:Name="lblBackupDir" Text="—" Style="{StaticResource InfoVal}" Foreground="{StaticResource AccentBlue}" TextDecorations="Underline" Cursor="Hand"/>
                    </Grid>
                </StackPanel>
                <Rectangle Grid.Column="1" Fill="{StaticResource BorderDefault}" Width="1"/>
                <StackPanel Grid.Column="2">
                    <Grid Margin="0,0,0,3">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="100"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Logs Dir:" Style="{StaticResource InfoKey}"/>
                        <TextBlock Grid.Column="1" x:Name="lblLogFile" Text="—" Style="{StaticResource InfoVal}" Foreground="{StaticResource AccentBlue}" TextDecorations="Underline" Cursor="Hand"/>
                    </Grid>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="100"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Last Checked:" Style="{StaticResource InfoKey}"/>
                        <TextBlock Grid.Column="1" x:Name="lblLastChecked" Text="—" Style="{StaticResource InfoVal}"/>
                    </Grid>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ═══ 4 · SETTINGS BAR ════════════════════════════════════════════ -->
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
                    <TextBox x:Name="txtInterval" Width="30" Text="24" VerticalAlignment="Center" Style="{StaticResource LightTextBox}" Padding="3,4"/>
                    <TextBlock Text="hrs" VerticalAlignment="Center" Margin="4,0,15,0" Foreground="{StaticResource TextSecondary}" FontSize="11"/>
                    <CheckBox x:Name="chkAutoApplyUpdates" Content="Auto-apply" Style="{StaticResource SettingsCheckBox}" IsChecked="False"/>
                    <TextBlock Text="Keep Logs:" VerticalAlignment="Center" Margin="0,0,4,0" Foreground="{StaticResource TextSecondary}" FontSize="11"/>
                    <TextBox x:Name="txtLogRetention" Width="30" Text="30" VerticalAlignment="Center" Style="{StaticResource LightTextBox}" Padding="3,4"/>
                    <TextBlock Text="days" VerticalAlignment="Center" Margin="4,0,15,0" Foreground="{StaticResource TextSecondary}" FontSize="11"/>
                    <TextBlock Text="Keep Backups:" VerticalAlignment="Center" Margin="0,0,4,0" Foreground="{StaticResource TextSecondary}" FontSize="11"/>
                    <TextBox x:Name="txtMaxBackups" Width="30" Text="15" VerticalAlignment="Center" Style="{StaticResource LightTextBox}" Padding="3,4"/>
                </WrapPanel>
                <Button Grid.Column="1" x:Name="btnApplySettings" Content="Apply Settings" Background="{StaticResource AccentBlue}" Style="{StaticResource ActionButton}"/>
            </Grid>
        </Border>

        <!-- ═══ 5 · BUTTON BAR ══════════════════════════════════════════════ -->
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
                </WrapPanel>
                <TextBlock Grid.Column="1" x:Name="lblFooter" Text="v17.0" Foreground="{StaticResource TextMuted}" FontSize="10" VerticalAlignment="Center" Margin="10,0,0,0"/>
            </Grid>
        </Border>

        <!-- ═══ 6 · PROGRESS ════════════════════════════════════════════════ -->
        <Grid Grid.Row="6" Margin="3,2,3,2">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <ProgressBar x:Name="progressBar" Grid.Row="0" Height="4" Minimum="0" Maximum="100" Value="0" Background="#E0E0E0" Foreground="{StaticResource AccentGreen}" BorderThickness="0"/>
            <TextBlock x:Name="lblProgressText" Grid.Row="1" Text="" FontSize="10" Foreground="{StaticResource TextMuted}" Margin="4,2,0,0" Visibility="Collapsed"/>
        </Grid>

        <!-- ═══ 7 · CONSOLE LOG ══════════════════════════════════════════════ -->
        <Border Grid.Row="7" Margin="3,3,3,3" BorderBrush="{StaticResource BorderDefault}" BorderThickness="1" CornerRadius="5">
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
                        <TextBlock Grid.Column="0" Text="Console Output" Foreground="{StaticResource TextPrimary}" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" Margin="5,0,0,0"/>
                        <Button Grid.Column="1" x:Name="btnClearLog" Content="Clear" Background="{StaticResource AccentGray}" Style="{StaticResource ActionButton}" Padding="10,4"/>
                    </Grid>
                </Border>
                <RichTextBox x:Name="rtbLog" Grid.Row="1" Background="#012456" Foreground="#EEEEEE" BorderThickness="0" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" FontFamily="Consolas,Courier New" FontSize="11" Padding="8,6">
                    <RichTextBox.Resources>
                        <Style TargetType="Paragraph">
                            <Setter Property="Margin" Value="0,1,0,1"/>
                            <Setter Property="LineHeight" Value="14"/>
                        </Style>
                    </RichTextBox.Resources>
                </RichTextBox>
            </Grid>
        </Border>
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
                            "RootPath"          { $sharedState.RootPath = $val }
                            "StartAfterUpdate"  { $sharedState.StartAfterUpdate = ($val -eq 'True') }
                            "AutoLaunchOnStart" { $sharedState.AutoLaunchOnStart = ($val -eq 'True') }
                            "CrashProtection"   { $sharedState.CrashProtection = ($val -eq 'True') }
                            "AutoCheckUpdates"  { $sharedState.AutoCheckUpdates = ($val -eq 'True') }
                            "UpdateCheckHours"  { $sharedState.UpdateCheckHours = [int]$val }
                            "AutoApplyUpdates"  { $sharedState.AutoApplyUpdates = ($val -eq 'True') }
                            "LogRetentionDays"  { $sharedState.LogRetentionDays = [int]$val }
                            "MaxBackups"        { $sharedState.MaxBackups = [int]$val }
                        }
                    }
                }
            } catch { }
        }
        # Re-derive paths
        $sharedState.ServerPath     = Join-Path $sharedState.RootPath "Server"
        $sharedState.BackupPath     = Join-Path $sharedState.RootPath "Backup"
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
    $lblSetupStatus      = $window.FindName("lblSetupStatus")
    $lblUpdateStatus     = $window.FindName("lblUpdateStatus")
    $lblInstallDir       = $window.FindName("lblInstallDir")
    $lblBackupDir        = $window.FindName("lblBackupDir")
    $lblLogFile          = $window.FindName("lblLogFile")
    $lblLastChecked      = $window.FindName("lblLastChecked")
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
    $txtLogRetention     = $window.FindName("txtLogRetention")
    $txtMaxBackups       = $window.FindName("txtMaxBackups")
    $btnApplySettings    = $window.FindName("btnApplySettings")

    $rtbLog              = $window.FindName("rtbLog")
    $btnFirstSetup       = $window.FindName("btnFirstSetup")
    $btnCheckUpdate      = $window.FindName("btnCheckUpdate")
    $btnUpdate           = $window.FindName("btnUpdate")
    $btnStartServer      = $window.FindName("btnStartServer")
    $btnStopServer       = $window.FindName("btnStopServer")
    $btnRefresh          = $window.FindName("btnRefresh")
    $btnClearLog         = $window.FindName("btnClearLog")

    # Sync UI with loaded config
    $txtRootPath.Text             = $sharedState.RootPath
    $chkAutoStart.IsChecked       = $sharedState.StartAfterUpdate
    $chkAutoLaunch.IsChecked      = $sharedState.AutoLaunchOnStart
    $chkCrashProtect.IsChecked    = $sharedState.CrashProtection
    $chkAutoCheckUpdates.IsChecked = $sharedState.AutoCheckUpdates
    $chkAutoApplyUpdates.IsChecked = $sharedState.AutoApplyUpdates
    $txtInterval.Text             = $sharedState.UpdateCheckHours
    $txtLogRetention.Text         = $sharedState.LogRetentionDays
    $txtMaxBackups.Text           = $sharedState.MaxBackups

    # Event Handlers for path labels
    $lblInstallDir.Add_MouseLeftButtonUp({
        $p = $sharedState.ServerPath
        if (Test-Path $p) { Start-Process explorer.exe $p }
    })
    $lblBackupDir.Add_MouseLeftButtonUp({
        $p = $sharedState.BackupPath
        if (Test-Path $p) { Start-Process explorer.exe $p }
        else { [System.Windows.MessageBox]::Show("Backup folder does not exist yet.", "Not Found", "OK", "Information") | Out-Null }
    })
    $lblLogFile.Add_MouseLeftButtonUp({
        $p = Join-Path $sharedState.LogsPath "BedrockServerManager_$(Get-Date -Format 'yyyyMMdd').log"
        if (Test-Path $p) { Start-Process notepad.exe $p }
        else { [System.Windows.MessageBox]::Show("Log file does not exist yet.", "Not Found", "OK", "Information") | Out-Null }
    })

    function Update-PathLabels {
        $lblInstallDir.Text = $sharedState.ServerPath
        $lblBackupDir.Text  = $sharedState.BackupPath
        $lblLogFile.Text    = Join-Path $sharedState.LogsPath "BedrockServerManager_$(Get-Date -Format 'yyyyMMdd').log"
    }
    Update-PathLabels

    # Pre-Freeze Brushes to prevent WPF Memory Leaks over long durations
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

    $brushCache = @{}
    foreach ($key in $colourMap.Keys) {
        $br = [System.Windows.Media.BrushConverter]::new().ConvertFromString($colourMap[$key])
        $br.Freeze()
        $brushCache[$key] = $br
    }
    $statusBrushCache = @{}
    foreach ($key in $statusColourMap.Keys) {
        $br = [System.Windows.Media.BrushConverter]::new().ConvertFromString($statusColourMap[$key])
        $br.Freeze()
        $statusBrushCache[$key] = $br
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
        }
    }

    $script:activeJobs = [System.Collections.ArrayList]::new()
    $script:nextUpdateCheck = [datetime]::Now.AddHours($sharedState.UpdateCheckHours)
    $script:lastGcTime = [datetime]::Now

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500) # Tick 2x per second to reduce CPU usage over long periods
    $timer.Add_Tick({

        # 1. Process Pending Messages (Max 50 per tick to keep UI smooth and auto-scroll reliable)
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
            
            # Purge old logs in UI to prevent memory leaks (Keep max 500 lines for performance)
            while ($rtbLog.Document.Blocks.Count -gt 500) {
                $block = $rtbLog.Document.Blocks.FirstBlock
                $rtbLog.Document.Blocks.Remove($block)
                if ($block) { $block.Clear() }
            }
            
            # Explicitly scroll to end after batch is processed
            $rtbLog.ScrollToEnd()
        }

        # 2. Process Pending Status Updates
        if ($sharedState.PendingStatus.Count -gt 0) {
            $updates = @()
            [System.Threading.Monitor]::Enter($sharedState.PendingStatus.SyncRoot)
            try {
                $updates = $sharedState.PendingStatus.ToArray()
                $sharedState.PendingStatus.Clear()
            } finally {
                [System.Threading.Monitor]::Exit($sharedState.PendingStatus.SyncRoot)
            }
            foreach ($u in $updates) {
                $ctrl = $window.FindName($u.Control)
                if ($ctrl) {
                    $ctrl.Text = $u.Text
                    try {
                        if ($statusBrushCache.ContainsKey($u.Colour)) {
                            $ctrl.Foreground = $statusBrushCache[$u.Colour]
                        } else {
                            # Create and freeze dynamic colors on the fly to prevent leaks
                            $dynBr = [System.Windows.Media.BrushConverter]::new().ConvertFromString($u.Colour)
                            $dynBr.Freeze()
                            $ctrl.Foreground = $dynBr
                        }
                    } catch { }
                }
                if ($u.Control -eq "lblInstallDir" -or $u.Control -eq "txtRootPath") {
                    Update-PathLabels
                }
            }
        }

        # 3. Progress Bar
        $prog = $sharedState.PendingProgress
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
                $sharedState.PendingProgress = @{ Type = "none"; Value = 0 }
            }
        }

        # 4. Button State Updates
        if ($sharedState.PendingButtons.Count -gt 0) {
            $btnUpds = @()
            [System.Threading.Monitor]::Enter($sharedState.PendingButtons.SyncRoot)
            try {
                $btnUpds = $sharedState.PendingButtons.ToArray()
                $sharedState.PendingButtons.Clear()
            } finally {
                [System.Threading.Monitor]::Exit($sharedState.PendingButtons.SyncRoot)
            }
            foreach ($b in $btnUpds) {
                if ($b.Action -eq "busy") { $sharedState.IsBusy = $true }
                elseif ($b.Action -eq "free") { $sharedState.IsBusy = $false }
            }
        }
        Update-ButtonStates

        # 5. Crash Protection Monitor
        if (-not $sharedState.IsBusy -and $sharedState.ExpectedToRun -and $sharedState.CrashProtection) {
            $exeName = [System.IO.Path]::GetFileNameWithoutExtension($sharedState.ServerExecutable)
            $exePath = Join-Path $sharedState.ServerPath $sharedState.ServerExecutable
            if (Test-Path $exePath) {
                $proc = Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exePath }
                if (-not $proc -and $sharedState.IsRunning) {
                    $sharedState.IsRunning = $false
                    # Use cached brush directly for speed
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
                    
                    Start-BackgroundWork -Work {
                        Start-ServerProcess
                    }
                }
            }
        }

        # 6. Periodic Update Check Monitor
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

        # 7. Cleanup completed background jobs
        if ($script:activeJobs.Count -gt 0) {
            $completed = @()
            foreach ($job in $script:activeJobs) {
                if ($job.Handle.IsCompleted) {
                    try { $job.PS.EndInvoke($job.Handle) } catch {}
                    $job.PS.Dispose()
                    $job.RS.Close()
                    $job.RS.Dispose()
                    $completed += $job
                }
            }
            if ($completed.Count -gt 0) {
                [System.Threading.Monitor]::Enter($script:activeJobs.SyncRoot)
                try { $completed | ForEach-Object { $script:activeJobs.Remove($_) | Out-Null } }
                finally { [System.Threading.Monitor]::Exit($script:activeJobs.SyncRoot) }
            }
        }

        # 8. Garbage Collection (Every 5 minutes)
        if (([datetime]::Now - $script:lastGcTime).TotalMinutes -ge 5) {
            $script:lastGcTime = [datetime]::Now
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }

        if ($lblInstallDir.Text -ne $sharedState.ServerPath) { Update-PathLabels }
    })
    $timer.Start()

    $txtRootPath.Add_TextChanged({
        $sharedState.RootPath = $txtRootPath.Text
        $sharedState.ServerPath     = Join-Path $sharedState.RootPath "Server"
        $sharedState.BackupPath     = Join-Path $sharedState.RootPath "Backup"
        $sharedState.LogsPath       = Join-Path $sharedState.RootPath "Logs"
        $sharedState.UpdateTempPath = Join-Path $sharedState.RootPath "UpdateTemp"
        Update-PathLabels
    })

    $btnApplySettings.Add_Click({
        $valHrs = 0
        $valLog = 0
        $valBak = 0
        if ([int]::TryParse($txtInterval.Text, [ref]$valHrs) -and $valHrs -ge 1 -and
            [int]::TryParse($txtLogRetention.Text, [ref]$valLog) -and $valLog -ge 1 -and
            [int]::TryParse($txtMaxBackups.Text, [ref]$valBak) -and $valBak -ge 1) {
            
            $sharedState.UpdateCheckHours = $valHrs
            $script:nextUpdateCheck = [datetime]::Now.AddHours($valHrs)
            $sharedState.LogRetentionDays = $valLog
            $sharedState.MaxBackups = $valBak
            
            $sharedState.StartAfterUpdate  = $chkAutoStart.IsChecked
            $sharedState.AutoLaunchOnStart = $chkAutoLaunch.IsChecked
            $sharedState.CrashProtection   = $chkCrashProtect.IsChecked
            $sharedState.AutoCheckUpdates  = $chkAutoCheckUpdates.IsChecked
            $sharedState.AutoApplyUpdates  = $chkAutoApplyUpdates.IsChecked
            
            Append-LogLine "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [SYSTEM ] Settings applied successfully." "SUCCESS"
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
            $sharedState.BackupPath     = Join-Path $sharedState.RootPath "Backup"
            $sharedState.LogsPath       = Join-Path $sharedState.RootPath "Logs"
            $sharedState.UpdateTempPath = Join-Path $sharedState.RootPath "UpdateTemp"
            Update-PathLabels
            Save-Config
        }
    })

    $btnOpenFolder.Add_Click({
        $p = $sharedState.RootPath
        if (Test-Path $p) { Start-Process explorer.exe $p }
        else { [System.Windows.MessageBox]::Show("Folder does not exist yet.", "Folder Not Found", "OK", "Information") | Out-Null }
    })

    $btnClearLog.Add_Click({ $rtbLog.Document.Blocks.Clear() })

    # Helper for UI Logging (Thread-Safe via Timer)
    function Append-LogLine {
        param([string]$text, [string]$colour)
        [System.Threading.Monitor]::Enter($sharedState.PendingMessages.SyncRoot)
        try { $sharedState.PendingMessages.Add(@{ Text = $text; Level = $colour }) | Out-Null }
        finally { [System.Threading.Monitor]::Exit($sharedState.PendingMessages.SyncRoot) }
    }

    function Start-BackgroundWork {
        param([ScriptBlock]$Work)

        $bgRS = [RunspaceFactory]::CreateRunspace()
        $bgRS.ApartmentState = "MTA"
        $bgRS.Open()
        $bgRS.SessionStateProxy.SetVariable("state", $sharedState)

        $bgPS = [PowerShell]::Create()
        $bgPS.Runspace = $bgRS

        $bgPS.AddScript({
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
                    
                    # Purge old logs
                    Get-ChildItem -Path $logDir -Filter "BedrockServerManager_*.log" -ErrorAction SilentlyContinue | 
                        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$state.LogRetentionDays) } | 
                        Remove-Item -Force -ErrorAction SilentlyContinue
                } catch { }
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
                $state.PendingProgress = @{ Type = $Type; Value = $Value }
            }

            function Get-RunningServer {
                $exeName = [System.IO.Path]::GetFileNameWithoutExtension($state.ServerExecutable)
                $exePath = Join-Path $state.ServerPath $state.ServerExecutable
                if (-not (Test-Path $exePath)) { return $null }
                return Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exePath }
            }

            function Get-AppliedVersion {
                # Placed in ServerPath so it doesn't get deleted if we purge UpdateTempPath
                $vPath = Join-Path $state.ServerPath "applied_version.txt"
                if (Test-Path $vPath) {
                    return (Get-Content $vPath -ErrorAction SilentlyContinue).Trim()
                }
                return $null
            }

            function Set-AppliedVersion {
                param([string]$Version)
                $vPath = Join-Path $state.ServerPath "applied_version.txt"
                Set-Content -Path $vPath -Value $Version -Force -ErrorAction SilentlyContinue
            }

            function Get-InstalledVersion {
                $exe = Join-Path $state.ServerPath $state.ServerExecutable
                if (Test-Path $exe) {
                    $vi = (Get-Item $exe).VersionInfo
                    $v = $vi.ProductVersion
                    if (-not $v) { $v = $vi.FileVersion } # Fallback to FileVersion
                    if ($v -and $v.Trim() -ne "") { return $v.Trim() }
                    
                    # Fallback: Read from applied_version.txt
                    $appliedVer = Get-AppliedVersion
                    if ($appliedVer) { return $appliedVer }
                    
                    return $null
                }
                return $null
            }

            function Test-ServerInstalled {
                return (Test-Path (Join-Path $state.ServerPath $state.ServerExecutable))
            }

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
                if (-not $proc) { return }
                Write-Log "Stopping server (PID $($proc.Id))..." -Level WARN
                Set-StatusLabel "lblServerStatus" "STOPPING…" "orange"
                $proc | Stop-Process -Force:$false -ErrorAction SilentlyContinue
                $elapsed = 0
                while ((Get-RunningServer) -and $elapsed -lt $state.ServerStopTimeout) {
                    Start-Sleep -Seconds 1; $elapsed++
                }
                if (Get-RunningServer) {
                    Write-Log "Force-killing server..." -Level WARN
                    Get-RunningServer | Stop-Process -Force
                    Start-Sleep -Seconds 2
                }
                $state.IsRunning = $false
                $state.ExpectedToRun = $false
                Write-Log "Server stopped." -Level SUCCESS
                Set-StatusLabel "lblServerStatus" "STOPPED" "red"
            }

            function Backup-Configs {
                $backupRoot = $state.BackupPath
                $revName    = "rev_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                $revDir     = Join-Path $backupRoot $revName
                
                if (-not (Test-Path $revDir)) { New-Item -ItemType Directory -Path $revDir -Force | Out-Null }
                
                Write-Log "Backing up configuration files to $revName..."
                $n = 0
                foreach ($f in $state.FilesToBackup) {
                    $src = Join-Path $state.ServerPath $f
                    if (Test-Path $src) {
                        Copy-Item $src $revDir -Force
                        Write-Log "  Backed up: $f" -Level SUCCESS
                        $n++
                    }
                }
                Write-Log "Backup complete ($n file(s))."
                
                # Purge old backups
                $oldBackups = Get-ChildItem $backupRoot -Directory | Sort-Object Name -Descending | Select-Object -Skip $state.MaxBackups
                if ($oldBackups) {
                    Write-Log "Purging $($oldBackups.Count) old backup(s) to retain max $($state.MaxBackups)..." -Level SYSTEM
                    $oldBackups | Remove-Item -Recurse -Force
                }
            }

            function Restore-Configs {
                $backupRoot = $state.BackupPath
                if (-not (Test-Path $backupRoot)) { return }
                
                $latestRev = Get-ChildItem $backupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
                if (-not $latestRev) { return }
                
                Write-Log "Restoring configuration files from $($latestRev.Name)..."
                $n = 0
                foreach ($f in $state.FilesToBackup) {
                    $s = Join-Path $latestRev.FullName $f
                    if (Test-Path $s) {
                        $d = Join-Path $state.ServerPath $f
                        Copy-Item $s $d -Force
                        
                        $srcHash = (Get-FileHash -Path $s -Algorithm MD5).Hash
                        $dstHash = (Get-FileHash -Path $d -Algorithm MD5).Hash
                        
                        if ($srcHash -eq $dstHash) {
                            Write-Log "  Restored & verified: $f" -Level SUCCESS
                            $n++
                        } else {
                            Write-Log "  Checksum FAILED for: $f" -Level ERROR
                            throw "Checksum verification failed for $f"
                        }
                    }
                }
                Write-Log "Restore complete ($n file(s) verified)."
            }

            function Fetch-LatestVersion {
                Write-Log "Contacting Minecraft API…" -Level SYSTEM
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $headers = @{ "User-Agent" = "Mozilla/5.0"; "Accept" = "application/json" }
                $resp = Invoke-RestMethod -Uri $state.ApiUrl -Method Get -Headers $headers -TimeoutSec 15
                $link = $resp.result.links | Where-Object { $_.downloadType -eq "serverBedrockWindows" } | Select-Object -First 1
                if (-not $link -or -not $link.downloadUrl) { throw "API did not return a valid download URL." }
                return @{ Url = $link.downloadUrl; Filename = [System.IO.Path]::GetFileName($link.downloadUrl) }
            }

            function Extract-VersionFromFilename {
                param([string]$Filename)
                if ($Filename -match "bedrock-server-(.+?)\.zip") { return $matches[1] }
                return $Filename
            }

            function Start-ServerProcess {
                $exe = Join-Path $state.ServerPath $state.ServerExecutable
                if (-not (Test-Path $exe)) { return }
                Write-Log "Starting server (minimized)…" -Level SYSTEM
                Set-StatusLabel "lblServerStatus" "STARTING…" "orange"
                
                # Start minimized
                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName = $exe
                $startInfo.WorkingDirectory = $state.ServerPath
                $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
                [System.Diagnostics.Process]::Start($startInfo) | Out-Null
                
                Start-Sleep -Seconds 3
                $proc = Get-RunningServer
                if ($proc) {
                    $state.IsRunning = $true
                    $state.ExpectedToRun = $true
                    Set-StatusLabel "lblServerStatus" "RUNNING (PID $($proc.Id))" "green"
                    Write-Log "Server started (PID $($proc.Id))." -Level SUCCESS
                } else {
                    $state.IsRunning = $false
                    Set-StatusLabel "lblServerStatus" "START UNCERTAIN" "orange"
                    Write-Log "Server process not confirmed. Check manually." -Level WARN
                }
            }

            function Refresh-InstalledLabel {
                $ver = Get-InstalledVersion
                if ($ver) {
                    Set-StatusLabel "lblInstalled" $ver "white"
                    $state.InstalledVersion = $ver
                }
            }

            function Download-AndInstall {
                param([string]$Url, [string]$Filename, [bool]$IsFirstSetup)

                $updateDir = $state.UpdateTempPath
                $zipPath   = Join-Path $updateDir $Filename

                Initialize-ServerDirectories
                Set-Progress "value" 5

                if (-not $IsFirstSetup) { Stop-GameServer }
                Set-Progress "value" 12

                if (Test-ServerInstalled) { Backup-Configs }
                Set-Progress "value" 22

                Write-Log "Downloading: $Filename …"
                $ProgressPreference = "SilentlyContinue"
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $Url -OutFile $zipPath -TimeoutSec $state.DownloadTimeout
                
                # Validate Download
                if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 1MB) { throw "Download failed or file is too small (corrupt)." }
                Write-Log "Verifying archive integrity..." -Level SYSTEM
                try {
                    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
                    $entries = $zipArchive.Entries.Count
                    $zipArchive.Dispose()
                    if ($entries -lt 5) { throw "Archive seems empty or invalid." }
                    Write-Log "Archive verified ($entries entries)." -Level SUCCESS
                } catch {
                    throw "Downloaded ZIP archive is corrupt or invalid: $($_.Exception.Message)"
                }

                $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
                Write-Log "Download complete ($sizeMB MB)." -Level SUCCESS
                Set-Progress "value" 58

                Write-Log "Extracting server files to $($state.ServerPath)…"
                try {
                    Expand-Archive -LiteralPath $zipPath -DestinationPath $state.ServerPath -Force
                } catch {
                    throw "Extraction failed: $($_.Exception.Message)"
                }
                
                # Verify Extraction
                $extractedExe = Join-Path $state.ServerPath $state.ServerExecutable
                if (-not (Test-Path $extractedExe)) {
                    throw "Extraction verification failed: $state.ServerExecutable not found."
                }
                Write-Log "Extraction complete & verified." -Level SUCCESS
                Set-Progress "value" 80

                if (-not $IsFirstSetup) { Restore-Configs }
                Set-Progress "value" 90

                # Set applied version and cleanup zip to save space
                $verLatest = Extract-VersionFromFilename $Filename
                Set-AppliedVersion -Version $verLatest
                if (Test-Path $zipPath) {
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    Write-Log "Cleaned up downloaded archive." -Level SYSTEM
                }

                Refresh-InstalledLabel

                Set-StatusLabel "lblLatest"       $verLatest    "blue"
                Set-StatusLabel "lblSetupStatus"  "INSTALLED"   "green"
                Set-StatusLabel "lblUpdateStatus" "UP TO DATE"  "green"
                
                $state.IsInstalled = $true
                $state.UpdateAvailable = $false

                if ($state.StartAfterUpdate) {
                    Start-ServerProcess
                } else {
                    Set-StatusLabel "lblServerStatus" "STOPPED" "red"
                }

                Set-StatusLabel "lblLastChecked" (Get-Date -Format "yyyy-MM-dd HH:mm:ss") "gray"
                Set-Progress "value" 100
                [System.GC]::Collect()
            }

            function Periodic-StatusCheck {
                Write-Log "── Periodic status check ──" -Level PERIODIC

                if (Test-ServerInstalled) {
                    $state.IsInstalled = $true
                    
                    # Attempt to sync applied_version.txt if missing
                    $appliedVer = Get-AppliedVersion
                    if (-not $appliedVer) {
                        $exeVer = Get-InstalledVersion
                        if ($exeVer) {
                            Set-AppliedVersion -Version $exeVer
                            $appliedVer = $exeVer
                        }
                    }

                    Refresh-InstalledLabel
                    Set-StatusLabel "lblSetupStatus" "INSTALLED" "green"
                } else {
                    $state.IsInstalled = $false
                    Set-StatusLabel "lblInstalled"   "Not installed" "red"
                    Set-StatusLabel "lblSetupStatus" "NOT INSTALLED" "red"
                    Set-StatusLabel "lblLastChecked" (Get-Date -Format "yyyy-MM-dd HH:mm:ss") "gray"
                    return
                }

                $proc = Get-RunningServer
                if ($proc) {
                    $state.IsRunning = $true
                    $state.ExpectedToRun = $true
                    Set-StatusLabel "lblServerStatus" "RUNNING (PID $($proc.Id))" "green"
                } else {
                    $state.IsRunning = $false
                    Set-StatusLabel "lblServerStatus" "STOPPED" "red"
                }

                try {
                    $latest  = Fetch-LatestVersion
                    $state.LatestUrl      = $latest.Url
                    $state.LatestFilename = $latest.Filename
                    $verLatest = Extract-VersionFromFilename $latest.Filename
                    $state.LatestVersion  = $verLatest
                    Set-StatusLabel "lblLatest" $verLatest "blue"

                    # Compare applied version with latest version
                    $currentVer = Get-AppliedVersion
                    if (-not $currentVer) {
                        Write-Log "Installed version unknown. Syncing tracking file to latest ($verLatest) to prevent false update loops." -Level WARN
                        Set-AppliedVersion -Version $verLatest
                        $currentVer = $verLatest
                    }

                    if ($currentVer -eq $verLatest) {
                        $state.UpdateAvailable = $false
                        Set-StatusLabel "lblUpdateStatus" "UP TO DATE" "green"
                    } else {
                        $state.UpdateAvailable = $true
                        Set-StatusLabel "lblUpdateStatus" "UPDATE AVAILABLE" "orange"
                        Write-Log "New version available: $verLatest" -Level WARN
                        
                        if ($state.AutoApplyUpdates) {
                            Write-Log "Auto-apply enabled. Starting update process..." -Level SYSTEM
                            Download-AndInstall -Url $latest.Url -Filename $latest.Filename -IsFirstSetup $false
                        }
                    }
                } catch {
                    Write-Log "Periodic update check failed: $($_.Exception.Message)" -Level WARN
                }

                Set-StatusLabel "lblLastChecked" (Get-Date -Format "yyyy-MM-dd HH:mm:ss") "gray"
                Write-Log "── Periodic check done ──" -Level PERIODIC
            }
        }).AddScript($Work).AddScript({ [System.GC]::Collect() })

        $handle = $bgPS.BeginInvoke()
        $job = @{ PS = $bgPS; RS = $bgRS; Handle = $handle }
        [System.Threading.Monitor]::Enter($script:activeJobs.SyncRoot)
        try { $script:activeJobs.Add($job) | Out-Null }
        finally { [System.Threading.Monitor]::Exit($script:activeJobs.SyncRoot) }
    }

    $btnFirstSetup.Add_Click({
        if ($sharedState.IsBusy) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true
            Set-Progress "indeterminate"
            try {
                if (Test-ServerInstalled) {
                    Write-Log "Server is already installed. Use 'Download and Update' instead." -Level WARN
                    Set-Progress "reset"
                    return
                }
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
            } finally {
                Set-Busy $false
            }
        }
    })

    $btnCheckUpdate.Add_Click({
        if ($sharedState.IsBusy) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true
            Set-Progress "indeterminate"
            try {
                Write-Log "Checking for updates…"
                if (-not (Test-ServerInstalled)) {
                    Write-Log "No installation found." -Level WARN
                    return
                }

                Refresh-InstalledLabel
                $latest = Fetch-LatestVersion
                $state.LatestUrl      = $latest.Url
                $state.LatestFilename = $latest.Filename
                $ver = Extract-VersionFromFilename $latest.Filename
                $state.LatestVersion  = $ver
                Set-StatusLabel "lblLatest" $ver "blue"

                $appliedVer = Get-AppliedVersion
                if (-not $appliedVer) {
                    Write-Log "Installed version unknown. Syncing tracking file to latest ($ver) to prevent false update loops." -Level WARN
                    Set-AppliedVersion -Version $ver
                    $appliedVer = $ver
                }

                if ($appliedVer -eq $ver) {
                    $state.UpdateAvailable = $false
                    Write-Log "Already up to date." -Level SUCCESS
                    Set-StatusLabel "lblUpdateStatus" "UP TO DATE" "green"
                } else {
                    $state.UpdateAvailable = $true
                    Write-Log "Update available: $ver" -Level WARN
                    Set-StatusLabel "lblUpdateStatus" "UPDATE AVAILABLE" "orange"
                }

                $proc = Get-RunningServer
                if ($proc) {
                    $state.IsRunning = $true
                    Set-StatusLabel "lblServerStatus" "RUNNING (PID $($proc.Id))" "green"
                } else {
                    $state.IsRunning = $false
                    Set-StatusLabel "lblServerStatus" "STOPPED" "red"
                }

                Set-StatusLabel "lblLastChecked" (Get-Date -Format "yyyy-MM-dd HH:mm:ss") "gray"
            } catch {
                Write-Log "Error checking for updates: $($_.Exception.Message)" -Level ERROR
            } finally {
                Set-Progress "reset"
                Set-Busy $false
            }
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
            } finally {
                Set-Busy $false
            }
        }
    })

    $btnStartServer.Add_Click({
        if ($sharedState.IsBusy -or $sharedState.IsRunning) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true
            try {
                if (Get-RunningServer) { return }
                if (-not (Test-ServerInstalled)) { Write-Log "Executable not found." -Level ERROR; return }
                Start-ServerProcess
            } catch {
                Write-Log "Error starting server: $($_.Exception.Message)" -Level ERROR
            } finally {
                Set-Busy $false
            }
        }
    })

    $btnStopServer.Add_Click({
        if ($sharedState.IsBusy -or -not $sharedState.IsRunning) { return }
        Start-BackgroundWork -Work {
            Set-Busy $true
            try {
                if (-not (Get-RunningServer)) { return }
                Stop-GameServer
            } catch {
                Write-Log "Error stopping server: $($_.Exception.Message)" -Level ERROR
            } finally {
                Set-Busy $false
            }
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
                    
                    # Sync applied version if missing
                    if (-not (Get-AppliedVersion)) {
                        $exeVer = Get-InstalledVersion
                        if ($exeVer) { Set-AppliedVersion -Version $exeVer }
                    }

                    Refresh-InstalledLabel
                    Set-StatusLabel "lblSetupStatus" "INSTALLED" "green"
                } else {
                    $state.IsInstalled = $false
                    Set-StatusLabel "lblInstalled"   "Not installed" "red"
                    Set-StatusLabel "lblSetupStatus" "NOT INSTALLED" "red"
                }

                $proc = Get-RunningServer
                if ($proc) {
                    $state.IsRunning = $true
                    $state.ExpectedToRun = $true
                    Set-StatusLabel "lblServerStatus" "RUNNING (PID $($proc.Id))" "green"
                } else {
                    $state.IsRunning = $false
                    Set-StatusLabel "lblServerStatus" "STOPPED" "red"
                }

                Set-StatusLabel "lblLastChecked" (Get-Date -Format "yyyy-MM-dd HH:mm:ss") "gray"
                Write-Log "Status refreshed." -Level SUCCESS
            } catch {
                Write-Log "Error refreshing: $($_.Exception.Message)" -Level ERROR
            } finally {
                Set-Busy $false
            }
        }
    })

    $window.Add_Closed({
        $timer.Stop()
        $sharedState.WindowClosed = $true
        Save-Config
    })

    $window.Add_ContentRendered({
        $sharedState.GuiReady = $true
        Update-PathLabels

        $exe = Join-Path $sharedState.ServerPath $sharedState.ServerExecutable
        if (Test-Path $exe) {
            $sharedState.IsInstalled = $true
            
            $v = (Get-Item $exe).VersionInfo.ProductVersion
            if (-not $v) { $v = (Get-Item $exe).VersionInfo.FileVersion }
            if (-not $v -or $v.Trim() -eq "") {
                # Fallback to applied_version.txt
                $appliedVer = Get-AppliedVersion
                if ($appliedVer) {
                    $v = $appliedVer
                } else {
                    $v = "Unknown"
                }
            } else {
                $v = $v.Trim()
                # Sync applied_version.txt if we successfully read it from EXE but file is missing
                if (-not (Get-AppliedVersion)) {
                    Set-AppliedVersion -Version $v
                }
            }
            
            $lblInstalled.Text     = $v
            $lblInstalled.Foreground = $statusBrushCache["white"]
            $lblSetupStatus.Text   = "INSTALLED"
            $lblSetupStatus.Foreground = $statusBrushCache["green"]

            $exeName = [System.IO.Path]::GetFileNameWithoutExtension($sharedState.ServerExecutable)
            $proc    = Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }
            if ($proc) {
                $sharedState.IsRunning = $true
                $sharedState.ExpectedToRun = $true
                $lblServerStatus.Text      = "RUNNING (PID $($proc.Id))"
                $lblServerStatus.Foreground = $statusBrushCache["green"]
            } else {
                $sharedState.IsRunning = $false
                $lblServerStatus.Text      = "STOPPED"
                $lblServerStatus.Foreground = $statusBrushCache["red"]
            }
        } else {
            $sharedState.IsInstalled = $false
            $sharedState.IsRunning = $false
            $lblInstalled.Text     = "Not installed"
            $lblInstalled.Foreground = $statusBrushCache["red"]
            $lblSetupStatus.Text   = "NOT INSTALLED"
            $lblSetupStatus.Foreground = $statusBrushCache["red"]
            $lblServerStatus.Text  = "N/A"
            $lblServerStatus.Foreground = $statusBrushCache["orange"]
        }

        $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Append-LogLine "$now [SYSTEM ] ═══════════════════════════════════════════" "SYSTEM"
        Append-LogLine "$now [SYSTEM ]   Minecraft Bedrock Server Manager v17.0"    "SUCCESS"
        Append-LogLine "$now [SYSTEM ]   PowerShell $($PSVersionTable.PSVersion)"   "SYSTEM"
        Append-LogLine "$now [SYSTEM ] ═══════════════════════════════════════════" "SYSTEM"

        if (-not (Test-Path $exe)) {
            Append-LogLine "$now [WARN   ] No installation detected — click 'Setup / Install Server' to begin." "WARN"
        } else {
            Append-LogLine "$now [INFO   ] Installation found. Performing initial update check..." "INFO"
            
            # Force an initial update check on launch
            Start-BackgroundWork -Work {
                Set-Busy $true
                try {
                    Periodic-StatusCheck
                } finally {
                    Set-Busy $false
                }
            }

            if ($sharedState.AutoLaunchOnStart -and -not $sharedState.IsRunning) {
                Append-LogLine "$now [SYSTEM ] Auto-launch enabled. Starting server..." "SYSTEM"
                Start-BackgroundWork -Work {
                    Set-Busy $true
                    try { Start-ServerProcess } finally { Set-Busy $false }
                }
            }
        }

        Update-ButtonStates
    })

    $window.ShowDialog() | Out-Null

}) | Out-Null

# ─── Launch GUI ───────────────────────────────────────────────────────────────
 $guiHandle = $guiPowerShell.BeginInvoke()

try {
    while (-not $guiHandle.IsCompleted) {
        Start-Sleep -Milliseconds 200
    }
} finally {
    $guiPowerShell.EndInvoke($guiHandle)
    $guiPowerShell.Dispose()
    $guiRunspace.Close()
    $guiRunspace.Dispose()
    [System.GC]::Collect()
}
