$ErrorActionPreference = 'Stop'
$installer = Get-Content (Join-Path $PSScriptRoot '../install.sh') -Raw
$source = [regex]::Match($installer, "(?s)<<'SESSION_PS'\r?\n(.*?)\r?\nSESSION_PS").Groups[1].Value
if (!$source) { throw 'Embedded Windows backend not found' }
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Exchange'
}, $true)
if (!$definition) { throw 'Exchange function missing' }
# Exercise the production protocol guards with simulated native metadata.
# No test opens or changes the runner's actual Windows clipboard.
Add-Type @'
public static class ClipVersion {
    public static bool HasFiles = false, HasMarker = false;
    public static uint GetClipboardSequenceNumber() { return 2; }
    public static bool IsClipboardFormatAvailable(uint format) {
        return format == 15 ? HasFiles : HasMarker;
    }
}
'@
. ([scriptblock]::Create($definition.Extent.Text))
function Test-WslgClipboardOwner { throw 'Ordinary Windows text must not inspect clipboard owners' }
$filesOnly = $true
$textFiles = $false
$nativeDesktop = $true
$bridgeMarker = 1000
if ((Exchange 'READ 1') -ne 'EMPTY 2') { throw 'Non-file data was not skipped' }
if ((Exchange 'READ 2') -ne 'SAME 2') { throw 'Unchanged sequence was not skipped' }
[ClipVersion]::HasFiles = $true
[ClipVersion]::HasMarker = $true
if ((Exchange 'READ 1') -ne 'SAME 2') { throw 'Bridge-originated files were not skipped' }
if ((Exchange 'TEXT 2 YQ==') -ne 'ERROR') { throw 'File-only backend accepted a text write' }
if ((Exchange 'IMAGE 2 YQ==') -ne 'ERROR') { throw 'File-only backend accepted an image write' }
Write-Output 'Windows backend parsed; five protocol guard checks passed without clipboard access.'
