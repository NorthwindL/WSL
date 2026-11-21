$ErrorActionPreference = 'Stop'
$installer = Get-Content (Join-Path $PSScriptRoot '../install.sh') -Raw -Encoding UTF8
$source = [regex]::Match($installer, "(?s)<<'SESSION_PS'\r?\n(.*?)\r?\nSESSION_PS").Groups[1].Value
if (!$source) { throw 'Embedded Windows backend not found' }
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Exchange', 'Encode', 'Decode', 'Test-ExportFilePath', 'Test-WslgCommandLine')) {
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
    public static bool HasFiles = false, HasMarker = false;
    public static int Writes = 0;
    public static byte[][] LastPayload;
    public static uint GetClipboardSequenceNumber() { return 2; }
    public static bool IsClipboardFormatAvailable(uint format) {
        return format == 15 ? HasFiles : HasMarker;
    }
    public static string Publish(IntPtr window, uint expected, uint[] formats, byte[][] data) {
        Writes++;
        LastPayload = data;
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
Write-Output 'Metadata-only copy, paste-triggered path retrieval and genuine Linux export checks passed.'
