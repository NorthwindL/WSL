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
$script:linuxFocused = $false
function Test-WslgClipboardOwner { $script:ownerChecks++; return $false }
function Test-WslgForeground { return $script:linuxFocused }
function Read-WindowsClipboard { $script:readCount++; return $script:originalData }
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$filesOnly = $true
$textFiles = $false
$nativeDesktop = $true
$bridgeMarker = 1000
$window = @{ Handle = [IntPtr]::Zero }
if ((Exchange 'READ 1') -ne 'EMPTY 2') { throw 'Non-file data was not skipped' }
if ((Exchange 'READ 2') -ne 'SAME 2') { throw 'Unchanged sequence was not skipped' }
[ClipVersion]::HasFiles = $true
[ClipVersion]::HasMarker = $true
if ((Exchange 'READ 1') -ne 'SAME 2') { throw 'Bridge-originated files were not skipped' }
if ((Exchange 'TEXT 2 YQ==') -ne 'ERROR') { throw 'File-only backend accepted a text write' }
if ((Exchange 'IMAGE 2 YQ==') -ne 'ERROR') { throw 'File-only backend accepted an image write' }
[ClipVersion]::HasMarker = $false
# Remote Explorer is foreground: do not read or write the original FileDrop.
if ((Exchange 'READ 1') -ne 'DEFER 2') { throw 'Windows Explorer file copy was not deferred' }
if ($script:readCount -ne 0 -or $script:ownerChecks -ne 0 -or [ClipVersion]::Writes -ne 0) {
    throw 'Background bridge touched the Windows desktop file selection'
}
# Switching focus must allow the same Windows sequence to be imported, without
# replacing its original Windows desktop path or publishing a cache path back.
$desktopPath = 'C:\Users\ai\Desktop\黑龙江分院中移咨询主体专项激励分配明细-辽宁计划单列分院1.xlsx'
$script:originalData = [pscustomobject]@{ Paths = @($desktopPath) }
$script:originalData | Add-Member ScriptMethod GetDataPresent { param($format) return $format -eq 'FileDrop' }
$script:originalData | Add-Member ScriptMethod GetData { param($format) return $this.Paths }
$script:linuxFocused = $true
$reply = Exchange 'READ 1'
$parts = $reply.Split(' ')
if ($parts[0] -ne 'FILES' -or (Decode $parts[2]) -ne $desktopPath) { throw 'Original Windows path was changed' }
if ($script:readCount -ne 1 -or [ClipVersion]::Writes -ne 0) { throw 'Import modified the Windows clipboard' }
foreach ($path in @('/home/ai/.cache/wsl-clipboard/files/copy-_pfnm5x3/1/desktop.xlsx',
                    '\\wsl.localhost\Ubuntu\home\ai\.cache\wsl-clipboard\files\copy-_pfnm5x3\1\desktop.xlsx',
                    '\\wsl$\Ubuntu\tmp\chatgpt-clipboard.123\1\desktop.xlsx', 'relative.xlsx')) {
    if ((Exchange ('FILES 2 ' + (Encode $path))) -ne 'ERROR') { throw "Unsafe export accepted: $path" }
}
if ([ClipVersion]::Writes -ne 0) { throw 'An unsafe path replaced Windows FileDrop' }
$linuxPath = '\\wsl.localhost\Ubuntu\home\ai\document.xlsx'
if ((Exchange ('FILES 2 ' + (Encode $linuxPath))) -ne 'OK 2') { throw 'Genuine Linux file export failed' }
$drop = [Text.Encoding]::Unicode.GetString([ClipVersion]::LastPayload[0], 20, [ClipVersion]::LastPayload[0].Length - 20)
if (!$drop.Contains($linuxPath) -or [ClipVersion]::Writes -ne 1) { throw 'Incorrect native FileDrop export' }
if ((Test-WslgCommandLine 'mstsc.exe /v:remote-host') -or
    !(Test-WslgCommandLine 'msrdc.exe /wslg')) { throw 'Ordinary RDP was confused with WSLg' }
Write-Output 'Windows/RDP file-copy isolation, cache-path rejection and genuine Linux export checks passed.'
