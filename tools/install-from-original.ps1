param(
    [string]$OriginalExe,
    [string]$PayloadFile,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
if (-not ('ERPPackageBuilder' -as [type])) {
    Add-Type @'
using System;
using System.IO;
using System.Text;
public static class ERPPackageBuilder {
    static uint Read(byte[] b, int p) {
        if (p < 0 || p > b.Length-4) throw new InvalidDataException("Invalid offset");
        return ((uint)b[p]<<24)|((uint)b[p+1]<<16)|((uint)b[p+2]<<8)|b[p+3];
    }
    static void Put(byte[] b, int p, uint v) {
        b[p]=(byte)(v>>24); b[p+1]=(byte)(v>>16); b[p+2]=(byte)(v>>8); b[p+3]=(byte)v;
    }
    public static byte[] Build(byte[] original, byte[] compressedMain, uint rawSize) {
        byte[] magic={77,69,73,12,11,10,11,14};
        int cookie=original.Length-88;
        if (cookie<0) throw new InvalidDataException("Missing archive");
        for(int i=0;i<8;i++) if(original[cookie+i]!=magic[i]) throw new InvalidDataException("Unexpected archive footer");
        if(Read(original,cookie+20)!=313) throw new InvalidDataException("Python 3.13 runtime required");
        uint total=Read(original,cookie+8), tocAt=Read(original,cookie+12), tocSize=Read(original,cookie+16);
        long archiveLong=(long)original.Length-total;
        if(archiveLong<0 || tocAt+(long)tocSize+88!=total) throw new InvalidDataException("Invalid archive bounds");
        int archive=(int)archiveLong;
        var directory=new MemoryStream(); var contents=new MemoryStream(); int changed=0;
        for(int pos=0;pos<(int)tocSize;) {
            int at=checked(archive+(int)tocAt+pos); int length=checked((int)Read(original,at));
            if(length<18 || pos+length>(int)tocSize) throw new InvalidDataException("Invalid directory entry");
            uint offset=Read(original,at+4), size=Read(original,at+8);
            if(offset+(long)size>tocAt) throw new InvalidDataException("Invalid payload bounds");
            string name=Encoding.UTF8.GetString(original,at+18,length-18).TrimEnd((char)0);
            byte[] entry=new byte[length]; Buffer.BlockCopy(original,at,entry,0,length);
            Put(entry,4,checked((uint)contents.Length));
            if(name=="main" && original[at+17]==(byte)'s') {
                contents.Write(compressedMain,0,compressedMain.Length);
                Put(entry,8,(uint)compressedMain.Length); Put(entry,12,rawSize); entry[16]=1; changed++;
            } else {
                contents.Write(original,checked(archive+(int)offset),checked((int)size));
            }
            directory.Write(entry,0,entry.Length); pos+=length;
        }
        if(changed!=1) throw new InvalidDataException("Expected one main entry");
        byte[] footer=new byte[88]; Buffer.BlockCopy(original,cookie,footer,0,88);
        Put(footer,8,checked((uint)(contents.Length+directory.Length+88)));
        Put(footer,12,checked((uint)contents.Length)); Put(footer,16,checked((uint)directory.Length));
        var result=new MemoryStream(); result.Write(original,0,archive);
        contents.Position=0; contents.CopyTo(result); directory.Position=0; directory.CopyTo(result);
        result.Write(footer,0,88); return result.ToArray();
    }
}
'@
}
if ($ValidateOnly) {
    Write-Host 'Windows package-builder C# compiled successfully.'
    return
}
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
if (-not $OriginalExe) {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select your original Loadout Manager.exe (1.3.5)'
    $dialog.Filter = 'Loadout Manager|*.exe'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $OriginalExe = $dialog.FileName
}
if (-not $PayloadFile) {
    $PayloadFile = Join-Path $PSScriptRoot '..\release\app-payload.json'
}
$payload = Get-Content -LiteralPath $PayloadFile -Raw | ConvertFrom-Json
if ($payload.schema -ne 1 -or $payload.python_version -ne 313) { throw 'Unsupported app payload.' }
$original = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $OriginalExe).Path)
$sha = [Security.Cryptography.SHA256]::Create()
$originalHash = ([BitConverter]::ToString($sha.ComputeHash($original))).Replace('-','').ToLowerInvariant()
if ($originalHash -ne $payload.original_sha256) {
    throw 'Original EXE does not match the supplied Loadout Manager 1.3.5 runtime. It was not modified.'
}
$code = [Convert]::FromBase64String($payload.payload)
$codeHash = ([BitConverter]::ToString($sha.ComputeHash($code))).Replace('-','').ToLowerInvariant()
if ($codeHash -ne $payload.compressed_sha256) { throw 'App payload checksum mismatch.' }
$sha.Dispose()
$result = [ERPPackageBuilder]::Build($original,$code,[uint32]$payload.raw_size)
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not [IO.Directory]::Exists($desktop)) { $desktop = $env:USERPROFILE }
$directory = Join-Path $desktop 'EldenRingPresets-Test'
[void][IO.Directory]::CreateDirectory($directory)
$output = Join-Path $directory 'EldenRingPresets-Test.exe'
$number = 2
while ([IO.File]::Exists($output)) {
    $output = Join-Path $directory "EldenRingPresets-Test-$number.exe"
    $number++
}
$stream = [IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
try { $stream.Write($result,0,$result.Length) } finally { $stream.Dispose() }
Write-Host "Created test application: $output" -ForegroundColor Green
Write-Host 'Original EXE unchanged. Close Loadout Manager before using this app.'
Start-Process explorer.exe -ArgumentList ('/select,"' + $output + '"')
