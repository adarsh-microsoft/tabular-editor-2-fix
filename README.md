# Tabular Editor 2 — Defender Fix

**One-line installer** that gets [Tabular Editor 2](https://github.com/TabularEditor/TabularEditor) running on corp-managed Windows machines where **Microsoft Defender for Endpoint** crashes it on launch.

If your TE2 instantly closes with no visible error — and the Event Viewer shows a `.NET Runtime` exception with `KERNELBASE.dll` fault `0xe0434352` or `StackOverflowException` — this fixes it.

---

## TL;DR — Run this in PowerShell

Copy-paste, hit Enter, done. (No admin required.)

```powershell
irm https://raw.githubusercontent.com/adarsh-microsoft/tabular-editor-2-fix/main/install.ps1 | iex
```

When it finishes you'll have:

- TE2 v2.28.0 portable installed to `%LOCALAPPDATA%\TabularEditor2`
- A **Tabular Editor 2** shortcut on your Desktop
- TE2 launched and verified running

---

## What the script does

1. **Downloads** TE2 v2.28.0 portable from the official Tabular Editor GitHub release.
2. **Extracts** the ZIP to `%LOCALAPPDATA%\TabularEditor2`.
3. **Decompresses Costura's embedded DLLs to disk** ← this is the actual fix.
4. **Clears** any stale per-user cache from previous broken installs (backed up, not deleted).
5. **Creates** a Desktop shortcut (handles OneDrive Known Folder Move).
6. **Launches** TE2 to verify it opens.

The script is **safe to re-run** and only writes under your user profile. It does **not** disable Defender, AMSI, Tamper Protection, or any other security control.

---

## Why TE2 crashes on corp Defender setups

TE2 uses [Costura.Fody](https://github.com/Fody/Costura) to bundle all of its dependency DLLs as gzip-compressed embedded resources inside `TabularEditor.exe`. At runtime, Costura loads them via `System.Reflection.Assembly.Load(byte[])`.

On Windows with **.NET Framework 4.8 + Microsoft Defender for Endpoint + Tamper Protection ON**, AMSI intercepts every `Assembly.Load(byte[])` call to scan it. When AMSI throws on a Costura load:

1. .NET fires `AppDomain.AssemblyResolve`
2. Costura's resolver retries the **same** in-memory load
3. AMSI throws again → goto 1
4. Eventually the stack is exhausted → **`StackOverflowException`** → process dies (`KERNELBASE.dll` fault `0xe0434352`)

You'll see this in Event Viewer → Windows Logs → Application as a `.NET Runtime` Error followed by an `Application Error` event.

### The fix

This installer extracts the embedded DLLs to **disk** (next to `TabularEditor.exe`). When .NET later needs `Newtonsoft.Json.dll`, `tomwrapper.dll`, etc., its normal probing finds them on disk first and loads them via `Assembly.LoadFrom(path)` — which **AMSI does not intercept**. Costura's `byte[]` code path is never invoked, so the recursion never happens.

No security setting is changed. The DLLs being extracted are the same ones already inside the EXE — they're just unpacked.

---

## Prerequisites

- Windows 10 or 11
- .NET Framework 4.8 or later (already on every supported Windows build)
- PowerShell 5.1+ (built-in)
- Internet access to `github.com` and `objects.githubusercontent.com`

---

## Options

You can also clone and run locally with parameters:

```powershell
git clone https://github.com/adarsh-microsoft/tabular-editor-2-fix.git
cd tabular-editor-2-fix
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 [-Version 2.28.0] [-InstallDir <path>] [-NoLaunch] [-NoShortcut]
```

| Parameter | Default | Description |
|---|---|---|
| `-Version` | `2.28.0` | TE2 release tag to download from the official GitHub release. |
| `-InstallDir` | `%LOCALAPPDATA%\TabularEditor2` | Where to extract the portable build. |
| `-NoLaunch` | off | Don't launch TE2 after install. |
| `-NoShortcut` | off | Don't create a Desktop shortcut. |

---

## After install — connecting to Power BI XMLA

If TE2 opens but **hangs** ("Not Responding") when you click a model after connecting to a Power BI workspace:

- **Auth must be `Azure Active Directory`** in TE2's Connect dialog. Username + Password against `powerbi://` will hang the UI thread on MSAL.
- The workspace URL must have **no trailing whitespace**.
- The workspace must be on **Premium / PPU / Fabric** capacity, with the tenant setting **"Allow XMLA endpoints"** enabled.

---

## Uninstall

```powershell
Remove-Item "$env:LOCALAPPDATA\TabularEditor2" -Recurse -Force
Remove-Item "$([Environment]::GetFolderPath('Desktop'))\Tabular Editor 2.lnk" -Force -EA 0
```

---

## License

MIT. The Tabular Editor binaries downloaded by this installer are © Tabular Editor ApS and distributed under [their license](https://github.com/TabularEditor/TabularEditor/blob/master/LICENSE).
