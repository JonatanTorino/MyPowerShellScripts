# Agent Instructions

Conventions for this repository. They apply to every `.ps1` file at the repository
root.

> This file holds the actual content. `AGENTS.md` is a Git symlink pointing here, so
> agents that look for either filename find the same instructions. The real file is
> `CLAUDE.md` on purpose: this team works mostly on Windows, where a clone without
> `core.symlinks=true` materializes a symlink as a plain text file containing its
> target path. Keeping the content in `CLAUDE.md` means that degradation only ever
> affects `AGENTS.md`, never the file that is loaded automatically.

## File Encoding: UTF-8 **with BOM** (mandatory)

Every `.ps1` file in this repository must be saved as **UTF-8 with BOM** and use
**CRLF** line endings. New scripts included. No exceptions.

**Why this is not cosmetic:** these scripts target **Windows PowerShell 5.1**, which is
a hard requirement because the `d365fo.tools` module does not run on PowerShell 7 /
pwsh. Windows PowerShell 5.1 does not assume UTF-8 when reading a script file: without
a BOM it falls back to the system ANSI code page (cp1252 on these machines). Every
accented character then decodes as two garbage characters — `módulo` renders as
`mA³dulo` — in `Get-Help` output, in `Write-Host` messages, and in pipeline logs.

The documentation in this repository is written in Spanish and is full of accented
characters, so a missing BOM silently corrupts it.

### How to verify

Run this from the repository root:

```powershell
Get-ChildItem -Filter *.ps1 | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    [PSCustomObject]@{ Script = $_.Name; Bom = $hasBom }
} | Where-Object { -not $_.Bom }
```

It must return nothing. Any script listed is missing its BOM.

### How to fix a file that is missing it

**Confirm the file is already valid UTF-8 before doing this.** Prefixing a BOM only
declares the encoding the bytes already use; it does not convert anything. If the file
is actually cp1252, adding a UTF-8 BOM corrupts it and it must be re-encoded instead.

```powershell
$path    = '.\MyScript.ps1'
$content = Get-Content -Path $path -Raw -Encoding UTF8
[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding $true))
```

## Script Documentation: comment-based help

Every script exposes PowerShell comment-based help, so `Get-Help .\Script.ps1 -Full`
is the single source of truth on how to use it.

Required structure:

- `.SYNOPSIS` — one or two lines: what the script does.
- `.DESCRIPTION` — how it works, side effects, destructive behavior, platform
  requirements, and any known limitation that is still true today.
- `.PARAMETER <name>` — one entry per parameter, including its default value.
- `.EXAMPLE` — realistic invocations, each followed by a line explaining what that
  invocation produces. Omit only for scripts that take no parameters and have a single
  obvious use.
- `.LINK` — related scripts in this repository.

**The help block is not a changelog.** It documents the script as it behaves *now*.
History belongs in git. Do not add `CAMBIOS (<date>)` sections, and do not write
"before it did X, now it does Y" — describe only current behavior. If a design decision
is non-obvious (a deliberate phase order, a check that looks redundant), explain *why*
it is that way, not what it used to be.

Help text is written in **neutral Spanish**, matching the rest of the repository.
Agent-facing documentation such as this file is written in English.

Placement:

- The help block goes at the top of the file, immediately before `[CmdletBinding()]` /
  `param(...)`.
- If the script has a `#Requires` statement, that line stays first and the help block
  goes right after it. The BOM always comes first, before `#Requires`.
