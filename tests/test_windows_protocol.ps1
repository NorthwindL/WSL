$ErrorActionPreference = 'Stop'
$installer = Get-Content (Join-Path $PSScriptRoot '../install.sh') -Raw -Encoding UTF8
$source = [regex]::Match($installer, "(?s)<<'SESSION_PS'\r?\n(.*?)\r?\nSESSION_PS").Groups[1].Value
if (!$source) { throw 'Embedded Windows backend not found' }
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Exchange', 'Encode', 'Decode', 'Test-ExportFilePath', 'Test-WslgCommandLine', 'Test-WindowsImageFormat', 'Read-WindowsPng', 'Publish-WindowsImage')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (!$definition) { throw "Function missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
# Simulate native metadata and writes; never access the runner's clipboard.
Add-Type @'
using System;
public static class ClipVersion {
    public static bool HasFiles = false, HasMarker = false, HasText = false, HasImage = false;
    public static int Writes = 0;
    public static byte[][] LastPayload;
    public static uint[] LastFormats;
    public static uint GetClipboardSequenceNumber() { return 2; }
    public static bool IsClipboardFormatAvailable(uint format) {
        return format == 15 ? HasFiles : format == 1000 ? HasMarker : format == 13 ? HasText : (format == 1001 || format == 8) ? HasImage : false;
    }
    public static string Publish(IntPtr window, uint expected, uint[] formats, byte[][] data) {
        Writes++;
        LastPayload = data;
        LastFormats = formats;
        return "OK 2";
    }
}
'@
$script:ownerChecks = 0
$script:readCount = 0
function Test-WslgClipboardOwner { $script:ownerChecks++; return $false }
function Read-WindowsClipboard { $script:readCount++; return $script:originalData }
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$bridgeMarker = 1000
$pngFormat = 1001
$window = @{ Handle = [IntPtr]::Zero }
if ((Exchange 'POLL 1') -ne 'OTHER 2') { throw 'Non-file metadata failed' }
if ((Exchange 'POLL 2') -ne 'SAME 2') { throw 'Unchanged sequence failed' }
[ClipVersion]::HasFiles = $true
foreach ($context in @('local Windows desktop', 'remote desktop Explorer')) {
    for ($i = 0; $i -lt 5; $i++) {
        if ((Exchange 'POLL 1') -ne 'FILES 2') { throw "File metadata failed: $context" }
    }
}
if ($script:readCount -ne 0 -or [ClipVersion]::Writes -ne 0) {
    throw 'Windows copy or metadata polling read paths or changed FileDrop'
}
[ClipVersion]::HasMarker = $true
if ((Exchange 'POLL 1') -ne 'OTHER 2' -or (Exchange 'PULL 2') -ne 'ERROR') {
    throw 'A bridge-originated file was imported back'
}
[ClipVersion]::HasMarker = $false
$desktopPath = 'C:\Users\ai\Desktop\黑龙江分院中移咨询主体专项激励分配明细-辽宁计划单列分院1.xlsx'
$script:originalData = [pscustomobject]@{ Paths = @($desktopPath) }
$script:originalData | Add-Member ScriptMethod GetDataPresent { param($format) return $format -eq 'FileDrop' }
$script:originalData | Add-Member ScriptMethod GetData { param($format) return $this.Paths }
if ((Exchange 'PULL 1') -ne 'CHANGED' -or $script:readCount -ne 0) { throw 'Stale paste read Windows paths' }
$parts = (Exchange 'PULL 2').Split(' ')
if ($parts[0] -ne 'FILES' -or (Decode $parts[2]) -ne $desktopPath) { throw 'Paste changed original Windows file path' }
if ($script:readCount -ne 1 -or [ClipVersion]::Writes -ne 0) { throw 'Paste import changed Windows FileDrop' }
foreach ($action in @('TEXT', 'IMAGE', 'READ', 'FILES')) {
    if ((Exchange ($action + ' 2 YQ==')) -ne 'ERROR') { throw 'Removed active protocol was accepted' }
}
foreach ($path in @('/home/ai/.cache/wsl-clipboard/files/copy-example/1/desktop.xlsx',
                    ('\' * 2 + 'wsl.localhost\Ubuntu\home\ai\.cache\wsl-clipboard\files\copy-example\1\desktop.xlsx'),
                    'relative.xlsx')) {
    if ((Exchange ('EXPORT 2 ' + (Encode $path))) -ne 'ERROR') { throw "Unsafe export accepted: $path" }
}
$linuxPath = [string]([char]92) * 2 + 'wsl.localhost' + [char]92 + 'Ubuntu' + [char]92 + 'home' + [char]92 + 'ai' + [char]92 + 'document.xlsx'
if ((Exchange ('EXPORT 2 ' + (Encode $linuxPath))) -ne 'OK 2') { throw 'Genuine Linux export failed' }
if ([ClipVersion]::Writes -ne 1) { throw 'Unexpected Windows clipboard write' }
if ((Test-WslgCommandLine 'mstsc.exe /v:remote-host') -or
    !(Test-WslgCommandLine 'msrdc.exe /wslg')) { throw 'Ordinary RDP was confused with WSLg' }
# Image metadata does not retrieve data, and rich text stays native even when
# its clipboard also contains a bitmap representation.
Add-Type -AssemblyName System.Drawing
[ClipVersion]::HasFiles = $false
[ClipVersion]::HasImage = $true
$reads = $script:readCount
if ((Exchange 'POLL 1') -ne 'IMAGE 2' -or $script:readCount -ne $reads) { throw 'Image metadata fetched data' }
[ClipVersion]::HasText = $true
if ((Exchange 'POLL 1') -ne 'OTHER 2' -or (Exchange 'PULL 2') -ne 'ERROR') { throw 'Mixed rich text was intercepted' }
[ClipVersion]::HasText = $false
$bitmap = New-Object Drawing.Bitmap(2, 2)
$stream = New-Object IO.MemoryStream
$bitmap.SetPixel(0, 0, [Drawing.Color]::Red)
$bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
$bytes = $stream.ToArray()
$bitmap.Dispose()
$script:originalData = [pscustomobject]@{ Image = $stream }
$script:originalData | Add-Member ScriptMethod GetDataPresent { param($format, $auto) return $format -eq 'PNG' }
$script:originalData | Add-Member ScriptMethod GetData { param($format, $auto) return $this.Image }
$reply = (Exchange 'PULL 2').Split(' ')
if ($reply[0] -ne 'IMAGE' -or $reply[2] -ne [Convert]::ToBase64String($bytes)) { throw 'PNG paste conversion failed' }
if ($script:readCount -ne $reads + 1) { throw 'PNG retrieval did not happen only at paste' }
# Test bitmap-only Windows screenshots with the production PNG converter.
$bitmap = New-Object Drawing.Bitmap(2, 2)
$data = [pscustomobject]@{ Image = $bitmap }
$data | Add-Member ScriptMethod GetDataPresent { param($format, $auto) return $format -eq 'Bitmap' }
$data | Add-Member ScriptMethod GetData { param($format, $auto) return $this.Image }
$converted = Read-WindowsPng $data
if (!$converted -or $converted[0] -ne 137 -or $converted[1] -ne 80) { throw 'Bitmap to PNG conversion failed' }
$writes = [ClipVersion]::Writes
if ((Exchange ('EXIMAGE 1 ' + [Convert]::ToBase64String($bytes))) -ne 'CHANGED') { throw 'Stale image write accepted' }
if ((Exchange ('EXIMAGE 2 ' + [Convert]::ToBase64String($bytes))) -ne 'OK 2') { throw 'Linux PNG export failed' }
if ([ClipVersion]::Writes -ne $writes + 1 -or
    [ClipVersion]::LastFormats -notcontains 1001 -or [ClipVersion]::LastFormats -notcontains 8 -or
    [ClipVersion]::LastFormats -contains 13) { throw 'PNG/DIB types were not preserved' }
if ((Exchange 'EXIMAGE 2 YQ==') -ne 'ERROR' -or [ClipVersion]::Writes -ne $writes + 1) { throw 'Invalid PNG changed clipboard' }
$bitmap = New-Object Drawing.Bitmap(2, 2)
$bmpStream = New-Object IO.MemoryStream
$bitmap.Save($bmpStream, [Drawing.Imaging.ImageFormat]::Bmp)
$bitmap.Dispose()
if ((Exchange ('EXIMAGE 2 ' + [Convert]::ToBase64String($bmpStream.ToArray()))) -ne 'OK 2' -or
    [ClipVersion]::LastPayload[0][0] -ne 137 -or [ClipVersion]::LastPayload[0][1] -ne 80) { throw 'BMP was not normalized into PNG for Windows' }
$bmpStream.Dispose()
$stream.Dispose()
Write-Output 'Native text, lazy file/image paste, bitmap conversion and reverse PNG/DIB export checks passed.'
