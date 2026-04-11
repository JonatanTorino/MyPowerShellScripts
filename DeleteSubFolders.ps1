[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateNotNullOrEmpty()]$path,
    [Parameter(Mandatory=$true)]
    [string]
    [ValidateNotNullOrEmpty]$folderToRemove
)

# Get-ChildItem -Path $path -Recurse -Force -Directory -Include $folderToRemove | Remove-Item -Recurse -Confirm:$false -Force
Get-ChildItem -Path $path -Recurse -Force -Directory -Include $folderToRemove -ErrorAction SilentlyContinue |
ForEach-Object {
    if (Test-Path -LiteralPath $_.FullName) {
        try {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "No se pudo borrar: $($_.FullName) :: $($_.Exception.Message)"
        }
    }
}