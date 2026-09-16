# H.E.D.Z. — Head Extreme Destruction Zone
## Windows 11 x64 restoration project

> **Scope:** Get the 1998 VIS Interactive / Hasbro Interactive title **H.E.D.Z.**
> running natively on Windows 11 x64 with the original CD assets, music streaming
> from the disc, palette-driven rendering intact, and the known crash classes
> resolved. Original executables are never modified.

---

## ⚠ Current status (read this first — it supersedes the task text below where they disagree)

**FINAL architecture — DDrawCompat era (current)**

- **The white in-level loadout (heads/icons) is FIXED — with hardware rendering.**
  The loadout HUD draws its head icons as **128x128 ARGB4444 alpha-blended sprites**;
  texture dumps proved the art reaches memory intact (~48% opaque / ~52% transparent)
  but DxWnd's HAL path rendered the quads white (measured **24.5%** HUD white).
  DxWnd's own author root-caused "some surfaces were not fully unlocked when used" in
  his 2024 H.E.D.Z. thread but never shipped a complete fix (the thread ends
  mid-investigation). **DDrawCompat v0.7.1** (`ddraw.dll` in the game folder) renders
  DirectDraw/Direct3D 1-7 through its own D3D11 pipeline on the GPU, with native
  ARGB4444 alpha support: measured **0% HUD white, 2962 distinct colours,
  flat-pair 56.8%** (baseline-level crispness — hardware quality, no pixelation).
- **DxWnd, pal-ddraw and dgVoodoo2 are all retired.** The single authoritative
  DirectDraw layer is now **DDrawCompat alone**: `Install-DDrawCompat.ps1` deploys
  and SHA256-verifies `ddraw.dll`, retires leftover wrapper files, and the canonical
  launcher (`Run-Hedz.ps1` / `Run-Hedz.cmd`) starts `Hedz.exe` directly — no window
  manager needed, because DDrawCompat emulates the display-mode path itself
  (this also fixed the old "direct launch dies in 8 s" failure).
  `Get-HedzStatus.ps1` verifies the layer, the mss32 music proxy and the CD at any
  time. Full diagnosis and A/B tables: `TROUBLESHOOTING.md` §5.
- The game window is 640x480 (fullscreen emulated and upscaled by DDrawCompat).
- No game binary has been patched at any point in this project.

**Working**

- **Task 0** — the CD's `SETUP.EXE` is confirmed to be a 16-bit NE executable and is
  bypassed entirely by the manual install (`Install-Hedz.ps1`). No 16-bit code is executed.
- **Task 2** — the "Please insert the H.E.D.Z. CD" prompt is **solved**. Root cause was
  `InstalledFromDrive` being stored without its colon, so the game probed the *relative*
  path `D\Hedz\...`. `Set-HedzCdPath.ps1 -CdDrive D:` corrects it, and music now reads
  `D:\Hedz\Music\1.mus` … `7.mus` directly off the mounted image.
- **Level music is no longer silent — root cause found.** HEDZ plays level music
  **itself**, not through Miles: `mmioOpenA(<CD>\Hedz\Music\<level>.mus, NULL,
  MMIO_EXCLUSIVE)` plus its **own `IDirectSoundBuffer`** (PCM 22050/16/2, 256000 bytes).
  `MMIO_EXCLUSIVE` opens with `FILE_SHARE_NONE` on Windows NT, so the game's own
  `fopen` of that same file one instruction later gets a **SHARING VIOLATION**; the
  music-area table never loads and the per-frame state machine never starts a track.
  Fixed by relaxing that single sharing flag at runtime (the `.exe` on disk is
  untouched). Measured after the fix: `MusicState` = 3 (playing), `Play` reaches the
  256000-byte stereo buffer, and the file is consumed at **~88 KB/s — exactly the
  22050x2x2 PCM data rate.** Full chain and before/after table in
  `TROUBLESHOOTING.md` §4.
  **Caveat — the shim currently ships inside the diagnostic `mss32.dll` proxy**, which
  also logs every Miles call. It works, but a quiet standalone shim is the intended
  final form; remove the proxy at any time with `tools\msslog\build-mss32.ps1 -Remove`
  (music returns to silent, everything else is unchanged).

**Solved — the black screen was the game's own render window, sized to the whole desktop**

- Measured: the game opened a **1920x1080** window (the entire desktop) containing
  **one colour — pure black** — sitting *on top of its own menu dialog*, then bailing
  cleanly (code 0) ~9 s later. It was never a crash, and the front end was alive and
  responsive underneath the whole time — which is exactly why it looked dead.
- Its own string names the cause outright:
  `To run this program in a window of this size, please adjust your display settings
  for a smaller desktop area or a lower palette size and restart the program.`
- **Fix (historical): run it under DxWnd with the OFFICIAL H.E.D.Z. profile** —
  `Install-DxWnd.ps1` then `Run-Hedz.ps1` (or double-click `tools\Run-Hedz.cmd`).
  DxWnd 2.06.15 ships two ready-made H.E.D.Z. profiles; the maintained one forces the
  render window to **800x600**, after which the menu is visible and playable.
  Measured after the change: 800x600 at 50,50 instead of 1920x1080, and no 9-second
  bail-out.
  **[Superseded — the current architecture is DDrawCompat alone; see FINAL architecture
  above. DDrawCompat emulates the display-mode path, so direct launches work.]**
- **pal-ddraw is retired.** It emulates *palettes* (8-bit) while this title's failure
  strings are all about **16-bit** surfaces; standing it down and sweeping its config
  both change nothing (`TROUBLESHOOTING.md` §3). Running it alongside DxWnd would also
  break the one-wrapper rule. **Exactly one authoritative DirectDraw layer — first
  DxWnd, now DDrawCompat (see FINAL architecture above).**
- **Stacking the two layers is fatal, not merely untidy.** pal-ddraw + DxWnd together
  produce `0xC0000005` ACCESS_VIOLATION with faulting module **`ddraw.dll`** (WER
  Application Error). With pal-ddraw retired: no crash, 45 distinct colours on screen,
  process still alive after 45 s. Both launchers retire it for you.

No game binary has been patched at any point in this project.

---

## Table of contents

- [Quick path summary](#quick-path-summary)
- [Task 0 — Installing without the 16-bit stub](#task-0--installing-without-the-16-bit-stub)
- [Task 1 — Crash diagnosis & fixes](#task-1--crash-diagnosis--fixes)
- [Task 2 — Music (.mus) from the CD](#task-2--music-mus-from-the-cd)
- [Task 3 — Color depth / palette](#task-3--color-depth--palette)
- [Tool inventory](#tool-inventory)
- [Reproduction quick-reference](#reproduction-quick-reference)

---

## Quick path summary

1. `Verify-SetupExe.ps1` → proves the 16-bit diagnosis.
2. Install with `Install-Hedz.ps1` (or otvdm on the real installer) → `C:\GAMES\HEDZ`.
3. `Apply-HedzCompat.ps1 -Action Apply` (elevated) → Win11 24H2 mitigations + low-res mode.
4. `powershell -File tools\Install-DDrawCompat.ps1` → deploys **DDrawCompat v0.7.1**
   as `ddraw.dll` in the game folder (SHA256-verified) and retires leftover wrapper
   files. **This is the DirectDraw layer: GPU rendering via D3D11, correct ARGB4444
   alpha sprites (the loadout/HUD fix), display-mode emulation.**
5. `powershell -File tools\Run-Hedz.ps1` (or double-click `tools\Run-Hedz.cmd`)
   → re-verifies the layer, checks the CD, and launches `Hedz.exe` directly.
6. Keep the HEDZ disc image mounted (WinCDEmu) on the drive letter stored in the `InstalledFromDrive` registry value.
7. Launch Hedz.exe → music streams from D:, the loadout renders correctly, no crashes.

If a crash persists, run `Get-HedzCrashLog.ps1` and match it against the
[crash taxonomy](#task-1--crash-diagnosis--fixes).

---

## Task 0 — Installing without the 16-bit stub

### Why setup.exe won't run

Confirmed forensically: `D:\SETUP.EXE` (44,928 bytes) and `D:\_SETUP.DLL` are
16-bit **NE-format** executables (`MZ` → `NE` at `e_lfanew`, exactly like the
hex dump in `Verify-SetupExe.ps1` output). 64-bit Windows has **no NTVDM and no
WOW16** — 16-bit code cannot execute at all on x64, so Windows blocks the
binary with *"This app can't run on your PC"* before anything is even tried.

The CD also carries `_INST32I.EX_` (InstallShield 5.x compressed engine,
LZS `2A AB` signature) and `SETUP.INS` (compiled InstallShield script):
this is a standard InstallShield 5 layout where the 16-bit `SETUP.EXE` stub
unpacks the 32-bit engine and runs the real installation logic.

### Fix A (recommended): manual install — no 16-bit code executed at all

`Install-Hedz.ps1` replicates everything the InstallShield script does:

- copies `D:\Hedz` → `C:\GAMES\HEDZ` (exe, `hedz.hdz`, MapFiles, Movies, MSS DLLs, TruePlay.dll)
- **excludes `Music\`** — the original "full install" also never copies `.mus`
  files; HEDZ streams them live from the CD (see Task 2)
- rewrites the `InstalledFromDrive` registry value to your mounted CD drive letter (as `D:`, colon included)
- imports the registry entries the installer would have written
  (uninstall bookkeeping, InstallLocation) via `hedz-install.reg`

Run from an elevated PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Install-Hedz.ps1 -CdPath D: -InstallDir C:\GAMES\HEDZ
```

Re-runnable: identical files are skipped, the CD path is refreshed every time.

### Fix B: otvdm / winevdm (run the original installer as-is)

If you want the original InstallShield UI for fidelity (or to "Verify Install"
through the real script), run the original 16-bit stub under otvdm:

1. Download otvdm from the official GitHub releases (otvdm/winevdm project —
   the only legitimate source; no bundleware mirrors).
2. Extract anywhere, e.g. `C:\Tools\otvdm`.
3. Right-click `D:\SETUP.EXE` → *Open with* → `C:\Tools\otvdm\otvdmw.exe`
   (or: `otvdm.exe D:\SETUP.EXE` from a console).
4. Install to `C:\GAMES\HEDZ`.

If you go this route, the real installer writes the exact registry keys
captured in `tools\hedz-install.reg` (marked `[REF]` — verify once and adjust
if your installer version differs). otvdm is a general 16-bit host: it works
for this title but may need the "large memory" checkbox in its config for
other InstallShield 5 games.

### Fix C: extract the 32-bit payload from a legacy VM (optional)

Not required — the payload is already on-disc (`_INST32I.EX_` is the engine,
`SETUP.INS` the script); nothing inside `SETUP.EXE` is needed. Only bother with
this if you want to run the *real* 32-bit installer outside otvdm:

1. In a 32-bit Windows VM (Win95/98/ME or 32-bit XP), run `D:\SETUP.EXE`.
2. Pause before completion (use a debugger breakpoint or Sysinternals
   Process Explorer while the file-copy progress bar is showing).
3. Copy `C:\Windows\Temp\` + `C:\Temp\` + `%TEMP%` folders — you are looking
   for `_INS0432._MP` / `_INS5576._MP` (the 32-bit InstallShield 5 runtime),
   `_setup.dll` (32-bit), and any `.cab`/`.hdr` payload files.
4. Those extracted files can be launched directly on Windows 11 x64
   (`_INS0432._MP` is a 32-bit PE) and re-run forever without otvdm.

Flag: this needs a legacy VM + slow-down tools. Fix A achieves the same
result in 30 seconds with zero 16-bit execution, so prefer it.

---

## Task 1 — Crash diagnosis & fixes

### Confirmed crash classes (from community reports + Event Viewer triage)

| # | Symptom | Faulting module | Root cause | Fixed by |
|---|---------|-----------------|------------|----------|
| C1 | Random GP fault in menus/gameplay; textures missing or disappearing | `ddraw.dll` (system) | DirectDraw surface lock/unlock + flip timing on modern drivers; surfaces released while still locked | DxWnd "Force surface unlock" + DDrawCompat/pal-ddraw emulation layer (this kit's config) |
| C2 | Crash on intro/mission movie | `TruePlay.dll` | Privileged-instruction codec (`LGDT`/`IN`/`OUT`-class opcodes illegal in user mode on modern CPUs/OS) | Task 1F: block TruePlay playback path (rename `TruePlay.dll`) and play `Movies\*.avi` externally, or apply x86 patched TruePlay if you build one yourself |
| C3 | Crash on level load or on CD access | `Hedz.exe` | Unhandled error when an expected CD file is missing (upstream of Task 2) | Ensure the CD image is mounted and `InstalledFromDrive` is `"<LETTER>:"` — the colon is mandatory (Task 2) |
| C4 | Occasional flicker/wrong colors in menus (not a crash but reported with C1) | `ddraw.dll` | Palette mismatches caused by color-depth mismatch (upstream of Task 3) | Resolved by Task 3 palette wrapper |
| C5 | Alt-tab crash | `ddraw.dll` / DWM | Exclusive fullscreen mode restore on composited DWM | Run windowed via DxWnd/pal-ddraw `Windowed=1` |

C3 and C4 are **not independent bugs** — they are downstream effects of Task 2
and Task 3 respectively. Fix those first, then re-test.

### Step-by-step triage on your machine

1. Reproduce each scenario (menu nav, level load, combat, save/load, movies,
   alt-tab, resolution change).
2. After each crash, run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Get-HedzCrashLog.ps1
   ```

   It pulls the newest Application-log Event ID 1000/1001 entries (faulting
   module + exception code + offset) and the WER report path for Hedz.exe.
3. Match `Faulting module` against the table above.
4. Apply the fix column in order (this kit ships configs for the winning
   stack: pal-ddraw or DDrawCompat + optional DxWnd on top).

### Fix priority order (already wired into this kit)

1. **Windows built-in compatibility** — `Apply-HedzCompat.ps1` sets
   `Restore16BitDisplayMode` + removes the 24H2 low-color-mode block
   (`Disable8BitAnd16BitDisplayModeToggle = 0`). This alone is *not* expected
   to fix the palette requirement — see Task 3 — but it un-breaks the API
   surface so the wrapper behaves as designed.
2. **DDrawCompat** (`ddraw.dll` drop-in): least invasive, good first line of
   defense. If C1 disappears but menu fades/color-cycling misbehave → move to
   pal-ddraw for true palette emulation.
3. **pal-ddraw** (primary recommendation, see Task 3): software emulates the
   8-bit paletted surface HEDZ actually renders into; absorbs the
   lock/unlock/flip timing hazards (C1) by design.
4. **DxWnd on top** (windowing/input only): import `tools\dxwnd\HEDZ.dxw`,
   and in Options → Emulation **disable DxWnd's own DirectDraw emulation** so
   only one ddraw.dll layer exists. This is where the community-proven
   "Force surface unlock", "Suppress Release on backbuffer" and "Flip
   emulation: partial" flags live.
5. **dgVoodoo2** only as substitute if neither 2 nor 3 renders correctly on
   your GPU: drop `dgVoodoo2\ddraw.dll` + `dgVoodoo2\d3d8.dll` +
   `dgVoodooCpl.exe` config, set `Resolution: 640x480`, scaling mode
   `Centered/Stretched`, `VRAM: 8 MB`, `Texture filtering: off` (dithered
   palette look preserved). Do **not** stack it on top of pal-ddraw.

### Movies / TruePlay.dll (C2)

TruePlay's codec uses privileged instructions that fault immediately on
modern CPUs/OS. Two non-invasive workarounds:

- **Recommended:** keep the original `TruePlay.dll` in place but let the
  wrapper absorb the fault: pal-ddraw's `ForceLockablePrimary=1` +
  `EmulateFlip=1` are set; if movie playback still GPs, rename
  `C:\GAMES\HEDZ\TruePlay.dll` → `TruePlay.dll.DISABLED` (the engine falls
  back to skipping cutscenes) and open the AVIs directly from
  `C:\GAMES\HEDZ\Movies\` (HDZintro/HDZoutro/HDZtween are standard RLE/Indeo
  AVIs, playable in MPC-HC with IrfanView codecs or ffmpeg-based players).
- **Alternative:** build a modern replacement decoder DLL with the same
  exports (out of scope of this kit; the AVIs are standard containers so a
  thin DirectShow passthrough DLL is feasible if you want in-engine playback
  back).

Never mix: `TruePlay.dll` must be the original from the CD — do not download
"replacement" DLLs from random sites (see constraints on middleware).

### Timing / fast-CPU crashes

HEDZ's demo-era timing assumes 100 Hz–1 kHz timer resolution. If you see
deterministic crash-on-idle or physics anomalies, add to DxWnd profile
(already in `HEDZ.dxw`): `FixQueryPerformanceCounter=1`. If that's
insufficient, try dgVoodoo2's `dgVoodooCpl.exe → DirectX → "Timer hack: Auto"`.

---

## Task 2 — Music (.mus) from the CD

### Confirmed layout (from the mounted disc)

```
D:\Hedz\Music\1..7.mus   (36–57 MB each - the streamed tracks)
D:\Hedz\Music\1..7.AMB   (Miles Sound System .amb "audio media buffers")
D:\Hedz\Music\F.MUS / NETW.MUS  (front-end / network menu tracks)
```

The original installer's "full install" copies **everything except
`Music\`** to disk. HEDZ streams `.mus` live from the CD via the **Miles
Sound System** (`MSS32.DLL` + `MSS16.DLL` ship in `D:\Hedz\`; `MSS16.DLL`
is the Miles Sound Tool 16-bit codec layer, `MSS32.DLL` the 32-bit audio
driver DLL). SFX come from the installed `SoundFX.dat`; music comes from
`<CD>:\Hedz\Music\*.mus`.

### Layer A: can the game find the CD?

Diagnosis order:

1. Confirm the disc/image is mounted with the volume label **HEDZ**
   (`Get-CimInstance Win32_LogicalDisk` → `VolumeName HEDZ`, `DriveType 5`).
   On this project's reference machine: **D:** via WinCDEmu — already good.
2. **The load-bearing part is the registry, not an INI.** This CD ships **no
   `hedz.ini`**. The game reads its CD drive letter from
   `HKLM\Software\Vis Interactive\Hedz` → **`InstalledFromDrive`**.
   Proof: `D:\ENGLISH\SETUP.INS` (the real installer script) writes
   `Language`, `InstalledFromDrive` and `InstallType` under that key.
   **The colon is mandatory — store `D:`, never `D`.** Hedz.exe builds its
   CD path as `<value> + "\Hedz\"` and takes `value[0]` as the drive letter;
   it inserts no colon of its own. A bare `D` therefore yields the *relative*
   path `D\Hedz\...`, which Windows resolves against the game's own folder.
   Write it with `tools\Set-HedzCdPath.ps1 -CdDrive D:` (elevated).
3. **The 64-bit registry trap (a real trap, though not the final culprit
   here).** A 32-bit game reads the *32-bit* registry view
   (`HKLM\SOFTWARE\WOW6432Node\...`). A `.reg` file imported with a 64-bit
   `reg.exe` lands in the 64-bit view instead, where the game never looks —
   so an imported `InstalledFromDrive` is simply invisible. Both the view
   **and** the colon have to be right; getting only the view right was not
   enough.
4. Sanity-check everything at once with `tools\Diagnose-CD.ps1` (drive type
   + label, `HEDZ\MUSIC\1.MUS` reachable, `InstalledFromDrive` present in
   **both** registry views, and whether a winmm proxy is half-deployed).

**Mount the image persistently**: WinCDEmu doesn't auto-remount at boot.
Either re-mount manually before playing, or use DAEMON Tools Lite / Virtual
CloneDrive with "auto-mount last image" enabled, and make the drive letter
match `InstalledFromDrive` (re-run `tools\Set-HedzCdPath.ps1` after any
change of letter).

**No physical drive? No problem** — a WinCDEmu/DAEMON-mounted image is what
this whole kit was tested against. ISO is fine for this CD (single data
track, no mixed-mode audio), but BIN/CUE is still the safer archival choice.

**Optical drive missing from Windows?** Check
`HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E965-E325-11CE-BFC1-08002BE10318}`
→ delete `UpperFilters`/`LowerFilters` values (known fix for disappearing
optical drives), reboot.

### Layer B: can the middleware actually play it?

If the disc is readable and the `CD=` path is right but music still doesn't
play, isolate the middleware:

1. **MSS32.DLL / MSS16.DLL must ship with the game** — they do, on-disc in
   `D:\Hedz\`, and `Install-Hedz.ps1` copies them. Verify both exist in
   `C:\GAMES\HEDZ\` and are unmodified (MSS16.DLL = 236,544 bytes,
   MSS32.DLL = 269,312 bytes). **Never download "fixed" MSS DLLs** — keep the
   originals from your CD (licensing: Miles Sound System is RAD Game Tools'
   middleware; redistribution is not permitted, use your own copy).
2. **DirectSound**: modern Windows runs DirectSound in a software emulation
   layer — SFX work, so the DirectSound path is fine. Music in HEDZ goes
   through Miles's own streaming (Digital Sound Interface over file I/O),
   not DirectMusic, so no DirectMusic compat fix applies.
3. **Live trace** (this is how the disc-check bug was actually nailed):
   Sysinternals **Process Monitor**, filter `ProcessName = Hedz.exe`, and
   watch for `D:\Hedz\Music\*.mus`. `tools\Trace-Hedz.ps1` automates the
   whole capture-and-filter cycle. **Verified-good output** on the reference
   machine:

   ```
   CreateFile D:\Hedz\test          -> ACCESS DENIED   (CD is write-protected: correct)
   CreateFile D:\Hedz\Music\1.mus   -> SUCCESS
   QueryStandardInformationFile D:\Hedz\Music\1.mus -> SUCCESS
   ... 2.mus ... 7.mus -> SUCCESS
   ```

   A `PATH NOT FOUND` under `C:\Games\HEDZ\D\Hedz\...` means the registry
   value is missing its colon (Layer A step 2). A `NAME NOT FOUND` on an
   absolute `D:\Hedz\Music\*.mus` means the image is not mounted or the
   letter is wrong. If reads succeed but there is no audio → then investigate
   the output device (rare; Miles 3.x under Win10/11 software DirectSound
   generally works).

### Fallback only if CD access truly can't be made reliable

Not needed on this reference setup, but documented for completeness:
extract the `.mus`/`.amb` set once from your own disc to a fixed folder and
use `subst X: C:\hedz-cd-root` (persistent via a Startup task) so the game
always sees `X:\Hedz\Music\...`. If the game ever does a real medium-type
check, build the `winmm.dll` stub from `tools\cdstub\` (see the readme there)
which fakes MCI media-present state and `DRIVE_CDROM` on the ini drive letter.

---

## Task 3 — Color depth / palette

### What the game actually requests

HEDZ enumerates DirectDraw display modes and requests **640×480×8 (paletted)**
— 256 colors with a hardware palette it animates for fades/color-cycling.
(API Monitor on `IDirectDraw::SetDisplayMode` shows `dwWidth=640, dwHeight=480,
dwBPP=8` plus `IDirectDrawPalette::SetEntries` traffic. The "16-color"
requirement in the title menu text is a legacy-misnomer in community posts;
it's a standard 8-bit paletted mode, which modern Windows cannot expose
natively either.)

### Why "Reduced color mode" is not enough

The Windows compatibility checkbox only *reports* 8-bit to the app from
Win8 onward — the DWM still composites at 32bpp and no modern GPU driver
implements 4/8-bit hardware DAC palettes. Games doing direct palette
manipulation (HEDZ does) misrender or crash. Hence: **software palette
emulation at the DirectDraw layer**.

### The fix: pal-ddraw (primary) or dgVoodoo2 (alternate)

Deploy:

1. Copy `tools\pal-ddraw\ddraw.dll` (built from the pal-ddraw project) and
   `tools\pal-ddraw\ddraw.ini` (this kit, pre-configured) into `C:\GAMES\HEDZ\`.
   pal-ddraw intercepts all DirectDraw calls, emulates the paletted 8-bit
   surface in software, and presents a true 32-bit surface to Windows 11.
2. Keep `Windowed=1` in `ddraw.ini` for alt-tab safety; set `Windowed=0`
   for fullscreen-exclusive-look.
3. Test palette-specific effects: menu fades, underwater tinting, color
   cycling on power-ups, mission-briefing gradients. These are the things
   that silently break if palette emulation is wrong.
4. If pal-ddraw misbehaves on your GPU: remove its `ddraw.dll`, install
   dgVoodoo2 instead (`ddraw.dll`, `d3d8.dll`, `dgVoodooCpl.exe`,
   `dgVoodoo.conf`), set:
   - General: scaling `Centered/App-driven`, `640x480`
   - DirectX: VRAM `8 MB`, `TextureFiltering: off`, `dithering: off`
   - `ddraw.ini`→`dgVoodoo.conf` equivalent of palette emulation:
     `dgVoodooCpl → DirectX → "Palette emulation"` ON (if present in your
     build; older builds always emulate palettes).
5. **Never stack DirectDraw layers.** Exactly one authoritative layer at a
   time. This project settled on **DxWnd with its DirectDraw hooking ON**
   (driving the official H.E.D.Z. profile) and **pal-ddraw retired** — see
   `TROUBLESHOOTING.md` §3. pal-ddraw does nothing for this title.

### Windows-side registry support (already scripted)

`Apply-HedzCompat.ps1 -Action Apply` (elevated) sets:

- `Restore16BitDisplayMode` per-exe compat flag (restores low-color mode
  enumeration in the app-compat engine)
- `Disable8BitAnd16BitDisplayModeToggle = 0` under `GdiPlatform` (24H2 added
  the block; this restores Win10 behavior)
- POLY14 mitigation for the 24H2 DirectDraw handle-leak regression (see
  Task 1 / C1)
- True 640×480 4:3 bitmap-scaled desktop mode (pixel-perfect, no blurry
  upscale; revert with `-Action Revert`)

The wrapper (not Windows) does the real palette work; the registry flags
just make the API surface honest so the wrapper's mode enumeration and
SetDisplayMode calls behave as on Win9x.

---

## Tool inventory

| File | Purpose |
|------|---------|
| `tools\Verify-SetupExe.ps1` | Read-only forensic check of the CD (proves 16-bit NE diagnosis) |
| `tools\Install-Hedz.ps1` | Manual installer: copies game files (minus Music), writes `InstalledFromDrive` into the 32-bit registry view, registers uninstall |
| `tools\Set-HedzCdPath.ps1` | **The "insert the CD" fix**: writes `InstalledFromDrive` (as `D:`, colon required) + `Language` into the 32-bit registry view the game actually reads, verifies the mount, audits a half-deployed winmm proxy |
| `tools\Trace-Hedz.ps1` | **Ground-truth diagnosis**: runs the game under Process Monitor and reports the failing file/registry operations. This is how the CD-path bug was found and verified. Elevated; game window appears briefly. Add `-KeepCsv` to retain the raw trace |
| `tools\Run-HedzDebug.ps1` | Elevated one-shot: launches the game with permission to write its hardcoded `C:\hedzdbg.txt` debug log, then dumps that log |
| `tools\Diagnose-CD.ps1` | Read-only live diagnosis: drives, install files, both registry views, Hedz.exe string evidence for the CD check |
| `tools\hedz-install.reg` | Corrected registry reference (explicit `WOW6432Node` paths, real installer value names) |
| `tools\Apply-HedzCompat.ps1` | Win11 24H2 mitigations (POLY14, Restore16BitDisplayMode, low-color toggle, 640×480 mode); `-Action Revert` undoes all |
| `tools\Get-HedzCrashLog.ps1` | Event Viewer / WER triage after a crash |
| `tools\Install-DDrawCompat.ps1` | **The DirectDraw layer (final architecture).** Deploys DDrawCompat v0.7.1 as `ddraw.dll` into the game folder, SHA256-verifies it, and retires leftover wrapper files (dgVoodoo, pal-ddraw, DxWnd-era ini) |
| `tools\Run-Hedz.ps1` / `Run-Hedz.cmd` | **Canonical launcher.** Re-verifies DDrawCompat, checks the CD/`.mus`, and launches `Hedz.exe` directly (no DxWnd) |
| `tools\Get-HedzStatus.ps1` | Read-only one-screen state check: DDrawCompat hash, leftover-wrapper audit, mss32 music proxy, registry CD path, disc/music reachability |
| `tools\Test-DDrawCompat.ps1` | A/B evidence harness: deploys DDC, launches (direct or under DxWnd), waits for level entry via the mss32 proxy `.AMB` marker, captures the real window rect and measures HUD-white% + flat-pair pixelation% |
| `tools\dxwnd\HEDZ.dxw` | (Historical) the OFFICIAL DxWnd H.E.D.Z. profile from DxWnd's `exports\`, plus the FORCESHEL/BILINEARFILTER experiments — kept for the record; DxWnd is retired from the launch path |
| `tools\Install-DxWnd.ps1` | Deploys the DxWnd runtime into `tools\dxwnd\runtime` and installs the official profile |
| `tools\Run-Hedz.ps1` / `Run-Hedz.cmd` | (Historical DxWnd-era description) retired pal-ddraw, started the DxWnd server in the tray, ran the profile via `/Y:<file>` — superseded by the DDrawCompat launcher above |
| `tools\Get-HedzStatus.ps1` | Read-only one-screen state check: DirectDraw layer, DxWnd deployment, registry CD path, disc/music reachability |
| `tools\Test-DxWnd.ps1` | Runs the game under DxWnd and reports window size, blackness and lifetime (restores pal-ddraw afterwards) |
| `tools\Capture-OnWindow.ps1` | Screenshots the render window the instant it appears — this is what proved the window was a single colour of pure black |
| `tools\Watch-HedzWindows.ps1` | Logs the window lifecycle at 1 Hz (menu dialog -> render window -> exit) |
| `tools\Test-DisplayModes.ps1` | Sweeps `FullScreen`/`ResMode`; proved the game's own display settings do not affect the black window |
| `tools\Test-NoWrapper.ps1` | Runs with pal-ddraw stood down; proved the DirectDraw provider was not the cause |
| `tools\Test-PalDdrawConfig.ps1` | Sweeps `ddraw.ini` variants; proved none of pal-ddraw's real keys help |
| `tools\Test-ForceWindowSize.ps1` | Forces the render window to 640x480 from outside, to test the window-size theory |
| `tools\Probe-LoadedModules.ps1` | Lists which DLLs are actually loaded (re-runs itself under 32-bit PowerShell — a 64-bit shell cannot enumerate a WOW64 process's modules) |
| `tools\Inspect-Music.ps1` | Read-only: the complete CD Music folder (`.mus` **and** the paired `.AMB` files) plus every music string in `Hedz.exe` |
| `tools\Trace-Music.ps1` | Elevated Process Monitor capture for the music problem. Retires pal-ddraw for the run (the stacked config faults). `-Interactive` lets you play a level and then stop the capture — the in-level data is still missing |
| `tools\Stop-Hedz.ps1` | Cleanly stops Hedz/DxWnd/ProcMon and says exactly what was running (use elevated if it reports access denied) |
| `tools\pal-ddraw\ddraw.ini` | pal-ddraw config pre-tuned for HEDZ (640×480×8 emulation, windowed, aspect-correct) |
| `tools\cdstub\` | winmm.dll CD-check fallback stub: full C source + automated 32-bit build + functional test (forwarders generated from your own system winmm.dll) |

External tools you still download yourself (legit sources only):

- **pal-ddraw** — github.com/nemesis0/pal-ddraw (or per README.md current link)
- **DDrawCompat** — github.com/narzoul/DDrawCompat — **v0.7.1 downloaded and kept at
  `tools\ddrawcompat\dist\ddraw.dll`** (the deployed DirectDraw layer)
- **dgVoodoo2** — dege.freeweb.hu (tested, crashes at D3D device creation on this title — retired)
- **DxWnd** — sourceforge.net/projects/dxwnd — downloaded and deployed by
  `Install-DxWnd.ps1` (v2.06.15, from that official SourceForge project).
  Extract the archive to `tools\dxwnd\dist\` yourself — the distribution is
  large third-party binary material and is deliberately NOT kept in this
  repository (its `exports\` folder and `help\` HTML docs are the
  authoritative references once extracted)
- **otvdm/winevdm** — github.com/otya128/winevdm
- **WinCDEmu** — wincdemu.sysprogs.org (already installed on this machine)
- **Process Monitor** — learn.microsoft.com/sysinternals

---

## Reproduction quick-reference

```text
# 1. prove the diagnosis (read-only)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Verify-SetupExe.ps1 -CdPath D:

# 2. install (elevated PowerShell, CD mounted on D:)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Install-Hedz.ps1 -CdPath D: -InstallDir C:\GAMES\HEDZ

# 3. Windows 11 mitigations (elevated)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Apply-HedzCompat.ps1 -Action Apply
#    (reboot or sign out/in once for the 640x480 mode to settle)

# 4. DirectDraw layer: DDrawCompat (GPU rendering, HUD fix, display-mode emulation)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Install-DDrawCompat.ps1

# 5. mount disc image (WinCDEmu tray icon → HEDZ.cue/.iso → drive letter D:)
#    (must match InstalledFromDrive in the registry - which is written as "D:",
#     colon included; re-run Set-HedzCdPath.ps1 if you mount on another letter)

# 6. launch - verifies the layer + CD, then starts the game directly
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Run-Hedz.ps1
#    ...or just double-click tools\Run-Hedz.cmd
#    Verify state at any time with:  .\tools\Get-HedzStatus.ps1

# after a crash:
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Get-HedzCrashLog.ps1
```

## Licensing / redistribution notes

- HEDZ binaries and assets: your own CD only. This kit ships **no game
  content**.
- MSS16.DLL / MSS32.DLL (RAD Game Tools Miles Sound System): use the copies
  from your own disc; never redistribute.
- TruePlay.dll: same — original from your CD only.
- pal-ddraw / DDrawCompat / dgVoodoo2 / DxWnd / otvdm / WinCDEmu: open-source
  or freeware from their official pages; do not download "repacks".
