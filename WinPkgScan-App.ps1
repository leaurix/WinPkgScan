<#
.SYNOPSIS
    WinPkgScan app (preview): scan, mark, remove and restore leftover app
    folders in one window.

.DESCRIPTION
    A Windows window on top of the WinPkgScan scripts. It runs the scanner,
    shows the results with tick boxes, and runs the remover and restore
    scripts. Every safety check of the scripts still applies: marked folders
    are checked again before anything is removed, and they go to the
    Recycle Bin. Nothing is removed without your confirmation.

    The app keeps its own scan results and logs in
    %LOCALAPPDATA%\WinPkgScan\app, so it does not touch the reports on your
    Desktop.

.PARAMETER SelfTest
    Build the window without showing it, check that every part loads, and
    exit with code 0 (OK) or 1 (problem). Used by the test suite.

.PARAMETER TestMode
    Load the app's functions only, without any window. Used by the test
    suite on systems without Windows.

.EXAMPLE
    .\WinPkgScan-App.ps1

.NOTES
    Version: 1.7.0
    Needs Windows (WPF). Start it with WinPkgScan-App.bat.
#>

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$TestMode
)

$AppVersion = "1.7.0"

# ------------------------------------------------------------
# Row shown in the results list. A small class, so tick boxes update the
# marked total as soon as they are clicked.
# ------------------------------------------------------------

if (-not ('WinPkgScanApp.Row' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;

namespace WinPkgScanApp
{
    public class Row : INotifyPropertyChanged
    {
        private bool _marked;
        public event PropertyChangedEventHandler PropertyChanged;

        public bool Marked
        {
            get { return _marked; }
            set
            {
                if (_marked == value) { return; }
                _marked = value;
                PropertyChangedEventHandler handler = PropertyChanged;
                if (handler != null) { handler(this, new PropertyChangedEventArgs("Marked")); }
            }
        }

        public bool CanMark { get; set; }
        public string FolderName { get; set; }
        public double SizeMB { get; set; }
        public string LastModified { get; set; }
        public string Category { get; set; }
        public string Notes { get; set; }
        public bool IsNew { get; set; }
        public string NewText { get { return IsNew ? "New" : ""; } }
        public string FullPath { get; set; }
        public string Status { get; set; }
    }
}
'@
}

function Get-HistoryPath {
    return Join-Path (Join-Path $env:LOCALAPPDATA 'WinPkgScan') 'history.json'
}

function Read-History {
    # Scan history: past scans (with folder names), removals and restores.
    param([string]$Path)
    $history = [PSCustomObject]@{ Scans = @(); Removals = @(); Restores = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $history }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ($text.Trim()) {
            $data = $text | ConvertFrom-Json -ErrorAction Stop
            if ($data.Scans)    { $history.Scans    = @($data.Scans) }
            if ($data.Removals) { $history.Removals = @($data.Removals) }
            if ($data.Restores) { $history.Restores = @($data.Restores) }
        }
    }
    catch {
        Write-Host "WARNING: The scan history could not be read, so it starts again: $($_.Exception.Message)" -ForegroundColor Yellow
        try {
            Copy-Item -LiteralPath $Path -Destination "$Path.bad" -Force -ErrorAction Stop -WhatIf:$false -Confirm:$false
        }
        catch {
            Write-Verbose "Could not keep a copy of the unreadable history: $($_.Exception.Message)"
        }
    }
    return $history
}

function Save-History {
    param($History, [string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false | Out-Null
    }
    $data = [ordered]@{
        Version  = 1
        Scans    = @(@($History.Scans)    | Select-Object -Last 50)
        Removals = @(@($History.Removals) | Select-Object -Last 1000)
        Restores = @(@($History.Restores) | Select-Object -Last 1000)
    }
    $json = ConvertTo-Json -InputObject $data -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-FreedMB {
    # Space freed with WinPkgScan: removals minus restores.
    param($History)
    $freed = 0.0
    foreach ($r in @($History.Removals)) { if ($r) { $freed += [double]$r.FreedMB } }
    foreach ($r in @($History.Restores)) { if ($r) { $freed -= [double]$r.SizeMB } }
    if ($freed -lt 0) { $freed = 0 }
    return [math]::Round($freed, 2)
}

# ------------------------------------------------------------
# Logic (no window). Tested by tests/WinPkgScan-App.Tests.ps1.
# ------------------------------------------------------------

function Get-AppPath {
    # Where the app keeps its files, and where the scripts are.
    param([string]$ScriptFolder = $PSScriptRoot)
    $data = Join-Path $env:LOCALAPPDATA 'WinPkgScan'
    $app  = Join-Path $data 'app'
    [PSCustomObject]@{
        DataDir    = $data
        AppDir     = $app
        Report     = Join-Path $app 'Orphaned-Appx-Packages.txt'
        Csv        = Join-Path $app 'Orphaned-Appx-Packages.csv'
        Html       = Join-Path $app 'Orphaned-Appx-Packages.html'
        Marked     = Join-Path $app 'WinPkgScan-marked-app.csv'
        PreviewLog = Join-Path $app 'preview-log.csv'
        Output     = Join-Path $app 'last-output.txt'
        History    = Join-Path $data 'history.json'
        Scanner    = Join-Path $ScriptFolder 'Find-OrphanedAppxFolders.ps1'
        Remover    = Join-Path $ScriptFolder 'Remove-OrphanedAppxFolders.ps1'
        Restorer   = Join-Path $ScriptFolder 'Restore-OrphanedAppxFolders.ps1'
    }
}

function ConvertTo-AppRow {
    param($Item)
    $size = 0.0
    [void][double]::TryParse("$($Item.SizeMB)", [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$size)
    $row = New-Object WinPkgScanApp.Row
    $row.FolderName   = "$($Item.FolderName)"
    $row.SizeMB       = $size
    $row.LastModified = "$($Item.LastModified)"
    $row.Category     = "$($Item.Category)"
    $row.Notes        = "$($Item.Notes)"
    $row.IsNew        = ("$($Item.New)" -eq 'Yes')
    $row.FullPath     = "$($Item.FullPath)"
    $row.Status       = "$($Item.Status)"
    # Only orphaned package folders can be marked. Windows components and
    # other folders are shown for information.
    $row.CanMark      = ($row.Category -eq 'Orphaned package')
    return $row
}

function Read-ScanResult {
    # Reads the scanner CSV into rows for the list.
    param([string]$CsvPath)
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) { return }
    foreach ($item in @(Import-Csv -LiteralPath $CsvPath)) {
        if ($item.FolderName) { $rows.Add((ConvertTo-AppRow $item)) }
    }
    return $rows.ToArray()
}

function Get-MarkedTotal {
    param([object[]]$Rows)
    $marked = @($Rows | Where-Object { $_.Marked -and $_.CanMark })
    $mb = 0.0
    foreach ($r in $marked) { $mb += $r.SizeMB }
    [PSCustomObject]@{ Count = $marked.Count; SizeMB = [math]::Round($mb, 2) }
}

function Test-RowVisible {
    # View: 0 = orphaned folders, 1 = new since last scan, 2 = all folders.
    param($Row, [int]$View, [string]$Filter)
    if ($View -eq 0 -and $Row.Category -ne 'Orphaned package') { return $false }
    if ($View -eq 1 -and -not $Row.IsNew) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $q = $Filter.Trim()
        $hit = ($Row.FolderName -and $Row.FolderName.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
               ($Row.Notes -and $Row.Notes.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $hit) { return $false }
    }
    return $true
}

function Export-MarkedCsv {
    # Writes the marked rows in the remover's CSV format (UTF-8 with BOM).
    param([object[]]$Rows, [string]$Path)
    $marked = @($Rows | Where-Object { $_.Marked -and $_.CanMark } | ForEach-Object {
        [PSCustomObject]@{
            Delete       = 'Yes'
            Category     = $_.Category
            FolderName   = $_.FolderName
            SizeMB       = $_.SizeMB.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
            LastModified = $_.LastModified
            FullPath     = $_.FullPath
            Status       = $_.Status
            Notes        = $_.Notes
        }
    })
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lines = @($marked | ConvertTo-Csv -NoTypeInformation)
    [System.IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    return $marked.Count
}

function Get-LogSummary {
    # Reads a delete log and counts what happened to each folder.
    param([string]$Path)
    $rows = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Import-Csv -LiteralPath $Path) } else { @() }
    $count = { param($a) @($rows | Where-Object Action -eq $a).Count }
    $mb = 0.0
    foreach ($r in @($rows | Where-Object { $_.Action -in 'Recycled', 'Deleted', 'WhatIf' })) {
        $v = 0.0
        [void][double]::TryParse("$($r.SizeMB)", [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)
        $mb += $v
    }
    [PSCustomObject]@{
        Rows     = $rows
        Recycled = & $count 'Recycled'
        Deleted  = & $count 'Deleted'
        WhatIf   = & $count 'WhatIf'
        Skipped  = & $count 'Skipped'
        Failed   = & $count 'Failed'
        SizeMB   = [math]::Round($mb, 2)
    }
}

function Format-LogSummary {
    # The text shown after Preview or Move to Recycle Bin.
    param($Summary, [switch]$Preview)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Preview) {
        $lines.Add("Would move to the Recycle Bin: $($Summary.WhatIf) ($($Summary.SizeMB) MB)")
    }
    else {
        $lines.Add("Moved to the Recycle Bin: $($Summary.Recycled + $Summary.Deleted) ($($Summary.SizeMB) MB)")
    }
    $lines.Add("Skipped: $($Summary.Skipped)")
    if ($Summary.Failed -gt 0) { $lines.Add("Failed: $($Summary.Failed)") }
    $problems = @($Summary.Rows | Where-Object { $_.Action -in 'Skipped', 'Failed' } | Select-Object -First 12)
    if ($problems.Count -gt 0) {
        $lines.Add('')
        foreach ($p in $problems) { $lines.Add("$($p.Action): $($p.FolderName)  -  $($p.Reason)") }
        $more = @($Summary.Rows | Where-Object { $_.Action -in 'Skipped', 'Failed' }).Count - $problems.Count
        if ($more -gt 0) { $lines.Add("...and $more more. See the log for all of them.") }
    }
    if (-not $Preview -and ($Summary.Recycled -gt 0)) {
        $lines.Add('')
        $lines.Add('You can put them back with Restore last delete.')
    }
    return ($lines -join "`n")
}

function Get-NewestDeleteLog {
    param([string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $Folder -Filter 'WinPkgScan-DeleteLog-*.csv' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function ConvertTo-ArgumentText {
    # Joins arguments for a command line, quoting any with spaces.
    param([string[]]$Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    return ($parts -join ' ')
}

function Get-ScriptCommandLine {
    # Arguments for powershell.exe to run one of the WinPkgScan scripts.
    param([string]$Script, [string[]]$Arguments = @())
    return (ConvertTo-ArgumentText (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments))
}

function Get-PowerShellPath {
    try { return (Get-Process -Id $PID).Path } catch { return 'powershell.exe' }
}

function Get-HistorySummary {
    param([string]$Path)
    $history  = Read-History -Path $Path
    $lastScan = @($history.Scans) | Select-Object -Last 1
    [PSCustomObject]@{
        LastScan = if ($lastScan) { "$($lastScan.Time)" } else { '' }
        Scans    = @($history.Scans).Count
        FreedMB  = Get-FreedMB $history
    }
}

if ($TestMode) { return }

# ------------------------------------------------------------
# Window (Windows only)
# ------------------------------------------------------------

# WPF needs a single-threaded apartment. Restart with -STA if needed.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argLine = Get-ScriptCommandLine -Script $PSCommandPath -Arguments $(if ($SelfTest) { @('-SelfTest') } else { @() })
    $proc = Start-Process -FilePath (Get-PowerShellPath) -ArgumentList "-STA $argLine" -WindowStyle Hidden -PassThru -Wait:$SelfTest
    if ($SelfTest) { exit $proc.ExitCode }
    exit 0
}

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinPkgScan" Width="1080" Height="720" MinWidth="820" MinHeight="520"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        Background="#F7F7F5" Foreground="#1D1D1F">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#CFCFCB"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2F6FDE"/>
      <Setter Property="BorderBrush" Value="#2F6FDE"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#E2E2E0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style x:Key="CardValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Text" Value="-"/>
    </Style>
    <Style x:Key="CardLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6B6B70"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
  </Window.Resources>

  <DockPanel Margin="18">

    <!-- Header -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,14">
      <StackPanel>
        <TextBlock Text="WinPkgScan" FontSize="22" FontWeight="SemiBold"/>
        <TextBlock x:Name="SubTitle" Foreground="#6B6B70" Text="Find and safely remove leftover app folders"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Button x:Name="ReportButton" Content="Open HTML report"/>
        <Button x:Name="AdminScanButton" Content="Scan as administrator"
                ToolTip="Extra checks: apps still registered to you in an unfinished state are kept out"/>
        <Button x:Name="ScanButton" Content="Scan" Style="{StaticResource Primary}"/>
      </StackPanel>
    </Grid>

    <!-- Summary cards -->
    <UniformGrid DockPanel.Dock="Top" Columns="5" Margin="0,0,-10,14">
      <Border Style="{StaticResource Card}">
        <StackPanel><TextBlock x:Name="OrphanValue" Style="{StaticResource CardValue}"/>
          <TextBlock Style="{StaticResource CardLabel}" Text="Orphaned folders"/></StackPanel>
      </Border>
      <Border Style="{StaticResource Card}">
        <StackPanel><TextBlock x:Name="NewValue" Style="{StaticResource CardValue}"/>
          <TextBlock Style="{StaticResource CardLabel}" Text="New since last scan"/></StackPanel>
      </Border>
      <Border Style="{StaticResource Card}">
        <StackPanel><TextBlock x:Name="WindowsValue" Style="{StaticResource CardValue}"/>
          <TextBlock Style="{StaticResource CardLabel}" Text="Windows components (keep)"/></StackPanel>
      </Border>
      <Border Style="{StaticResource Card}">
        <StackPanel><TextBlock x:Name="OtherValue" Style="{StaticResource CardValue}"/>
          <TextBlock Style="{StaticResource CardLabel}" Text="Other folders"/></StackPanel>
      </Border>
      <Border Style="{StaticResource Card}">
        <StackPanel><TextBlock x:Name="FreedValue" Style="{StaticResource CardValue}"/>
          <TextBlock Style="{StaticResource CardLabel}" Text="Freed with WinPkgScan"/></StackPanel>
      </Border>
    </UniformGrid>

    <!-- Status bar -->
    <Grid DockPanel.Dock="Bottom" Margin="0,8,0,0">
      <TextBlock x:Name="StatusText" Foreground="#6B6B70" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"
                 Text="Click Scan to find leftover app folders."/>
      <ProgressBar x:Name="BusyBar" IsIndeterminate="True" Width="160" Height="6"
                   HorizontalAlignment="Right" Visibility="Collapsed"/>
    </Grid>

    <!-- Action bar -->
    <Border DockPanel.Dock="Bottom" Style="{StaticResource Card}" Margin="0,12,0,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="RestoreButton" Content="Restore last delete"/>
          <Button x:Name="PreviewButton" Content="Preview" IsEnabled="False"/>
          <Button x:Name="DeleteButton" Content="Move to Recycle Bin" Style="{StaticResource Primary}" IsEnabled="False"/>
        </StackPanel>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="MarkedText" Text="0 marked (0.00 MB)" FontWeight="SemiBold"/>
          <TextBlock Foreground="#6B6B70" FontSize="12" TextWrapping="Wrap"
                     Text="Marked folders are checked again before anything is removed, and go to the Recycle Bin."/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- View and filter -->
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8" LastChildFill="True">
      <TextBlock Text="Show" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <ComboBox x:Name="ViewBox" Width="200" SelectedIndex="0" VerticalContentAlignment="Center">
        <ComboBoxItem Content="Orphaned folders"/>
        <ComboBoxItem Content="New since last scan"/>
        <ComboBoxItem Content="All folders"/>
      </ComboBox>
      <CheckBox x:Name="MarkAllBox" Content="Mark all shown" VerticalAlignment="Center" Margin="16,0,0,0"/>
      <TextBlock Text="Filter" VerticalAlignment="Center" Margin="16,0,8,0"/>
      <TextBox x:Name="FilterBox" VerticalContentAlignment="Center" Padding="4,3"
               ToolTip="Type part of a folder name or note"/>
    </DockPanel>

    <!-- Results -->
    <Grid>
      <DataGrid x:Name="ResultsGrid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
                HeadersVisibility="Column" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#ECECEA"
                Background="#FFFFFF" BorderBrush="#E2E2E0" RowHeight="30" SelectionMode="Extended"
                AlternatingRowBackground="#FAFAF8">
        <DataGrid.RowStyle>
          <Style TargetType="DataGridRow">
            <Style.Triggers>
              <DataTrigger Binding="{Binding CanMark}" Value="False">
                <Setter Property="Foreground" Value="#6B6B70"/>
              </DataTrigger>
              <DataTrigger Binding="{Binding Marked}" Value="True">
                <Setter Property="Background" Value="#EAF1FD"/>
              </DataTrigger>
            </Style.Triggers>
          </Style>
        </DataGrid.RowStyle>
        <DataGrid.Columns>
          <DataGridTemplateColumn Width="40" CanUserSort="False">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <CheckBox IsChecked="{Binding Marked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                          IsEnabled="{Binding CanMark}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTextColumn Header="Folder" Binding="{Binding FolderName}" Width="2*" IsReadOnly="True"/>
          <DataGridTextColumn Header="New" Binding="{Binding NewText}" Width="50" IsReadOnly="True" Foreground="#2F6FDE" FontWeight="SemiBold"/>
          <DataGridTextColumn Header="Size (MB)" Binding="{Binding SizeMB, StringFormat=N2}" Width="90" IsReadOnly="True">
            <DataGridTextColumn.ElementStyle>
              <Style TargetType="TextBlock"><Setter Property="HorizontalAlignment" Value="Right"/></Style>
            </DataGridTextColumn.ElementStyle>
          </DataGridTextColumn>
          <DataGridTextColumn Header="Last modified" Binding="{Binding LastModified}" Width="110" IsReadOnly="True"/>
          <DataGridTextColumn Header="Group" Binding="{Binding Category}" Width="140" IsReadOnly="True"/>
          <DataGridTextColumn Header="Notes" Binding="{Binding Notes}" Width="*" IsReadOnly="True"/>
        </DataGrid.Columns>
      </DataGrid>
      <TextBlock x:Name="EmptyText" HorizontalAlignment="Center" VerticalAlignment="Center"
                 Foreground="#6B6B70" FontSize="14" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="420"
                 Text="No scan yet. Click Scan to find leftover app folders."/>
    </Grid>
  </DockPanel>
</Window>
'@

$ControlNames = @(
    'SubTitle', 'ReportButton', 'AdminScanButton', 'ScanButton',
    'OrphanValue', 'NewValue', 'WindowsValue', 'OtherValue', 'FreedValue',
    'StatusText', 'BusyBar', 'RestoreButton', 'PreviewButton', 'DeleteButton', 'MarkedText',
    'ViewBox', 'MarkAllBox', 'FilterBox', 'ResultsGrid', 'EmptyText'
)

function Show-Message {
    param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK')
    return [System.Windows.MessageBox]::Show($Text, 'WinPkgScan', $Buttons, $Icon)
}

function Get-OutputTail {
    # Last lines a script printed, for error messages.
    if (Test-Path -LiteralPath $Paths.Output) {
        return ((Get-Content -LiteralPath $Paths.Output -Tail 12) -join "`n")
    }
    return ''
}

function Show-BusyState {
    param([bool]$Busy, [string]$Text)
    $script:IsBusy = $Busy
    $ui.BusyBar.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    foreach ($b in 'ScanButton', 'AdminScanButton', 'RestoreButton', 'ReportButton') { $ui[$b].IsEnabled = -not $Busy }
    if ($Text) { $ui.StatusText.Text = $Text }
    Show-MarkedTotal
}

function Show-MarkedTotal {
    $total = Get-MarkedTotal -Rows @($script:Rows)
    $ui.MarkedText.Text = "$($total.Count) marked ($($total.SizeMB.ToString('0.00')) MB)"
    $canAct = ($total.Count -gt 0) -and -not $script:IsBusy
    $ui.PreviewButton.IsEnabled = $canAct
    $ui.DeleteButton.IsEnabled  = $canAct
}

function Show-ResultView {
    if ($script:View) { $script:View.Refresh() }
    $shown = 0
    if ($script:View) { foreach ($r in $script:View) { $shown++ } }
    if (@($script:Rows).Count -eq 0) {
        $ui.EmptyText.Text = if (Test-Path -LiteralPath $Paths.Csv) { 'No leftover app folders were found.' } else { 'No scan yet. Click Scan to find leftover app folders.' }
        $ui.EmptyText.Visibility = 'Visible'
    }
    elseif ($shown -eq 0) {
        $ui.EmptyText.Text = 'Nothing to show here. Try another view or clear the filter.'
        $ui.EmptyText.Visibility = 'Visible'
    }
    else {
        $ui.EmptyText.Visibility = 'Collapsed'
    }
}

function Import-ScanView {
    # Loads the app's last scan into the list and the summary cards.
    $rows = @(Read-ScanResult -CsvPath $Paths.Csv)
    $script:Rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($r in $rows) {
        $r.add_PropertyChanged({ Show-MarkedTotal })
        $script:Rows.Add($r)
    }
    $ui.ResultsGrid.ItemsSource = $script:Rows
    $script:View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
    $script:View.Filter = [Predicate[object]] {
        param($item)
        Test-RowVisible -Row $item -View $ui.ViewBox.SelectedIndex -Filter $ui.FilterBox.Text
    }

    $orphans = @($rows | Where-Object Category -eq 'Orphaned package')
    $mb = 0.0; foreach ($o in $orphans) { $mb += $o.SizeMB }
    $history = Get-HistorySummary -Path $Paths.History
    $ui.OrphanValue.Text  = "$($orphans.Count)  ($([math]::Round($mb, 2)) MB)"
    $ui.NewValue.Text     = if (-not (Test-Path -LiteralPath $Paths.Csv)) { '-' }
                            elseif ($history.Scans -gt 1) { "$(@($rows | Where-Object { $_.IsNew }).Count)" }
                            else { 'First scan' }
    $ui.WindowsValue.Text = "$(@($rows | Where-Object Category -eq 'Windows component').Count)"
    $ui.OtherValue.Text   = "$(@($rows | Where-Object Category -eq 'Other folder').Count)"
    $ui.FreedValue.Text   = "$($history.FreedMB) MB"

    $ui.MarkAllBox.IsChecked = $false
    if (Test-Path -LiteralPath $Paths.Csv) {
        $when = (Get-Item -LiteralPath $Paths.Csv).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $ui.StatusText.Text = "Scanned $when. Tick the orphaned folders to remove. Double-click a row to open its folder."
    }
    Show-ResultView
    Show-MarkedTotal
}

function Invoke-ScriptAsync {
    # Runs a WinPkgScan script in the background. $OnDone gets the exit code.
    param([string]$Script, [string[]]$Arguments, [string]$BusyText, [scriptblock]$OnDone, [switch]$Elevated)
    if (-not (Test-Path -LiteralPath $Paths.AppDir)) { New-Item -ItemType Directory -Path $Paths.AppDir -Force | Out-Null }
    Remove-Item -LiteralPath $Paths.Output -ErrorAction SilentlyContinue
    $exe  = Get-PowerShellPath
    $line = Get-ScriptCommandLine -Script $Script -Arguments $Arguments
    if ($Elevated) {
        $proc = Start-Process -FilePath $exe -ArgumentList $line -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
    }
    else {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $env:ComSpec
        $psi.Arguments       = '/d /s /c ""' + $exe + '" ' + $line + ' > "' + $Paths.Output + '" 2>&1"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    $script:Job = [PSCustomObject]@{ Process = $proc; OnDone = $OnDone }
    Show-BusyState -Busy $true -Text $BusyText
    $script:Timer.Start()
}

function Invoke-Scan {
    param([switch]$Elevated)
    $text = if ($Elevated) { 'Scanning as administrator... Windows may ask for permission.' } else { 'Scanning...' }
    $script:ScanStarted = Get-Date
    try {
        Invoke-ScriptAsync -Script $Paths.Scanner -Arguments @('-Csv', '-Html', '-NoPause', '-ReportPath', $Paths.Report) `
            -BusyText $text -Elevated:$Elevated -OnDone {
                param($code)
                # An elevated scan may not report its exit code: then check the CSV is new.
                $fresh = (Test-Path -LiteralPath $Paths.Csv) -and
                         ((Get-Item -LiteralPath $Paths.Csv).LastWriteTime -ge $script:ScanStarted.AddSeconds(-2))
                if ($code -eq 0 -or ($null -eq $code -and $fresh)) { Import-ScanView }
                else {
                    $ui.StatusText.Text = 'The scan did not finish.'
                    Show-Message -Text "The scan did not finish (exit code $code).`n`n$(Get-OutputTail)" -Icon 'Warning' | Out-Null
                }
            }
    }
    catch {
        Show-BusyState -Busy $false -Text 'The scan was not started.'
        Show-Message -Text "The scan was not started: $($_.Exception.Message)" -Icon 'Warning' | Out-Null
    }
}

function Invoke-Remove {
    param([switch]$Preview)
    $total = Get-MarkedTotal -Rows @($script:Rows)
    if ($total.Count -eq 0) { return }
    if (-not $Preview) {
        $answer = Show-Message -Icon 'Question' -Buttons 'YesNo' -Text (
            "Move $($total.Count) folder$(if ($total.Count -ne 1) { 's' }) ($($total.SizeMB) MB) to the Recycle Bin?`n`n" +
            "Each folder is checked again first, and skipped if any check fails. " +
            "You can put them back with Restore last delete.")
        if ("$answer" -ne 'Yes') { return }
    }
    Export-MarkedCsv -Rows @($script:Rows) -Path $Paths.Marked | Out-Null
    $log = if ($Preview) { $Paths.PreviewLog } else { Join-Path $Paths.AppDir ("WinPkgScan-DeleteLog-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    Remove-Item -LiteralPath $Paths.PreviewLog -ErrorAction SilentlyContinue
    $arguments = @('-CsvPath', $Paths.Marked, '-LogPath', $log, '-NoPause')
    $arguments += if ($Preview) { '-WhatIf' } else { '-Force' }
    $script:LastLog = $log
    $script:LastWasPreview = [bool]$Preview
    Invoke-ScriptAsync -Script $Paths.Remover -Arguments $arguments `
        -BusyText $(if ($Preview) { 'Checking the marked folders...' } else { 'Moving the marked folders to the Recycle Bin...' }) `
        -OnDone {
            param($code)
            $summary = Get-LogSummary -Path $script:LastLog
            if (@($summary.Rows).Count -eq 0) {
                Show-Message -Text "Nothing was done (exit code $code).`n`n$(Get-OutputTail)" -Icon 'Warning' | Out-Null
                return
            }
            if ($script:LastWasPreview) {
                $ui.StatusText.Text = 'Preview finished. Nothing was changed.'
                Show-Message -Text ("Preview: nothing was changed.`n`n" + (Format-LogSummary -Summary $summary -Preview)) | Out-Null
            }
            else {
                Show-Message -Text (Format-LogSummary -Summary $summary) -Icon $(if ($summary.Failed -gt 0) { 'Warning' } else { 'Information' }) | Out-Null
                Invoke-Scan
            }
        }
}

function Invoke-Restore {
    $log = Get-NewestDeleteLog -Folder $Paths.AppDir
    $summary = if ($log) { Get-LogSummary -Path $log.FullName } else { $null }
    if (-not $summary -or $summary.Recycled -eq 0) {
        Show-Message -Text 'There is nothing to restore: the app has not moved any folders to the Recycle Bin yet.' | Out-Null
        return
    }
    $answer = Show-Message -Icon 'Question' -Buttons 'YesNo' -Text (
        "Put back the $($summary.Recycled) folder$(if ($summary.Recycled -ne 1) { 's' }) from the last delete ($($log.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))?`n`n" +
        "A folder is skipped if something already exists at its place, or if it is no longer in the Recycle Bin.")
    if ("$answer" -ne 'Yes') { return }
    Invoke-ScriptAsync -Script $Paths.Restorer -Arguments @('-LogPath', $log.FullName, '-NoPause') `
        -BusyText 'Restoring folders from the Recycle Bin...' -OnDone {
            param($code)
            $result = (Get-OutputTail) -split "`n" | Where-Object { $_ -match '^Restored:' } | Select-Object -Last 1
            $icon = if ($code -eq 0) { 'Information' } else { 'Warning' }
            Show-Message -Text $(if ($result) { $result.Trim() } else { "Restore finished with exit code $code.`n`n$(Get-OutputTail)" }) -Icon $icon | Out-Null
            Invoke-Scan
        }
}

# ------------------------------------------------------------
# Build the window
# ------------------------------------------------------------

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $Paths  = Get-AppPath
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    $ui = @{}
    foreach ($name in $ControlNames) { $ui[$name] = $window.FindName($name) }

    $script:Rows   = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $script:View   = $null
    $script:Job    = $null
    $script:IsBusy = $false
    $script:Timer  = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $window.Title = "WinPkgScan $AppVersion (preview)"

    $script:Timer.Add_Tick({
        $job = $script:Job
        if (-not $job) { $script:Timer.Stop(); return }
        $finished = $true
        try { $finished = $job.Process.HasExited } catch { $finished = $true }
        if (-not $finished) { return }
        $script:Timer.Stop()
        $code = $null
        try { $code = $job.Process.ExitCode } catch { $code = $null }
        $script:Job = $null
        Show-BusyState -Busy $false -Text 'Done.'
        try { & $job.OnDone $code }
        catch { Show-Message -Text "Something went wrong: $($_.Exception.Message)" -Icon 'Error' | Out-Null }
    })

    $ui.ScanButton.Add_Click({ Invoke-Scan })
    $ui.AdminScanButton.Add_Click({ Invoke-Scan -Elevated })
    $ui.PreviewButton.Add_Click({ Invoke-Remove -Preview })
    $ui.DeleteButton.Add_Click({ Invoke-Remove })
    $ui.RestoreButton.Add_Click({ Invoke-Restore })
    $ui.ReportButton.Add_Click({
        if (Test-Path -LiteralPath $Paths.Html) { Invoke-Item -LiteralPath $Paths.Html }
        else { Show-Message -Text 'There is no report yet. Click Scan first.' | Out-Null }
    })
    $ui.ViewBox.Add_SelectionChanged({ $ui.MarkAllBox.IsChecked = $false; Show-ResultView })
    $ui.FilterBox.Add_TextChanged({ Show-ResultView })
    $ui.MarkAllBox.Add_Click({
        $state = [bool]$ui.MarkAllBox.IsChecked
        if ($script:View) { foreach ($r in $script:View) { if ($r.CanMark) { $r.Marked = $state } } }
        Show-MarkedTotal
    })
    $ui.ResultsGrid.Add_MouseDoubleClick({
        $row = $ui.ResultsGrid.SelectedItem
        if ($row -and $row.FullPath -and (Test-Path -LiteralPath $row.FullPath)) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($row.FullPath)`""
        }
    })
    $window.Add_Closing({
        $closingArgs = $args[1]
        if ($script:IsBusy) {
            $answer = Show-Message -Icon 'Question' -Buttons 'YesNo' -Text 'A task is still running. Close the app anyway? The task keeps running in the background.'
            if ("$answer" -ne 'Yes') { $closingArgs.Cancel = $true }
        }
    })

    Import-ScanView

    if ($SelfTest) {
        # Check every part of the window loaded, and that the list accepts a row.
        $missing = @($ControlNames | Where-Object { -not $ui[$_] })
        $sample = New-Object WinPkgScanApp.Row
        $sample.FolderName = 'Sample.App_abc123def4567'; $sample.CanMark = $true; $sample.Category = 'Orphaned package'
        $sample.add_PropertyChanged({ Show-MarkedTotal })
        $script:Rows.Add($sample)
        $sample.Marked = $true
        Show-ResultView
        $marked = $ui.MarkedText.Text
        if ($missing.Count -gt 0) { Write-Host "SELFTEST FAILED: missing $($missing -join ', ')"; exit 1 }
        if ($marked -notmatch '^1 marked') { Write-Host "SELFTEST FAILED: marked text is '$marked'"; exit 1 }
        Write-Host "SELFTEST OK: window built, $($ControlNames.Count) controls found, marking works"
        exit 0
    }

    [void]$window.ShowDialog()
}
catch {
    $message = "WinPkgScan app could not start: $($_.Exception.Message)"
    if ($SelfTest) { Write-Host "SELFTEST FAILED: $message"; exit 1 }
    try { [System.Windows.MessageBox]::Show($message, 'WinPkgScan', 'OK', 'Error') | Out-Null }
    catch { Write-Host $message; Read-Host 'Press Enter to exit' | Out-Null }
    exit 1
}
