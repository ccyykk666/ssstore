param(
    [string]$OutputPath = (Join-Path (Get-Location) 'inventory.plist'),
    [string]$ToolPath = 'ideviceinstaller',
    [string]$UDID
)
$ErrorActionPreference = 'Stop'

# Requires the modern ideviceinstaller CLI with the `list` subcommand.
# Connect by USB, unlock the phone, and accept its Trust prompt first.
$arguments = @('--xml', '--user')
if ($UDID) { $arguments += @('--udid', $UDID) }
foreach ($attribute in @('CFBundleIdentifier', 'CFBundleDisplayName', 'CFBundleName',
                         'CFBundleShortVersionString', 'CFBundleVersion', 'ApplicationType')) {
    $arguments += @('--attribute', $attribute)
}
$arguments += 'list'
$result = & $ToolPath @arguments
if ($LASTEXITCODE -ne 0) { throw "ideviceinstaller failed with exit code $LASTEXITCODE" }
$content = $result -join "`n"
[xml]$plist = $content
if (-not $plist.plist.array) { throw 'Expected a plist array; the output file has not been changed.' }
$target = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $target) { throw "File already exists: $target. Choose a new OutputPath." }
[IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($false))
Write-Output "已导出清单：$target"
