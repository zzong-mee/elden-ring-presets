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
    $payload = ConvertFrom-Json -InputObject '{"schema":1,"python_version":313,"raw_size":50748,"compressed_sha256":"15e898043dfab23a7aed00484c7566f77da649f54ad88a473c41477c49ea1aae","original_sha256":"31a132aceee81a1e2b71fc4ba1d149e074844b36a7c9d029fd1f1d10813727f1","payload":"","source_sha256":{"app/model.py":"16ed28bce85ae9f3671bb01b0d84d52a41fc12484fc532961e06ae548fd9ee4f","app/windows.py":"4383714904a8f1b7faf8ac5aeb97998b645521dae81e2857da6417595426c108","app/main.py":"a97f34d57685fac241f01763838221a8f9b4f67fdb541403bad4dfa8ae9ffbdb","tools/diagnose_1171.py":"4a7ce2f0cd310930c0ba12e98d8f17bb86169b9ddb3405cb4a15d75397f3aae3"}}'
    $payload.payload = @(
        'eNrtfW1wG8eVICVLlkzLdpxsPnY3dkZw7JkxIQggQYmiNL5QFGUz1pdJ2kqW5KGGwJBECALIDECRVnSlOEpOsZWykli2vCs58q1syzlvrSzLjrLrVO3mrvbq'
        'fp0d75193Lq6q/t3AliVrf2ztXVXde+97p7p+QJBxbW/Vi4TwEz369evX79+7/Xr1/kO6V8n//yHQ7d1dJzrGO0YXfd4h80+19nr6HO9vZ4+b7Nvo88N9obR'
        '9Z/reKy7o8PeOLF+ZEtH6F+iY2Jj7zr23d60vWNiU2mzeDexEX7d4f7aNLFu5PfCECY2qvD3YLaj484OpeP+jtHbRjeMbhy9fXRTaoPdOdE58sVwnV7+CbhZ'
        'HR319dD2Fvp7l313LJ5bPDwntox8JVxmdLMoMdqxkTCWsL8Lfn1m1b5swb5M3AutfRb+v3virtE7em8TdUYeiujJevapdBycYRSIhjzaiRiN6PG0UDpm1m3t'
        'mPj8pg7zGv6auG0kGUUHUd7+4v1s9L9kf2liw0h3JM2+NJINPx/ZGYHfnRNfhvKRcEZ2x2MtKC7o4I7Alm13Ao73T9w/8q8iWrsL/rt713ro5f2j92DJkYGI'
        '0fji6GdG78VS0M/PPr716wk7ATUSI/uj+jr6udHfoz5wiAKTbb5Rsjq2wv/GbV/pmF43zT/1z/8ffHlIX798m1mtLm+sVSolR1//9Bb4tX2+UrBKqepS/f/C'
        'sE7blXkll5uu1+q2lcspxflqxa4pZrlcqZm1YqXsdFKRglkz8yXTcSxHlHEfdfIHs6YzWypOiZ/fcipl8b3CwVTNGhYRII7Az87OoYNHxr6pGEp6cT//1zl6'
        '4PDYKDwa19JJRW2+/H7zB2eVjKonFS2DD85fbrx2w3vW7RXqpgc9vkL4rFMR/7SsV7qHSvf6SrNnGYTZuHKj8fpb7DeCbPz8xsoP3vVDyyC4lTMvsFIIqvHc'
        'ZbfWTnz5vdPwu/ns5cYbZ0Qn+oLPAzhmdgULMLS608HnWVWf7BwdGxjLHd6/f3SIyFYo5mvaU8OPHh4x0os9g0nl4PChffA1C7WHDu17cmTg0OAQ/gbcR8dG'
        'hg49OvYY/uyTUJD+7Rv6xtjQyPDYN7EMQBs+NDZ04MDwo0MMSi9A3T8wTCB6AeLAyODAIXoBvTww9NTQAfi+o0/v7PyayzMasMPTVtkYs+uW3kmPlOGaNd9P'
        'CBTLBWuxHz5q9HPWLBdKlve7CAVzxYL34Nt1s1wr1pbYk1WaGfp2vVitWgXWlFOq1FpADjXtYdbZWbCmldoSgIIqGgJKCgA678e0eKAYhkJ83u9S2LZgzpXZ'
        'U3qYN2vWTMVewqmAVRGissdQehWr5FhKBp9luvGJeJPhr7o7JYCixe8omgtxzx6lGweAUC6WF6xyDR7npoqmo1lIj3l4kvTecPynlnKMAIDS8cWUIMaiMl2x'
        '4W+x7NVA5BZTYiCUR5T0CQIBsqZmOlDfsWqaTo+wssUHAWG4CHi0AWCiRCqegkS0CjRYrlteVSgOzbmop2agYRcYe6bLDVGFoqMcqpQtBVDD326jWw1vhF0g'
        'bKiDCOp+xGyzCCPzlFmqW0O2XbE1deX8qeYrbynNV15r/PJU8+WTSvMHZ5pvnFz5yenmxfNK86WrN69dbV48pdy8drL5+sWVc+fhpdL4+V+uvHi6+ey7jedO'
        'g2BJqR7ujLQpsyChRvypbOOdwB+64MSSVdZYFR27lZE4MYRqHI4XbzR+9DYIHhfb6/Ds/eYvz3Nsm+eeDaG6gHBRKDF0q5Wq5uIEqwzwOnAyK7QHF4FMGv+1'
        'xE7gJCHUuPZC88Kpm1cBh1fOA9EaZ883XwrTjc8Rao5Ph2rJLOdcHtQcc8EqhKeCbTn1Ug2XpEn6XXeAeYNczRgjh0xNK1i/NFZO0WY1EP64U7NJYuiTPsYF'
        'Nkoq7pTjlcZV/kqdTHrPWCl1MsjK8VOFdSEFOoBVLmhcYCHX63rrKfWA8mTZtOcBfazjACfNFGvFeRAupSXFmTVtS6nNWsqMOW+pjjJVL5Zq24AE00WnxhjR'
        'hVTncAxJuEE/ZMQzNP5ujTy8LoI8t1CGjLcneRBk5EKmQEGpqRjZ3aK6JjqAWHBhQkwMCCFHSMPpIZ5yQNfR5qwlo2TOTxVMBRYQza0NU5F9SyJyNGN94gmh'
        'e7D8I1oGiovlnhhOH8euTLYWRNPqcax4ovnSWWXl3KnmH7+wcu4CF0s0gdwpDwWaL/3Am0TKzXfPNq9db7z2vtJ87kLzlR9L0x6+RQmp/GzFscqApNeH8bSH'
        'IBKNJBgrF5LPkTzLyuq+Gc0K8ikN05uaylXhMcxQ1Ae8JRl/0aqgOvlZa95UmTzEMaWhdIplp2aW85bmlcwDl5v5mmWjFgaTVxelsci49HqypeB642TzT856'
        'RGs8+4Ky8sIpVOa+/5yycuYMCtNXvu+nImoCvA8MlxnLtNWkcvyETogfJ1miMwEkS58TrVDxmmUDrzSffavx6p/DCL/VPPU2CfZWcpTW8HINZ1+Z04DQmkyR'
        'aHU0aTXEssD9WFJzRRmosVyCBdbNItOpNIJOHYa60FNYodlEqwnS08JBxcahyCT+ipB6bXb/5tWfrNpp4IoaiiGJgfAJGwt5rOgxDQ7+kpVzvb0xaTz7WuPS'
        'a7CurmU8gAhJvpACqQkHkna+wRDkpXJRVM34lmNtZ6YH6+D4gcRUSZ1Xmda5a9fqKk9Ej9pcqZ2qVSr5qT1vzhTzqk95kCYrq5BUSrDs0PREhYc9ZBO8Gx+a'
        '5SWNCLAYy1KLLid5qw2H0+bovXG6ce1cu0PHBRh2E8QXs1FGYWGz+rkCPQ0GerFcrOVymmOVppOKXQHFwUMFH6bwGRALLWqN3ne6tdHo5jVdOZVUqnZluoir'
        'Trk+P2XZfhZhz8TKZpvlGQsN7961DPi10yvnb6CEy/ybbEioUTsFiy3ZhnAdpECZ6O7doWkunkqXok6kVfjg+Oopq5yvFCxNrdemt/Wpup6atRYLxRnLEZqY'
        'RFSPNNu95rYr0ypbGLYdZx09kUJnheqRDJW0VUmWVKR1hWu64WVHJmtosUC+dH+uRtvmX5xtvP5nK6eu0txZTe3GfzjypKQCFYgLWoy/rxKUtoFaqfm5QtHW'
        '2A+HrGiwexZhguUqc9yoFtVA0FQrtknmK4E4VqzN5pz69HRxUVNTtfmqhBi+82qkKrC6a+oxEKQ0uMXyjCGGVwHjERY4y5z3kwcHLFWoz1eJykleBgE46Mky'
        'nXyxaOw3QU4lyWgv14xuv5rLaqSmS3VnVvO/qjipaWepnNdEGSBUuaJJihmUsC2wHEDuuN1IUr+liVeqmIW1TLxbGi4uCInkNDQ+cR/NSY0r7zcvnQTl73rj'
        'uV96Gggan/AcVkR4ozT/9P3mqRugHfpsTiC2YoQ4nUYDu+tohAhQrZCrWYtgeQcHVP8UZwR62l67obgTA21UrzdRMkcWtvr6p79AntHthaI5UwadMpfJ7Myk'
        'qkvm/+vq6Hhg6/a6Y2+fKpa3W+UFpbpUm62UezoTicQI9G5bpQzGTyaV2ZnKKLx+rZh3UsohawHk1jG7iDZLreKaRrjGQM9AlDpKZXoayOakAFhnGy5Y8cie'
        'ganoWOJ3HhcyB2fI4O/og+XfbRc0MH49X3N/LTmdnaOHnxwZHMoNHj54cHgMeCCxc1f3ju50b77X7LYK3T07CoWeTPfOvnx2urd35678rh3ZvGXle3oTnQ8o'
        'Y48OKKm8ZSqPAiX2AfUPmmVl4PBesv4es+yK8o2DB5SSuVSpg4pl1hRfa6nOIwNjY0Mjh6BZ20rlK/NVmAuaPZWYWMz2TSz2TU0spntT8I//7p1YzKcnFndm'
        '8blXJgvPeuF7vgf/TyQR2L7DYwMHDuidjw4NjKCbK3HUMquVcu5AJtGvpBd7dvUlFfFsRDwb9J4d6GbPBtKe89QtL95lpfI9/JkMVzwblGA8BlzGHg9i0QF7'
        'vmLz39j8o2a9XCsBE7Fn+9Lw7IA1I35mJUhjMFudebOc4+jvw/ruQ47jUDqqBkdsKCvXyPKHfSfI8TxKZCN3M8cPCqPHmX6hzznhOp3ZI4Qm/M7siex5Trj+'
        'ZvYOwckuZ3qKTucEeZ3ZTwTJHM/stw8gaa30fAfgzGxEBwzSXJXZeLqy7RFUA5m8oRlOYgKnLiiYM0DmSnlbtQJFYGqPPDWg0ExCh2G9XPw2qMopFHbKyPCR'
        'bbZVglm7YJH0pwkui7r+bpJwU4mDf5QQOirDYI+yI9tCvUwcAiFvKkeGYP218vWaOVWyEkyuVdEHwCZsql6umvm5HKKnJfYMJ5iOkqRR0YXhDchAnS6lO6s8'
        'ImEA6BCOVau/anVlOaJHhibSE+lEK9SGy7QeIHKzwLSWzRGbN/OzxTKsWfkK8Gocko895mJJWGVZ5UoVZZ9ZyjnFp2M7GKjanZb7yJvHbqQX+3bsyPpMHIYT'
        'fNm1A5/7m1ttMIYWqxYsUAVlEaAeGUr4UUYNiNFXoOK+6Qo0FKD/Kp0UdbGXrFvd6b3tjUxPt9e0f5SKYFZZLak8HEIA+tG7w6W1A7TAdcrzjqLdVPRMB6K1'
        'bLHUTBv5IZYsXVD7YSWbllUFVgn4Iy1TbRUVIQFKahm3QQoCS3/nZS8a8j410k9/u/omUzbQo1jVYJ1JSxUWinatzlGFNWQBCGObx/hPtrTHkhL+udQUPerz'
        'qUQcQJcL83fqroS2GCbXm4YdT7bTG66zzRZrgTFmEHK8mo8AaDTzBv2mJVKbJAvJzMQq2znYCrSL4LgOANp4uQDKlc01f9Ze0qMbohEgVKHokLKOHv64oSm6'
        '4wLtpWhsNB3A9eiyw5JMHVDEaIih11BALr7NQ2Mn/C+3G/JyMSh7lDTOfP4LmAGG25uSbfiyEqPFmbKJyqNCKxRol6BDgbXLwCT0YMMoAtENsoDSj7eLapiE'
        'ArqA4Mu8uagtODC6jh7jEKfxgfHHUgtYkDsgxdDra+sAR0F0QEAJ9AH5UDAxq+Hb5MLXq25xTXsyHJdxWS11BDpJ6F0dCHPchXoi4fPZ4DNkDqZR5CulEkDM'
        'OWWz6sxWahpaQUllvlKol6zclOmw6aV7fp1qzdbMQgFsKMfvRqiHZDEw6BOksIJJyaskQXD4eFNsqLEtNMmPh+tf2vu3mhBBYihC26mXzQWzWEJ9YzfpNKCF'
        'eO6Z6SKIyETIvmL7a0wHKAMT2rgkQmclWqCAW+DuEZgjS14ZXsOVi8LtSrsW/SGyDAuycChdrkTI6qGpK0ktT06REitcpSdk9yJpCtT+OFciyc2MTlGuS5il'
        'kiaVmqP3u3Yxh6wLnFyoyJIcSitHYuII6weZ2tNAemBRWkaB7FZ+TkwGdLd/SkSJogmaQ36SkPeVj5ELFTTtnnTAYTseiwwD0UUcytf4PoFRUGfIdPPNtAeU'
        'AYnhavDWKdJCXiwLN4SjgM2NDwrFhWIBFjPcl6zn8zBJpuslattJuapvJB/i4AjOA0SCjIivWadbjdygiyYz9AtKoW6D/aDkzSoKlN04P+wlvxA5niDWSfQz'
        'FgI7BocWfuIH/CKi4Vvm3/aNXIJolWOMkatifBbajOSo8xcEXrXgDfkuzKliCR2hKPShU3WnCJObzVlHKVSIrxcsuzi9xIIcQDmzbOaKQNrsOzCooAkOTxig'
        'VEIYVcdgCCrHHE8EertuFScllv5EuUbGz2AKl7jKtDaYyucWKsVCrkqE7gvSeATUx+K8oPKT8GRHdtsUaAVHyCkDElw5ylrmpCXzjLtHuA8DUHPdJUep0Jxl'
        'ly1U1gdTUHvfgQNagj3q6QaGrTtWrmQ6tZyFrUrOTuahPzJyeHBodHTo0NjIN3u6oQejxPQwyNLczk0XrVLByVEkWwI7C4CPpvYdPTyyD6O5EnUHV2j/s2qx'
        'ID+JXHi1BGixVSiGlEO4uRrVZXwdAFibpQnQBlDm6A3iYxcrNowyPT5w+NCj9HS6ZM60AxLHnIodHXxsYAQmfPeONJ/YjJAHD+978sDQ70hHP8naJuJMqTIF'
        'mm/kKNgVFB/hdzGgUJTw8eCcjFBAcZipzQZAs31PevgY6/0aqAdmF6FncrBhsjIeTg3CoNessUqlNGuVqj3do3xKpkBhYhMBiMnRcvFrDwIoHwgBAEAPBg7t'
        'OzDkq1aqONZjLPbK3xYrOxlXWAa79/DhA3K5I2w4err3o8JxNBIwUv/IYfQUjWj+6emnjAvrENgfPlCrNNYKIQ/56FZade4gzdq2++abMf6uBSC1avQwqM8c'
        'xziWwCrRrCFXbs0NuN7wkget+Yq9FNs9MXHC35mAk0kgib3J1q1FkoBrDiT6RVPatoye8vRWsYJ5Axo3HTD6OO1t/7v1DNFMcDWj5YatZYO4sS0tM2KLidkd'
        'rqmNoU2wxpuIDe1p0VPQJDzQLBjDCK5L+m72JsX9O+6SS0+l/ay5WPbXRJdwAKaWbEtUlrbzZkFLBRiR0UmsffyRKlWOgdkeNkipIOgFIOStMipMKWvRSoRN'
        'RyKLsPwYXBD0kfCYRe7gRqOWsExnyaVhIsImlQmMK71/N3AublavQprpYhlVUa+5sNBzIfgsWOpntAnrU4UCRqxdL5dR2/SR0WfEMsDCil0Dj4PG3schga7+'
        'KXO7j5GZCgMo+RUDYGT2JsTJ7HFoQzRSIkYMGK8e6VlrA3fha2a4yVxOmm4rjo7UbcuWGNF5E2whrtBJbaFPRwR68FbZtrMoQUaNITDCX7fIjGACOGhnGQru'
        'POf4T40wYCVoG59+sy38hD2VoB376f7gjvE07QnzuY9+M8O/A8N8IhTGEY4HoRKhOI8CKO+0kesF6nucLK1QwLzZDJ5RYNEALhOjafnEk0Mj38wNH9p/eOTg'
        'wNjw4UPKd5SnDuZGhgb2KbjDKzsDePj72vkbLSO/4ybgopyqT0+T/wOWI5qBOfQ7l2dy7IVGxb2QSr6b4i2CWhz3h9ZDTcSauqiwJoTzVswK5rGnPQn6ylZG'
        'imgLeSWj+DjUsPBkAEBm91roSAKDo1Y0mYUe9iIx1FK2eSwsJh5QhijSQynhXpvrsiObdmT4iPAkzpu1/Czt43H2RZu86MxxrvUHpKzCyTSLUo5lzWm0nbY7'
        'YueNezs4t0f5WhgA2h/qAxBIM1iq5qveHMl6hMDO5WJbodLch8G2XbMhh6BcRkDrYl4XOtwgml99SPcB2bYTtb0dSL6Z4gBNcagSoUCRGJ+o5wwNjjnzhtTR'
        'HZKgKBKchW516HQCWs/JAglK8m9hKyrB2CAHKoNUPMHCNhCY9CKHYUKoWcASDk2SA6RI7hQmOMLAERMmoaAQE03ovYE1IIfdz0H/4AWILQ17GgHAVTtywtyk'
        'eBowwfs9lSSpPPww7UuE61OQSc6pV9HDEcYYuj9j5vKV+fkiQvSFVJxoe1EQIdnMw+NbCmjh6W/f42JWiz53ixiSFt4WqJJ61Krth2afYqWHy9OVURBCQUPp'
        'wJHBo6NjI7KZIKzuyVVByWYC1WlRI7bhoDUtWzKTLQFGWilYGEo9UbfsJfIy+huWraTI3vt8ETJRnoQvEk0CbUTiUqjPzy951EF1jOthLaiK4XOMR7yFhQDp'
        'vhhe/4rS9qra/qIp9ryiiS9jmRbrIIOh3wJaYt/EZ1sCuZgriEiI9NdCqPmHQRPrcmJiIuGRj0OXCMrg6iLiGb6nxK5Pb3drR+rBouOQveDJczEjpaNbTsTq'
        'k+kZJqQ4xc2aQCwJjXqjy+q7wQr7h4b2p7N797XGSsQsCPUT+LFSt/OW32s+zmF3TyqPPKJkdiQV78FDyo7e3p5e91FPsEyPW0bs3aGyLZzVFGOHAyji7VID'
        '9kwdt3CP0ButYDl5u0gBC0YuV6jkczldqonnWXImr6Iltm2r1GvVOq5dOK8M1NzxHNe0WS/V6JeW8LnTt9kWyk+KSU5wYgI4hwJrqQH6wCYcLcKCYtWhdNgb'
        'L+mQBZy8LMDCWsxb1ZqiHR6lIUhKexpJ3+AkBSMQx5N+BHUjWpZXcab40cqNtWifw9agHjDxKivYiSC+GZcYKUbUFANAoaZuSLCjMUSkyF/QeRITuNC48agJ'
        'ikdNeKbskgPsXACw4lwAHo2TgnOB01u34YICwWDW8FDOEu7msCPICW5/yOdicMmszTFxwddM0MbQ4TxVWZSVONZ7GC6/luYVBkOpAqM9XdGk4FQvKhWJj89p'
        '26ZkgXWZUsZmi7jZYzmh7R4KkuCRqqmJ8gj1EwYSQytww1qiPs7N0oKlyVG9eDakJZ6WZyJEIMrIOs6ZZZIN3Fpw4AICadbZWcTDE2iV53LkYcrlcKbnctwU'
        'Z/JndMmpWfNDi8WaxuSAjrHBd2OyBD6FMF3CidGOjkQiwTeacKu0hNFlU3axAFYD0FOE+R4rO2FC7gYys6PGtFiB6Fhj8K8c7LuqshUdDXwrEcBUASiRorQR'
        'ogqdL0sq8smmJDsyk6Rj/En3lH0ycNw8GThvyxqgMOyULwxbNMW9BJ2dDzCYRFTm7fRbfTu3CZmr5EGppW3XCrWNqwgeUgVJTe/BBpxa4kHJhAiinEOGwRBl'
        'DFdEjVlpN7451Tn0xJPDR3IxMcpqigUfT2f4l0IffNnRM7FomeLVLtUXi3xw4NHhwZbwdk0s9uYp3hm/7szit96d+BPh5lMccL5bNCAe9Plb4kkMQHzmRLCN'
        'HGgWF1qq7hlWI0NLW0R6qnseU71ozS4vfJBpHhgz2dWd7Vq9phTluUqcIflzCXxXNv1wMTLiz6z1m75YPzxv1DLWb/U4P5Xi/FycEb7eGeHwhrFE0qt+cbmE'
        'm52sKRG0gU0KA6xepnFC65JHwMF8hiWkjE6db9WdGrK4keZkIAeIFQjbC8FGEsYygajFfClQkrfXOhCvKyIMzw2cI1AiaG4br+Bh31ao3CNRvqjocyI3r51p'
        'vnJKWTl3pXn6PD+6TOdbfnCGzlL96oXGTy/wg4l4uLlx7aXmi9cbz7wVeapKIqvYiwCCdkVEovFSqwejBTBcOXNl5dR1Ojl44VLz4vsRx7z6mUNftHDi5tUL'
        '4nh260PZfHnkFaXoNZCZJAM1wWFJRQhUEZ0GKxYGPIslcGDvcD+e/4cfigPcj27FEshkjD6twWQgXyv6+2aKsMDaDizeGItgsbdMjZMC5LE/XovKI8rOVsct'
        'B0BZAp1BcSj0x62n+vRlPAsqweyC7j6s7dzmb4mHdTANc2qpZpm2bS6hIGAHR0iiTiz29ElnbStVLC8dt30aRIdbZQrlufvDFD9AUk/1yT924WlyRFWaJ4RH'
        'l8FbEOKQ7C51zxOqaPIhKV2S+Cehx6eiHz0MF0d53d1HUjvNGx/P9k9GICDwz++Ez+zEYndW7ULqONo4Az+pB7AblrAjZUCirAQQaBDRLcF1eheWm56GdTLt'
        'DUA+iwOAp3ZUmYsZPtiA7p6d5TugEaEkvjASFYWH6ovMUCnYI/CsSofV5ScYeqP6Q29CMkhT2f5LoCoPxQk2QWE3aqsgEyjEw3BUOQxHpTCcADhcXVQ3NuRh'
        'FhnSKUfb3AptQmQIE0YOp1m1N1J4TQAMOofVYCiNynwbq4DlKQV8oTURFGFBNCrqwWFCcUpxIYexsDEHsf1HpqX4NhUGs834thgniCpELIrb5qVTzT9+E+T5'
        '25FHGum46JzsV1VFGJvawrHqVq37qkJ5e/WKQAskBD/0cdzXHTVuE1ntVzQ3vERElSRFCEhgPNVAFAKvzMNFQoE+OgJCb2UsGNqwv1Uo/l3kOCic4+KASFuS'
        'AVJQoM2qFJGc8j4M4toL7cEF8Xb9x4GvPN4mOtwmprGj6If5Z2vtKaaVD5RKlfzQYsuWOPgQ38niJRL4ftBU1gR7FWSBODXQrteGbsReRkwr+/Ec+3CZLaww'
        'MQdN0O/aaCoOHpvFIzCUMJdp2WoH7+hh9nrjbofEcvlRs1jbX7FH6djl4alvAcn8DUvUDi4EJzrDIe3kK0ry/EA6pavxhFc4PwpVxpgH14lH4jVJ0PTd8M7d'
        'hDEQMj3hWyYGT0LkF6+051ABJdjGwAMm2P1Bc0cP7Yuow0oy0vOJNVzwGh9nFZNxu13tABN4y3te/noDmAbhcWtpFIhhSY3jSBbLtcndsWUFbGKO2YodIIsb'
        'r4FeVv8rtKjQexP5jqL2ws8pSD4ndMjIIuTpaV2EOZNNOjjghtq5iz/zW7J8DtylqYfSOfqWcV6qa1pVNLGiU6LR88rx8P7RCV2Vs7awUQL1NqBrSFFbjDdb'
        'RSamfX4HOVwrKvIxSi9htPOyu7x6AbNCYMa9n7/ZePUi5Yy4+KtVUhUG4hlDWxZuBKMhtHdf4KIRF7bIwvMMTofYwMW4uMX42MVQtKEXbpgMBzTq4eNxEVgF'
        'QgbjkArtyXtKXotgLYkFCW+PkehwiAgwCDKTy2UMW4/pfHyDpwWxv4ah4gkw3CPhh2MwrE3lhwBJ/UX3kACyah6S5p+cbbxzQznAYR5kMCm93L/7fuNPz2Be'
        'usZPLivNZ94CDTg2KYmEoRz2qfrCPlX9ltEcAjjKAADaNkgxos3nLq+8+EN0z9y8ehY4v3H2rJQjDyY4zpOL7zcv3nB1d6qhNL/33ZXvXcD+rbx8Dl7H9gg3'
        'EkDKorRDpJHrQmgLRyIMii/K0J8SEl0dBE3famRWHQ8f6i+db/z0UuON7zZfOts8dcHLskIesvdON372FiUIjRkRV1xLu2nkpydsxtOTWw1RZDW0mHMM6Q0E'
        'bj53gZMzQPZzbzeeP+UvEUtfPlMEKtJkqZTLoHFE2HfSqhVMq4mwQssU651/8ukhIW6sJsIp8FbAjBTmhnEropw7HBs/v9L46ek1yfKQ4GaeDoO7FvyBukZs'
        'mK4cAMJoEBeqG4zURdM6It52a3AexHmGY8nQXv/dQUY/hSGF2XJdiKIIjVB8LsuJxBxWn4awZ6nNFkxDhNF6jQcKscg0IxBTKxWPzKAm8btg0nBMLYszi2RP'
        'd2Cj5owM3KeGtRollo4U8w7H5EZGGXDznfcVIS/OC7l78z1cSnB4G2+80nzvql8oeAoeyx1GWmBI64qYzXzAYWCrWlj2BfRNnmE6YGnwt4ZvV8cbmqRvZzG5'
        'DaTBTr3L5b7gZPKVTk3XSyVy82sCzYLr2+9CSMlMN0usGUYsZn3gy9jlH+MCIZGZ5dBkuxe4o8JSmeJYtJWnLkZHd6kSyVeysu5HviXX9gzEcm2LWO943hT5'
        'Q2nrReK05ot/+Sny6GriwZtPgis5EdjH7jDJyKPn8f60a6EGOZ+WE8MN/GvXuNTirV9Nd2U6S0ManbcxSnmg8myFM1z9wevFnLUUUnFFwNgULK5ajLWqzekP'
        'sRwJundyH7hlZzoJfzL4pxv/9MCfHvzZgz976GdWl/QHmmRkIooA+8hQf6NVzOJutotutIrv5zwQju+Xxt5FgYcS0r516wB/0MliwvujFs0fYQJ4UAhx0bx5'
        '4ypx8pkraqs4fpdQdYymkgkVHjF/0CFtL3mCTPSNR7x7ZjOLQ4wDzTgnCPmJKMgtk2vsMQjSnjUl1lCjVOjzV7hZACIVBcYqloE/gb3otbdkuYMe2MAPs9Tu'
        'VXgxlL1U4ruwt7cV47nZi1blvpZ5jlqz4E+v+lhQnpHVOHWee5oCQQokx5Lz1C1DLhdIHwokE2tMhNNS43DSofWFam410m2tuBevgwmp+BcZYInmtT+j8IBz'
        'p5pvfFdpvnFKrMvuDhHtF+E6xC1ppjG9cfbmO5cUoBSmzrx0eU2LDOtQZDGfy9zHCoyMSZSjJF7DtTlxmR7oZeAVBlCkHsatNLHWtaWXcY8FH1FJTJAq1SX0'
        'aTzWQ4k+/AV5bTmQh9J1GCwBC1tXUKaxyl08cZbniPanmxFRc/4UK3LmmT0GyyjDU25P7jF41hlydbASC3sMkWomuRBK+k1JZ8AqYgD0toWTNKvYVSSkeNPE'
        'irOJxISSKYCSUjeM9NrSGj9zHXga+P00Zo7mgpH7H1o7gdwUMYYnyl1Mdg0me7r1VMHyUkdnduBGMYkTx1BR9OVrqp5yqqViTcMYsGQmSv6vPVszrI7XG6+f'
        'as+4FKHllQD7uT3p3ZeWj4c5NZw6vqIeCDYEQp3wBshfwh+aRmUf6d7R17dqB91bWDDR+au0prV7dY0bE2qM0xaCVTbSvr0bKagPcQnfEYB1HjEI235lCkZ7'
        'LsIESIo7VcTtIKGVn8L0PIbhBO0qPtydJeso2CwHuNWIuWkA0eoyMru9HgoHMsaYasVkDGJ6YC5Z5a28c22PAlPCaBK9fApEPqabb303hxuEa4yLcF12w0bE'
        'XO7Z1deF7x7O6pGvs2n3dVyqOMlq8NXt3uuC1r1rdLx7LLw5iAHERuz1Vd6VPZLMx20hPjPiZlRPOlDBGPew9EGgCQXM0afHZqviI6ittspsNaRsUzErzVaD'
        '59mq2BHLZpRk2Gp4czsEOCgYQN1i7B4JP1JScKZsfy1pPHNevkLqutJ45+TNa7/yu25dn+2FxvOnVtN86bIbdnGLkUl6Ut/Llc7WZZZMi40n/Y3mS0yyZdAV'
        'Kot0r5feTw3w+Wm49wXxiWuIe3t0724IlwNPRDfB1Qn24XGpx8hJ4muKjveYW1oJvK9J78ipIfn2JHUXAFTmuCngBnLSFjjDO8csIBarXzWXcD+HVK/QhRIB'
        '7UlSh119j8df+BQ+hJXsy+wiAxk0PvhIZ0N2BAO3mpYv/ErnbzTfu6A03nwB/bSvv0UbRJdPwqvVVxqmtPqdjCEPNpocBkOpK5vetSM8G5iBRXHOoZhHmbCk'
        'dHGyupfK0W0p/GHwqq2CZURE3o7T8Wm82Mow1H0DYwP8yhXp/isc00k9DlOudrPISN++ZKkQ4csJW3jBoJUopR5JlaSgUmHXAXRdX4PXjI8sC8Bey7CGEY6M'
        'f4nCGm1MosutIPoXZ1FS3bz6dvO5S2F/h8Rwvn0dOYomPFnSAjP+i2ZjVE8Z6DVsa/j8srTtSN1oj7w+40zzWcX6LVnCvSH7b43GcCCM/+KPG8+9S1bwGyeb'
        'L10NbAe+9wKqQtKFZZeh+JVVO8zE3m5ZbuwWws8nRCJ3bh7gtz9MY5Q7xT3DAlsqKVOWd86WTh+5t0KkwoqtFAIT65vHQxGMG9q11EWiGiZ4b8FwlzwqKLHY'
        'EsNuSyyW86V6AR1IuPIy97p4xlbg4NnHfN3GmGfGNRHnU4vT/KJE+W4Q0D5YtZgL1z6tS0JE4+zWKW/JVfWt8qrbZsNiLjI3P7/kjZu0/LKVC1EIKfy+0Ma1'
        'UxhFwGoIVan1LS14xM6IutdS3NKWdAnpKhyqtJg8oBwBaV4qzszWvBzt0xadtXOAmXGzgDiY0v+GDjumfHdSynzQH8ntgeCtWKaPKGx4qnXcFprvMF1gMTxW'
        'tgrGce9SSHd1jaKP/6LJR9Ingp1Bz8wiNw1pt0Jb/A5egMH+6eI6LWpVulqMDQy73GxSX9vtdfyqMRBuQs32dtounuSv2RVkLRdSXBTl2zX9SFHPeccmdeam'
        'xWt/2qqgt9UlFM/vvCv6I11JdFIJ3prY4lAWsgbdUSp5O9yhZAq4OgmmzMDObOQKm9ljSED2GJlsO7iLQWA3KPKltl1XSBTvxFB1XMKtv01O4TIkhOGrFwL3'
        'PnHv2iWF1lb51s9IKtfMYimKyFEGDJE8MxjqswdpW0aS7WgIBcV6a8KH7wNeywgwxUne+/dJUrTdQjxEQS6Uq0ByXIXsigeUwRKm6SaxiOt5jV+h4wpR5xgs'
        'fUnFxPAdKkDprVGUFurVUhGvcsDQZfJOUsByKHE3OUvYHdZlEvyRygKW2pPZ2R++YMF1BvG8c4ZvoZAuKpauIQ7nT8zTIVkR9RTrOoqrKO/YxzqWovrlNuwT'
        'u9JTN50ekEoTV337tpR9KGw16MJibuNHTLG4WJDIgq46J/uBWjiF/D6fdl3qbfuhyZuOWnGEE0bV47sq+RQCERrJccmLl04SLzJ7Nck8DBn4Lz0ZDVvMoC4j'
        '05J6sdwU64VtIQ+/dxplHgiIN86422lkc66+ybGGGdcWh/zzcsenyRncER6dKMXnWFnTdob8r62tjcialSnHshdQkLXp68cJTxdvRzr95SN+HDIFr0pygu6P'
        'Eu8y4p3QKeWX3ZNrnb2fju/0UxHyq85Hw5O2JIYFj5CojeZYSbwbPtEbTaTY1YvGjy8BEnd67jdvlLsCikYIFl+MVgPGinV+ehKTsOMSMxm8CL0dodmGwBQD'
        '1KaMmFaPhy6XP+HGul27evOd99u+jLaF8CB2ac0dvgnXtoQTd3tfIHxvGe2gGcvw9enmkv7Kn4SRFOogWc39ZEBbqBeiioeOMrz4slanFM4mu+5DMUsoq5YU'
        'nheS2O/YrGUH/EYR26bzxbKW6U5KJsO/qDP+GRK/Hejt862qYnDi0TUsRGutyPy4ASmjR49Xkg0z7iKV6/N4y4qlBYy+fmkIJ2OGEPuFgAyObrygpNIwk4wy'
        'pkxbbMfjIfbCDHabus+lgRNB9ono/6Iwh/kBCbg6PzA7RN57bodBW25EhwylrYafudoVpO6N9p+CBCUncX/kdGgjUOpfLDJvk88Xahbel+RDTfQGOYLEndT1'
        'tk0tHsHmsowPzlr623j2tcal14BPRJDmLfCPONoouz55/OxlivukkBfl179QjgsNCVMiCY8XY1zVi3xhGS+H6IPSwwUyWcZpQ1DoBN9W+/Uv3I7BV8/RevH9'
        'xnvygKJzDV1qsgNW+PZXOxDIckRCo/JxTkm2sD0YYY9SHIHuT71veAmNMt2+4EWXW/Agd4WxDG1w9xFE33aIrAIHTvJEwBkWkOhiZ+YIgK88SxF83etLWBSd'
        'NJKtZz5LCnMepXnVNSIhqf8szkKCy9ZgmMp7xbLWGavM+3cfkuOS/j7phlOwQ14Uxyxtm+Vxg24tBwtr7j5dIBZD4mCPO/sVvP4t4H4coATvBcxAy/cLcSaZ'
        'xbKj4F2uJsZvUJpJBY+tl8ThUoBerO0WV8HRZmax1nKnsj/2VAovMJ6e/B1OsdDOq77+6TsxJyfm6MSEnP9F7+j4HfJn4sWBSB1RR/xOEs2exhb5G0z6Kr6X'
        'KjPoyV1DSs1v1626C4oNggRA5H8FvGpznVEpYWvieTgLJ2hplveO5yoVb6UERm5So4FqNSaZUVKxK3gtSqFogyWCe/zBeCB4beCf3eJUIS9ouN/4GwfRMgg5'
        'zX23XSUTxk3Q5sLFTXBDwtUN3/5WZcoxiHipJ/CvNm8u0pHSjBfgjek2/IUC0KfqzhLbfPaQq1bRsSQ/BNQWipW6Y4zT08mH+0QLMFZmKee+9y5fkmPRazbe'
        'cmDnQmCyIj6d73azaAIZMhszI5CKooaOKcc4fqIzIAv4C8pCjKLG0WQKi/eUOVrlJ04pNbKb9ZhCn/tUOV1vIPmzJ1H0gEgRGQLwCgCjNocpxADkU6atuadq'
        'NBcF2jrnhdWkiicO3rmhypkS+HBgxAAA21upgG1c9qDx41oyOKaBsON7IUgszqBNSEz9jYFklTFjaCESFqXB2h0c+ciiDHi4u3Uninj+s/fugde4g/fnr7DE'
        'CO5x2JDLTxgiPDwyskmqrTTOnCQV6vKP5WhLmOkpsOlALKtDeKxaGUG/xBE2iVHRWvn+meazl1eevaE0fnmm8dMLKtCFas1YlXm85lRTd2TBXNmVdt/Mw8ID'
        'M1jbkU4ne3dI6+y0jVIAJF1qP37TSBZVzQLxbDfGsFMJptwCS5UMdaqCydusxSqsEIHsZAjngDlllTSqlcQpgL3l+QzcsCihSqrJaRhKQ1PVZKYvCZBLBeBU'
        '1phZzs9WbEM9pq4Gn8d5sLtFkKig3CGdms9dbl66IGynxvMvY/JRpu6hvrhy7hSMHMWAhAgaRAFJsmRovX4vdRQ6C6ZdRC42/GwgdTTTTkcrVWlQCLq+Gx7K'
        '47DIsZLd8Vhnb71Wq5Q1KO2nD2e67aD7nsZdaBa2riYx6TIOZcmcnyqY7ECNU5+ax9MY/LyPiyteDm6oJWu6FhiVQTQBp4ItN5670nzv3Mozl4HsF5qn3l55'
        '+QU16acQn/M++DbGv8hRNUL0BSnCX0RRpTdqmHh5jh1LqrOCp17ooIi6WieHMGGMD4i/L+LNsWKhNmt0d4fhIW6LoRGLYOmrL1MABj/Acl7xndVp/Pg8vnkT'
        'TJZTF3AoecBTsENkAb1xsnnpnCyo4rmOqxvHYB2d9Cf0qs9PoV7k+jqSvcFIdFhLA8PjihEtndyl67uhiH+gAuGbLiGgICODbHQeZzicUDl1M92tRos2shCY'
        'EQFWbfz5DSYGJGC7WfkwzN0uVcSBEioYRp7POwn7/QJpkkYUORacbkrZYGX88w4tfzVZ1uM4qLed5uXWZZu9TRxQzYnGQbq9kox4x6OyPP6c2Lzlt5TGM9eb'
        'f/ym6vJFn76b14+awH1Rc4SXF6Dfug7d+fUvGlffbL54/ea7b/36F/I2M86glXN/hqvByvNvrZy70jj7puvkaL3IyOIs0KZwPWAKnsal041rVyj7zTvvNv/k'
        'bFC4kd50y01B35ovvkupmMjJEd8OaVVrXjcxrP+H14Fm3/8RX/4wBvLSa3Sc9aWzeA7QFeAU1vMX70s+EqV5+t83XzkL71A+Ia6vXqfzrc++RnLn6hWM+o10'
        'MK0V0cGaXera3+/pDSD3Lq1876LCeoD8Lda4q7/CcAIY7uZfXoZOkavrFcov0zh3xusOPPwxKARxC31v/BDJeH1jqrKIKcNBZehXDuztGti+d/s3tn/T7yAD'
        '5ODViPdWCIKApuDqtGskT5jj6k7ymG1WWd5eA9TApJdjwlAf6M72ZneaousBXaI7UpfwcY17RnXl+euNH70AesX1KD2i4rCUYLgi0k1PnoHbSvMhdRUW0lol'
        'D8aDevRgbt/QgaGxodzR4UP7Dh/lcQTk0gksXIvFcrVeW+XAiVzSy73LHmRyWVWYGOxJ6hvD+PGoVYtKw4g+257uZPCqsYimgnDkFI0MStAq5EZhlCF4rGLP'
        'oV0hHBopfryBpcE33DLJgmnNV8rccpKqivT/fpqb0+iJ700zAteK+bmgCRXUCaUz49zGi8kAQjvZQomTNSWyCfUUu/+BkhIIe1WcJXOlKCvKj5V5Qo89llFh'
        'WLKMDMxXyBY3IxPh/UMvhbu9IDwU/eHMYtz8Z8VEZ6M8Hkjs3dJMxNKa2rx2HgQXytX/ffL1oMKF7pYUcEeuXDlmAuqaD+2kaE7uJI5jkNYsnSK2Hx3r7fYu'
        'OnCCjkQwTymoav7+u34QQNXwcEbSo8euAnMpncpEukmZh2hovlpbitkbje6tAS2E2g9j7kvmRl2IONLg34zD2HWDKVgxoVPovD8+1y8gjc9NSqlpVHYCUk1K'
        'JyGSLJwnKfwkwsvhO8FwIraxccKmkDNr6qQhnKEp4AZN+ENT9Ros70WnAnjMmzWtxQYV+QBTCNBNXeY7tOFSeNx1Ek0K4vsTj0RcJBWpkfMFje8EqeHQp5JM'
        'eNIqWxBe6gQWXXMnWuPv8Qk/S8MOFrrQ+Fab9EScDoim+Jr4L7zVEkQvIrsKM9q9XTZ/QhLm1KADB++cQv0w7N5wVd5QyzUL/dWmOFwa5c+szVdb1Iu5A07U'
        'TvLQbtPJF4vcK5cMOURbgLetasnM8+2JeHdrtEDjPmqUrJqGYjHJqZx08xtGcJEeKcVab1eSscl2J1KWKKlh1nmbbfGwi/j6lQdBNrCJ0A7OPFmauLKPYlui'
        'MXbXBVy1g+tCSHDGLRQseW6YSr6FW2CIKZT5ehXTl4gNAHdBFEmcIwPpeLut4g3EGTZetGU8CJMZ1Ox04nikOGEWMtlyilRC7LuLRDAnEtFSgMUTkVcgEE8k'
        'PAfJjB6/b8/8DrA2ThdnNO4xJYnaOHtFlZdvmyW0jBGJwvlU1IEJi04N89BQzKSKMdYvsoNIF8+ooQ0I3xLtUzdbqw6+lIBMsSw6ORMvqtb0fm/vKlXAYxSV'
        'pWi9wisWoYAGKxQqx8qSrKWkc6Cx45xa8PsTmV7ohTdSeSnVnkcFNiFBpS8GI3r66Ew5tjlenCRQbn/FhhO8mAxu0/CtKKzXGVA9FtyDD9hkgJwUSMtfjadF'
        'gnefR4hF80C5PVk+tsxJQ88ezHZJOhjb5jK83HtEgYgEfOnFTEbk4AvQK7J0doebsc933Tm156dSYBPP7fuCxdkDL6XMsVJBbTq4Ach+h1iT2Vf9Ecei6TaL'
        'OkYEPJzZoWvB4/9kw1j82EyklaZ5p+sJoo7hRj4ozCWAiVFqKdwM5klm2V9WZzzbv2MyqZaKtRoIa50l+uFtsyH0gxSijSVN5A08RLnviHziybzpzOn8cjhH'
        'JE3MsKwP3ewjyz5opCY7IxThBSn813M/sJnTv1qUazY+IFIE3AUnTcSGLZRZJcIzxP8eTaCf/lkA/L87nJEodrOY49nZliiSLEyJaWOCSnx7zB6RfY9TdG1s'
        'TsjqkNHJN6hrc6mxSrVkLVglzUVQj9zLZh8BAGIrMeg7U/XdvABetlEEqgLPqttA0uPlbmrSv7HHi7objNNqTxoGIJvuOu5RjXXIyduWVSa/uqZv3969LdOb'
        'PhFXbNbCrR5erjt9Qt70qThFLpm1TDKtJ7VuWEaT8L0b/qbhe9QeRVLLV0r1+XISll3dvxq7AEOrMYvuqqDtK1zhMB68z97qFekdj/PDs9qt9jGEv4y1rKdm'
        '7GKBY294nTDQoc98/txF1xsalin40NQ9Q07erFqPqEnu1s/1B7vQblCUu+BHpVh3Azk8X4dYdFHJYnp+hA/ES5WIOe55JkVMunu6+Ut+2wDPmMhNFuYrCV8T'
        '7t35tdXAG7/6w7cJy9d4ic38+MT0XkQNJQ8H4FZ5oWiDQUMxCwcODw4cGDhyhB0WQYUci6VmK/N097GubFfYTj1u1PN9etUPODU/B981dt8cywCcpJmfq8xJ'
        'e+jCipgynWJ+kGmEqNTRbQOSAYRBR1AWRhrlgiGqDR/afzjJXASG+qAGdhc6EHRHeVCjgnSTDv4S+reICWLXlhlR95jF3kbGivA8KwdBfCweDfhHpeuIcDWj'
        'L8dQZRWe0igQsmuUAfAV9YLWIhub3B1RUAaJiLDrWbE5IwIDjQwtZnypByp5szQxERzdbfsrdfuIL6yKnxfJ2fUyniMxwrfMGEamr6dT+FtJsM9F3SIvEjUh'
        'NpR20g85kMe8vavMJSeD/zJwN7P4udONZ66rSXmdwDSm12kr+c9vKHIG8us332b5xfizVy7dvHG6RertYEhxS6NgoFplUSjefsFuFsMCIqBUqYh4zKBp7tEl'
        'whYHoHSmG61x8n7Xq9wql+/KaY+WrelIlwypyWlVZIHlYic6b37j1Qs3f3GjXznudhaESYJP74S8HJKI64zMf4MH+pFZ+iNmiUZvdN997IahitvY1X4mWDv1'
        'DU/f4YY5Pv25iGvBKQRUhDr+02YqDHWX16WWN2B+HXtDR0fH8hZZWC5/JjhxxvT1y5u4FFzeLCTg0/fyMdlGxEzVFmtPbyT3kL4OSnGPEXzv9Gj/9GfDwVFP'
        'f37UN7Yp5UBlpl/Rv7q8ad60nVmztHybs+QsbyS5sXxHDYxna8rMzyFOFEaKX/Jz0MJyJ7sUYwxKLt/OrpNY3pzLYblcbvlO/EYF4ccm9hrg0lGJ5Q1I5uXN'
        'QnAv3+6AtMgDSBt6XiMdBEHh+1zOvh3JtonfMo7PcbcEoG4g6t7h8vdyJ5PsoDHmlzcSoZbXV6A1XIyWN/EVa/k2EDvQy5q9vAEXqOXb2bbQ8kZagZY7PZfd'
        '8ibO6/YWROEOl5nf7PiHDnzyB+6tHjkeQprjdzEtLW/ewzr9iN0NRdfB/84V+Pvb29atW/c/O1Ifd6Q+6kj93T1fOfnoJ3d99uO77vvNXfedn/norodO7v/k'
        'C186uf/U4U9+Xzm5/283fOGTP9x6cvDfPv7dx89u+mjDl/7+jo7PKL/t/Ny6u3+7vuO+bz+17rcdHV8/us56fAN8WXh8Q9m6A758x7rj62Nb/r6j457Hx7ZA'
        'C1/teuPgqwdfP/zhZuX0hg/vVk4vnv/CJ/d+4eN7t/7m3q2XvvrRverp2z+5b+vPci/nrox+dF/m6tYP78uevv1vN//BJ3+QOH37mXs++XLi9G3P3/nDO8/u'
        '+3Dz7//3zVt+ePTsU+e/cWnho7tSV2//xT1v3/PfNn/t7+/seDD72y0dGzcTup0fbvjDjzcoH25Q/uuGxD9+sukz/9DRue7uT7Z8/uMtym+2KB9tSZwc+u36'
        'zRvv/rvN935y75de+vJPvnx+6mffevlbPyu/XL7yr385+Feb/tOWv97y8dee+PBrT3z0tdGP9ox9dP+TH9371AffnPvw3jnAePPdz2/54ZbzY1eyp7d8uDn9'
        'yR33fPDZBz+848GPN2c+3Jy5+uBfffED/Db8PzY/9Mnmz368+cu/2fzlD+7LfNDz9f88+sETRz/4o/kPn5j/6GD5w57y326u/K/Nd/3j6Y3/9NvPA5b/5DwE'
        'I/bXd++9bzDZ8R+SX9z/1dv+44a9v7///vV/c986+PE396/fr2z8G2UDfP//LDb64Q=='
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
