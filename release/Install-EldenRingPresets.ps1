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
    $payload = ConvertFrom-Json -InputObject '{"schema":1,"python_version":313,"raw_size":58272,"compressed_sha256":"63ad014fc708be12ae43296ea7364515301e566a787cd74dadabc6cf0399c2fd","original_sha256":"31a132aceee81a1e2b71fc4ba1d149e074844b36a7c9d029fd1f1d10813727f1","payload":"","source_sha256":{"app/model.py":"16ed28bce85ae9f3671bb01b0d84d52a41fc12484fc532961e06ae548fd9ee4f","app/windows.py":"4383714904a8f1b7faf8ac5aeb97998b645521dae81e2857da6417595426c108","app/controller.py":"a41017d293c5ae4a9c860e80b58d690f09b5b25b0181add420faa6aa7db7ed3c","app/main.py":"cb4ff397f04d147a3ac5e18ea79987dd1949e78b8ffe542edb7a4a74a81a2aef","tools/diagnose_1171.py":"4a7ce2f0cd310930c0ba12e98d8f17bb86169b9ddb3405cb4a15d75397f3aae3"}}'
    $payload.payload = @(
        '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'
        'HR0fqR66B5r6465XD7508McT725Tzmx59x7lzOqFT35w7yffv3fHb+7dcfmP37tXPXP7B5/b8aPcC7krU+99Lnt1x7uf6ztz+99v+8MP/jBx5vazH/ngs4kz'
        't333rm/fdW7k3W2f+R/btn/7yLknL3zp8tH37k5fvf3nH3njI/992xf+8a6OB/p+t71j6zbCu/PdLX/0/hbl3S3Kf9uS+OcP7vjoP3V0brrng+2feH+78pvt'
        'ynvbE6dGf7d529Z7/mHbvR/c++nnP/u9z16Y/9FXXvjKj0ovlK78u18M//Ud/2X732x//wuPv/uFx9/7wtR7+6bfu++J9+598tdfXn733mXAeNs9393+7e0X'
        'pq/0ndn+7rbMB3d+5Ncfe+DdOx94f1v23W3Zqw/89ad+jb/G/ue2Bz/Y9rH3t332N9s+++vPZX/d+8X/OvXrx4/8+k9X3n185b2DpXd7S3+/rfy/t939z2e2'
        '/svvPgFY/ovzIAzd39yz/77h7o6/7f7UgQdu+89b93/mwOc3/919m+Dh7z6/+cCOrX+3Ywv8/v/yK/nR'
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
