& {
    $ErrorActionPreference = 'Stop'
    $handle = [IntPtr]::Zero
    $folder = [Environment]::GetFolderPath('Desktop')
    if (-not [IO.Directory]::Exists($folder)) { $folder = $env:USERPROFILE }
    $output = Join-Path $folder 'eldenring-report-v3.json'
    $report = [ordered]@{ diagnostic_version=3; status='failed'; mode='read-only'; write_support_verified=$false }
    try {
        if (-not [Environment]::Is64BitProcess) { throw '64-bit PowerShell required.' }
        if (-not ('ERPReaderV3' -as [type])) {
            Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ERPReaderV3 {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, UIntPtr n, out UIntPtr read);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);
}
'@
        }
        $previous = Get-Content -LiteralPath (Join-Path $folder 'eldenring-report-v2.json') -Raw | ConvertFrom-Json
        if ($previous.signature_matches -ne 1 -or $previous.game_data_rva -notmatch '^0x[0-9A-Fa-f]+$') {
            throw 'The previous unique-signature report is required.'
        }
        $games = @(Get-Process -Name eldenring -ErrorAction SilentlyContinue)
        if ($games.Count -ne 1) { throw 'Load one Elden Ring character first.' }
        $module = $games[0].MainModule
        if ($module.FileVersionInfo.FileVersion -ne $previous.exe_file_version) {
            throw 'The executable version changed. Repeat the signature scan.'
        }
        $rva = [Convert]::ToInt64($previous.game_data_rva.Substring(2), 16)
        if ($rva -lt 0 -or ($rva + 8) -gt $module.ModuleMemorySize) { throw 'RVA outside image.' }
        $report.exe_file_version = $module.FileVersionInfo.FileVersion
        $report.game_data_rva = $previous.game_data_rva
        $handle = [ERPReaderV3]::OpenProcess(0x410, $false, [uint32]$games[0].Id)
        if ($handle -eq [IntPtr]::Zero) { throw 'OpenProcess failed. Check matching execution privileges.' }
        function Read-BytesV3([long]$address, [int]$count) {
            $buffer = New-Object byte[] $count
            $actual = [UIntPtr]::Zero
            $size = [UIntPtr]::new([uint64]$count)
            $ok = [ERPReaderV3]::ReadProcessMemory($handle, [IntPtr]::new($address), $buffer, $size, [ref]$actual)
            if (-not $ok -or $actual.ToUInt64() -ne $count) {
                throw "ReadProcessMemory failed. Win32 error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            return ,$buffer
        }
        function Read-IntV3([long]$a) { return [BitConverter]::ToUInt32((Read-BytesV3 $a 4), 0) }
        function Read-PtrV3([long]$a) {
            $v = [BitConverter]::ToUInt64((Read-BytesV3 $a 8), 0)
            if ($v -lt 65536 -or $v -ge 140737488355328) { throw 'Invalid player pointer. Load a character first.' }
            return [long]$v
        }
        $globalAddress = $module.BaseAddress.ToInt64() + $rva
        $manager = Read-PtrV3 $globalAddress
        $player = Read-PtrV3 ($manager + 8)
        $offsets = [ordered]@{ VIGOR=0x3C; MIND=0x40; ENDURANCE=0x44; STRENGTH=0x48; DEXTERITY=0x4C; INTELLIGENCE=0x50; FAITH=0x54; ARCANE=0x58; LEVEL=0x68 }
        $stats = [ordered]@{}
        foreach ($key in $offsets.Keys) { $stats[$key] = Read-IntV3 ($player + $offsets[$key]) }
        $report.stats = $stats
        foreach ($key in $stats.Keys) {
            $max = if ($key -eq 'LEVEL') { 713 } else { 99 }
            if ($stats[$key] -lt 1 -or $stats[$key] -gt $max) { throw "Stat range check failed: $key = $($stats[$key])" }
        }
        $offsets = [ordered]@{ Weapon_L1=0x398; Weapon_R1=0x39C; Weapon_L2=0x3A0; Weapon_R2=0x3A4; Weapon_L3=0x3A8; Weapon_R3=0x3AC; Head=0x3C8; Armor=0x3CC; Gauntlets=0x3D0; Legs=0x3D4; Talisman_1=0x3DC; Talisman_2=0x3E0; Talisman_3=0x3E4; Talisman_4=0x3E8 }
        $gear = [ordered]@{}
        foreach ($key in $offsets.Keys) { $gear[$key] = Read-IntV3 ($player + $offsets[$key]) }
        $report.gear = $gear
        $magicPointer = Read-PtrV3 ($player + 0x530)
        $report.magic = @(for ($i=0; $i -lt 12; $i++) { Read-IntV3 ($magicPointer + 0x10 + 8*$i) })
        if ((Read-PtrV3 $globalAddress) -ne $manager -or (Read-PtrV3 ($manager + 8)) -ne $player) { throw 'Character changed during capture. Retry.' }
        $report.status = 'read_only_snapshot'
    } catch { $report.error = $_.Exception.Message; Write-Host $report.error -ForegroundColor Yellow }
    finally { if ($handle -ne [IntPtr]::Zero) { [void][ERPReaderV3]::CloseHandle($handle) } }
    try {
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $output -Encoding UTF8
        Write-Host "Report saved: $output" -ForegroundColor Green
    } catch { $report | ConvertTo-Json -Depth 6 }
}
