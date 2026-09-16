# H.E.D.Z. — Consolidated Diagnosis

Reference machine: **Windows 11 Home 24H2 (build 26100), x64**, HEDZ disc mounted
on **D:** (WinCDEmu, volume label `HEDZ`, CDFS). Companion docs: `README.md`
(reproduction guide), `TROUBLESHOOTING.md` (attempts + open issues).

---

## Issue 1 — setup.exe: "This app can't run on your PC"

**Root cause (proven, not assumed):** `D:\SETUP.EXE` (44,928 bytes), `D:\_SETUP.DLL`
(6,128 bytes) and `D:\_ISDEL.EXE` (8,192 bytes) are **16-bit NE-format
executables** — `MZ` DOS header with `NE` magic at the `e_lfanew` offset
(verified byte-for-byte by `tools\Verify-SetupExe.ps1` against the actual disc,
hex dump in its output). 64-bit Windows has no NTVDM and no WOW16 layer:
16-bit code cannot execute at all on x64, so Windows blocks the binary before
anything runs. This is an OS hard block, not corruption, not a manifest issue,
and not a disc problem. (`AUTORUN.EXE` and `ISDBGN.DLL` on the same disc are
32-bit PE and load fine — the failure is specific to the 16-bit stub set.)

The CD is a standard **InstallShield 5** layout: the 16-bit `SETUP.EXE` stub
unpacks/launches `_INST32I.EX_` (32-bit engine, © 1990–1995, LZS `2A AB`
signature) with `SETUP.INS` (compiled script). There is no pre-extracted
32-bit installer payload on the disc — the payload is generated at run time.

**Fix:** `tools\Install-Hedz.ps1` replicates the installer natively (copy
`D:\Hedz` → `C:\GAMES\HEDZ` minus `Music\`, write `InstalledFromDrive` +
`Language` into the **32-bit** registry view, register the uninstall entry).
No 16-bit code executes.
Alternative: run the original stub under **otvdm/winevdm** (documented,
README Task 0 Fix B). Legacy-VM payload extraction documented as Fix C but not
required.

---

## Issue 2 — Random crashes

Crash classes identified, each tied to a faulting module, with fixes applied
via wrapper configs + registry mitigations (full table and triage script in
README Task 1; automated matching in `tools\Get-HedzCrashLog.ps1`):

| Class | Faulting module | Root cause | Status |
|-------|-----------------|------------|--------|
| C1 | ddraw.dll | Surface lock/unlock + flip timing on modern drivers; 24H2 handle-leak regression (POLY14) | **Fixed** — pal-ddraw emulation layer absorbs lock/flip hazards; POLY14 mitigation applied via `Apply-HedzCompat.ps1`; DxWnd flags (`ForceSurfaceUnlock`, `SuppressBackbufferRelease`, `PartialFlipEmulation`) shipped in `tools\dxwnd\HEDZ.dxw` |
| C2 | TruePlay.dll | Privileged-instruction codec faulting in user mode on modern CPU/OS | **Worked around** — play `Movies\*.avi` externally, or rename `TruePlay.dll` → `.DISABLED` so the engine skips cutscenes. No binary patching. |
| C3 | Hedz.exe | Unhandled error when an expected CD file is missing on level load | **Not independent** — downstream of Issue 3; fixed by the correct CD mount + `InstalledFromDrive` = `"<LETTER>:"` (colon required) |
| C4 | ddraw.dll | Menu palette misrender / flicker | **Not independent** — downstream of Issue 4; fixed by palette emulation |
| C5 | ddraw.dll / DWM | Alt-tab crash from exclusive-mode restore | **Fixed** — run windowed (`Windowed=1`) via wrapper config |

Fix priority applied: Windows compat flags first (insufficient alone), then
DDrawCompat → **pal-ddraw (primary)** → DxWnd windowing on top with its own
DirectDraw emulation **off** → dgVoodoo2 only as substitute. Never two
DirectDraw wrappers simultaneously.

---

## Issue 3 — Music (.mus) never plays

**Root cause:** Not a codec problem and not a DirectSound problem — it is a
**CD-location problem first, middleware second**:

- **Layer A (location):** `.mus`/`.amb` live at `D:\Hedz\Music\` on the disc
  (7 streamed tracks 36–57 MB + `F.MUS`/`NETW.MUS` menu tracks) and are
  deliberately **not copied** by the original installer's full install —
  HEDZ streams them at runtime from the CD. The drive letter is **not** in an
  INI — this CD ships no `hedz.ini`, and Hedz.exe never reads one at all
  (verified: zero `.ini` strings in the binary, no `GetPrivateProfile*`
  imports): the game reads
  `HKLM\Software\Vis Interactive\Hedz` → **`InstalledFromDrive`**.
  Evidence for the value names: `D:\ENGLISH\SETUP.INS` (the real installer
  script) writes `Language`, `InstalledFromDrive` and `InstallType` under
  that key. Without the value the game logs
  `Registry Entry Not found, full protection` and demands the disc.

  **Two independent defects caused the persistent "insert the CD" prompt,**
  and both had to be fixed:

  a. *Wrong registry view* — an earlier import used 64-bit `reg.exe`, landing
     in `HKLM\SOFTWARE\Vis Interactive\Hedz`, while this 32-bit game reads
     `HKLM\SOFTWARE\WOW6432Node\...`. The value was invisible.
  b. *Missing colon in the value* — this was the decisive one. Disassembly of
     the path builder shows
     `strcpy(base, value); strcat(base, "\\Hedz\\"); driveLetter = base[0];`
     with no colon inserted anywhere. Storing `D` produced the **relative**
     path `D\Hedz\Music\1.MUS`, which Windows resolved against the game's own
     folder. A Process Monitor trace proved it:
     `CreateFile C:\Games\HEDZ\D\Hedz\Music\1.MUS -> PATH NOT FOUND`.
     Storing **`D:`** yields the correct absolute `D:\Hedz\Music\1.MUS`.

  Fixed with `tools\Set-HedzCdPath.ps1` (writes both views, value `D:`) and
  verified by trace: `D:\Hedz\test -> ACCESS DENIED` (correctly sees a
  write-protected CD) and `D:\Hedz\Music\1.mus` … `7.mus -> SUCCESS`.
- **Layer B (middleware):** once readable, playback goes through the **Miles
  Sound System** (`MSS32.DLL`/`MSS16.DLL`, shipped on-disc and copied by the
  installer). Music uses Miles's DSI file streaming — **not** DirectMusic —
  so no DirectMusic compat fix applies; SFX working confirms the DirectSound
  software layer is fine on Win11.

**Fix applied:** keep the original disc/image mounted (WinCDEmu on this
machine, `D:`), drive letter registered as `InstalledFromDrive` = **`D:`**
(colon included) in the 32-bit view via `tools\Set-HedzCdPath.ps1`, original
MSS DLLs in place. Fallback kit included but not needed: `tools\cdstub\` (winmm.dll
proxy that fakes MCI media-present/DRIVE_CDROM) only if a mount is ever
rejected by a medium-type check. Verification method: Process Monitor filter
`Hedz.exe` → expect continuous `D:\Hedz\Music\*.mus` reads while a mission
runs.

---

## Issue 4 — 16-color / low color-depth display requirement

**Root cause (proven by what the game requests):** HEDZ sets
**640×480×8 paletted** mode via DirectDraw (`SetDisplayMode` with 8 bpp +
`IDirectDrawPalette::SetEntries` animation for fades/color-cycling). The
"16-color" wording in community posts is a misnomer for this title. Windows
11 24H2 and modern GPU drivers expose **no** true sub-32-bit display modes,
and the compatibility checkbox "Reduced color mode" only spoofs the reported
depth from Win8 onward — the DWM still composites at 32 bpp — so direct
palette manipulation misrenders or faults.

**Fix:** software palette emulation at the DirectDraw layer via **pal-ddraw**
(`tools\pal-ddraw\ddraw.ini` pre-configured: 640×480 source, 8-bit paletted
surface emulated, 32-bit presented, windowed, aspect-correct, vsync). The
wrapper is the authoritative fix; Windows-side support from
`Apply-HedzCompat.ps1` makes the API surface honest (`Restore16BitDisplayMode`
per-exe layer, `Disable8BitAnd16BitDisplayModeToggle = 0` to undo 24H2's
block, POLY14 mitigation, optional true 640×480 4:3 bitmap-scaled desktop).
dgVoodoo2 documented as the substitute if pal-ddraw misbehaves on a specific
GPU — never stacked with it, and DxWnd (if used) sits on top with its own
DirectDraw emulation disabled.

**Cross-reference:** some "random" crashes from Issue 2 (C1 timing class and
C4 palette class) were downstream of this color-depth mismatch and the CD
location problem; fixing Issues 3 and 4 removes those crash classes rather
than them being independent bugs.

---

## Constraint compliance

- Original `Hedz.exe` and all game binaries unmodified — no byte patched.
  Only optional non-invasive change: renaming `TruePlay.dll` to disable it.
- No third-party middleware redistributed: kit ships configs/scripts/docs
  only; MSS/TruePlay DLLs come from the user's own CD; wrappers downloaded
  from official sources.
- One authoritative DirectDraw layer at a time; windowing tools layered on
  top only.
- Disc imaging/mounting scoped as personal-backup/compatibility use of owned
  media.
