& {
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
if ($PayloadFile) {
    $payload = Get-Content -LiteralPath $PayloadFile -Raw | ConvertFrom-Json
} else {
    $payload = ConvertFrom-Json -InputObject '{"schema":1,"python_version":313,"raw_size":58240,"compressed_sha256":"a8967b08c9e7303a85b901c08f1c5c88ce4261b9df995d73fbe639473888a335","original_sha256":"31a132aceee81a1e2b71fc4ba1d149e074844b36a7c9d029fd1f1d10813727f1","payload":"","source_sha256":{"app/model.py":"16ed28bce85ae9f3671bb01b0d84d52a41fc12484fc532961e06ae548fd9ee4f","app/windows.py":"4383714904a8f1b7faf8ac5aeb97998b645521dae81e2857da6417595426c108","app/controller.py":"00dfb3747054919a29f969b4b881adb56e8d888a2c39c2dc8a6e9f4dc5030b6f","app/main.py":"cb4ff397f04d147a3ac5e18ea79987dd1949e78b8ffe542edb7a4a74a81a2aef","tools/diagnose_1171.py":"4a7ce2f0cd310930c0ba12e98d8f17bb86169b9ddb3405cb4a15d75397f3aae3"}}'
    $payload.payload = @(
        'eNrtfW1wHMd1IEiREgVRsmXHX4ktD1eRZlZYLHfxQYIgR2cQACVYIEEBkGgFwG0NdgfAGIvd9cwuCZDhFW3TOlqiy5QtWlRMytRFsiifXKEkyqYTuSpxrnJ1'
        '/ywrd9IxdXVX/nfcRZVT+ZNK3VXde6+7Z3q+dhe06n6Ftsidme7Xr1+/fv3e69ev8x3Sn07+7z8dvq2j43zHVMfUpsc6bPbvJnsT/bvZ3kz/3mbfRv9usbdM'
        'bf5kx6M9HR321tnNk9s7Qn8SHbNb+zex3/YdOztm7yhuE99mt8LTne7THbObJv8gDGF2qwp/H+zr6LirQ+m4r2PqtqktU1unbp+6Y2pbeqvdOds5+ZlwrX7+'
        'L2BndnTUNkPr2+nvu+17YjHd7mE6u33yi+EyU3eKElMdWwlnCf+74enjLXuzHXszey+09gn4757Zu6c6+28TdSYfjOjJZvav0nFwkdEgGvLUXYjRZDKeFkrH'
        '4qYdHbOfuqPDeAufZm+bTEXRQZS3P3MfG//P2p+d3TLZE0mzz072hd9P7o7Ab/vs56F8JJzJvfFYC4oLOrgjcHf3XYDjfbP3Tf6biNbugf99bM9m6OV9Ux/H'
        'kpNDEaPxmal7pz6BpaCfn3xsx5cTdgJqJCYPRPV16g+mPkV94BAFJt2+UTI7dsB/+m1f7FjYtMD/TX76f+PHQ8nNN24zKpUbW6vlctFJbj6+HZ52rpQLZjFd'
        'Wav9HxjWBbu8ouRyC7VqzTZzOcVaqZTtqmKUSuWqUbXKJaeTihSMqpEvGo5jOqKM+6qTv1gynKWiNS8ev+qUS+J3mYOpGFUsIkAchsfOztGDh6efUnQls3qA'
        '/+mcGp+YnoJXM1ompaiNF99tPH1OyarJlKJl8cWFV+qvXvfe9XiFeuhFr68QvutUxB+tzyvdS6X7faXZuyzCrF+5Xv/xG+wZQdZ/cn396Xf80LIIbv3s86wU'
        'gqo/+4pbazd+/OYZeG4880r9tbOiEwPB9wEcs3uCBRhaPZng+z41Odc5NT00nZs4cGBqlMhWsPJV7cmxRyYm9cxq73BKOTh2aAR+9kHt0UMjT0wOHRoexWfA'
        'fWp6cvTQI9OP4uOAhIL0Z2T0K9Ojk2PTT2EZgDZ2aHp0fHzskVEGpR+gHhgaIxD9AHFocnjoEH2AXo6PPjk6Dr93DSQ7O7/k8owG7HDcLOnTds1MdtIrZaxq'
        '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'
        '3PXawZcP/njivW3KmS3v3aOcWb3w6Q/v/fQH9+74zb07Lv/x+/eqZ27/8As7fpR7MXdl6v0vZK/ueO8LfWdu//ttf/jhHybO3H72Yx9+PnHmtu/e9e27zo28'
        't+1z/33b9m8fOffkha9cPvr+3emrt//8Y29+7L9t+9I/3tXxQN/vtnds3UZ4d7635Y8+2KK8t0X5r1sS//zhHR//p47OTfd8uP1TH2xXfrNdeX974tTo7zZv'
        '23rPP2y798N7P/vC57/3+QvzP/rqi1/9UenF0pV/+4vhv77jP2//m+0ffOnx9770+Ptfmnp/3/T79z3x/r1P/vqp5ffuXQaMt93z3e3f3n5h+krfme3vbct8'
        'eOfHfv2JB96784EPtmXf25a9+sBff+bX+Gvsf2x78MNtn/hg2+d/s+3zv/5C9te9X/4vU79+/Miv/2TlvcdX3j9Yeq+39Pfbyv9r293/fGbrv/zuU4DlvzgP'
        'wtD9zT377xvu7vjb7s8ceOC2/7R1/+cOfHHz3923CR7+7oubD+zY+nc7tsDv/wdSre4r'
    ) -join ''
}
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

}
