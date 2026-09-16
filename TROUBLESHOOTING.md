# H.E.D.Z. — Troubleshooting appendix

Companion to `README.md`. Records what was tried, what worked, what did not,
and what remains open on this specific reference machine (Windows 11 Home
24H2 build 26100, x64, HEDZ disc mounted on `D:` via WinCDEmu, volume label
`HEDZ`).

---

## 1. What was tried, by task

### Task 0 — Installer blocked ("This app can't run on your PC")

| Attempt | Result |
|---------|--------|
| Hex-dump forensics of `D:\SETUP.EXE`, `D:\_SETUP.DLL`, `D:\AUTORUN.EXE` (`Verify-SetupExe.ps1`) | **Confirmed 16-bit NE executables** (`MZ` + `NE` at `e_lfanew`). Diagnosis proven, not assumed. |
| Layout check | Standard InstallShield 5: `_INST32I.EX_` (LZS `2A AB` engine, © 1990–1995) + `SETUP.INS` + `_SETUP.DLL`. No 32-bit installer payload exists on the CD outside the stub. |
| Manual install path (`Install-Hedz.ps1`) | **Works.** Mirrors the installer's footprint (copy `D:\Hedz` minus `Music\`, write `InstalledFromDrive` + `Language` into the **32-bit** registry view, register the uninstall entry). No 16-bit code executed. Recommended default. |
| otvdm / winevdm route | **Viable** (documented in README Task 0 Fix B) for running the genuine installer UI; requires downloading otvdm from its official GitHub. Not needed for a clean install. |
| Legacy-VM payload extraction | Documented (README Task 0 Fix C) but **not required** — everything the installer needs is already on-disc; only `_INS0432._MP`-style extraction adds convenience for future installs. |

### Task 2 — `.mus` music files

| Attempt | Result |
|---------|--------|
| Disc layout inspection | `.mus`/`.amb` confirmed at `D:\Hedz\Music\` (7 tracks 36–57 MB + `F.MUS`, `NETW.MUS`; `.amb` = Miles Sound System metadata). Install copy excludes them by design. |
| Install strategy | Music stays on CD (there is **no `hedz.ini`** on this disc — an earlier revision of these notes invented one). The CD location lives in the registry as `InstalledFromDrive`; HEDZ then streams via Miles Sound System from `<CD>\Hedz\Music\`. **This is the load-bearing part of the fix.** |
| Mount technology | Windows-native ISO mount *not* used; **WinCDEmu** (already present) provides a proper CDFS device so DriveType=5. Accepted by the game's file-path check per community reports. BIN/CUE recommended for archival (though this disc is single-track, no mixed-mode audio at risk). |
| winmm.dll CD-check stub | **Source + automated build shipped and verified on this machine** (`tools\cdstub\`) but **not needed here** — kept as fallback if a mount is ever rejected by an MCI medium-presence check. Built x86 (192 exports), fake cdaudio + forwarding proven by `test_stub`. Honest limitation documented: GetDriveType/IOCTL-level checks cannot be proxied (kernel32 is a KnownDLL). |
| DirectSound vs Miles | SFX work → DirectSound software layer fine. Music goes through Miles's DSI file streaming (not DirectMusic), so no DirectMusic fix applies. No MSS DLL replacement used — originals from the CD only (licensing). |
| **"insert the CD" prompt with the image mounted** | **ROOT CAUSE FOUND — two independent defects, both required fixing.** (1) *Registry view*: an earlier import wrote `InstalledFromDrive` into the **64-bit** view via 64-bit `reg.exe`, while this 32-bit game reads `WOW6432Node`. (2) *Missing colon — the decisive one*: disassembling the path builder shows `strcpy(base, value); strcat(base, "\\Hedz\\"); driveLetter = base[0];` with no colon inserted, so a bare `D` builds the **relative** path `D\Hedz\...`. Settled by Process Monitor: `CreateFile C:\Games\HEDZ\D\Hedz\Music\1.MUS -> PATH NOT FOUND`. **Fix:** `tools\Set-HedzCdPath.ps1 -CdDrive D:` (elevated, stores `D:`) → re-trace shows `D:\Hedz\test -> ACCESS DENIED` and `D:\Hedz\Music\1.mus`…`7.mus -> SUCCESS`. |
| Superseded theories | "The value is a bare letter and the game appends the colon" — **wrong**, disproven by the `AUDIO INFO: [MUS V2.0] Music path is: %s:` literal being unrelated to the protection path builder. "The protection checks the CD volume label / serial" — **wrong**, `GetVolumeInformation` is not imported at all. "The hardcoded `01383845300` is the expected serial" — **wrong**, that literal has zero code xrefs and is never compared. "A write-test lands on the hard disk" — **wrong**, the write test targets `<CD>\Hedz\test` and correctly gets ACCESS DENIED. |
| Deploying `winmm.dll` alone | **Removed again — the proxy must not be deployed for this title, and half-deploying it is worse than useless.** `Hedz.exe` contains **no `cdaudio`/MCI strings at all** (audio is DirectSound + Miles/AIL, and the disc check is registry/`GetDriveType`/`GetDiskFreeSpaceEx`/file-size based), so the stub intercepts nothing HEDZ uses. Worse, with `winmm_real.dll` missing its forwarded exports (`timeGetTime`, `waveOut*`, …) have no target — and `MSS32.DLL` imports exactly those, so the half-deployed proxy can break audio/music loading. Keep the stub as a documented tool for OTHER titles; for HEDZ the game folder must contain **no** `winmm.dll` / `winmm_real.dll`. |
| Music still silent after the disc fix (*superseded — see the RESOLVED row below*) | The CD path is proven good and the anti-piracy check passes, but a 45 s Process Monitor capture shows the game **never reads any music data**. The only `.mus` activity is the size probe (`CreateFile` -> `QueryStandardInformationFile` -> `CloseFile`, **no `ReadFile`**), and neither `F.MUS` (1.9 MB — almost certainly the front-end music) nor any of the seven paired `.AMB` files is touched. So the music subsystem fails **before streaming**, not in the Miles/DirectSound output path (and SFX working proves that path is healthy). Remaining work: an **in-level** capture (`Trace-Music.ps1 -Interactive`), plus DxWnd's own Sound logging. *This row is superseded — the cause was found (see §4).* |
| **Level music — ROOT CAUSE FOUND AND FIXED** | HEDZ plays level music **itself**, not through Miles: `mmioOpenA(<CD>\Hedz\Music\<level>.mus, NULL, MMIO_EXCLUSIVE)` + its **own `IDirectSoundBuffer`** (PCM 22050/16/2, 256000 bytes). Because `MMIO_EXCLUSIVE` opens with `FILE_SHARE_NONE`, the game's own `fopen` of the *same* file one instruction later gets a **SHARING VIOLATION**; the music-area table therefore never loads and the per-frame state machine never starts a track. Fixed at runtime by relaxing that one sharing flag. Full evidence in **§4**. |

### Task 3 — Color depth / palette

| Attempt | Result |
|---------|---------|
| Mode detection | **Corrected by static analysis of `Hedz.exe`.** An earlier revision of these notes asserted 640×480×**8-bit paletted**; the binary says the opposite emphasis. Every failure string in the surface/display code names **16-bit**: `Unable to change screen depth to 16bit mode, Intro movies will not be played`, `Could not create a 16 bit surface for the interface.` (repeated ~10×), `Unsupported Z-buffer depth requested by device.`, `Setting Display Mode To %dx%dx%d,` / `SetDisplayMode to %dx%dx%d failed`. "16-color" in the community posts is a misnomer; the real requirement is a legacy **16-bit** display mode, which Win11 cannot provide. |
| "Reduced color mode" checkbox | **Insufficient** (spoofs reported depth only, Win8+ behavior) — ruled out as primary fix, documented why. |
| Native OS low-color modes | Not available on Win11 24H2 — confirmed, no driver exposes 4/8-bit DAC palettes. |
| pal-ddraw | **Deployed and loading, but it is NOT the fix for this title — disproven by experiment (§3).** pal-ddraw is a *palette* (8-bit) emulator; it does not virtualize a 16-bit display mode. Standing it down entirely (`Test-NoWrapper.ps1`) changes nothing, and sweeping every key the DLL actually has (`Test-PalDdrawConfig.ps1` — `BPP`, `UseFlip`, `NoBuffer`, `UseThrottle`, with and without a `[PAL-DDRAW]` section) also changes nothing. `tools\pal-ddraw\ddraw.ini` now documents only the four keys that genuinely exist in the deployed DLL. |
| dgVoodoo2 | Documented alternate (Task 3 step 4). Do **not** stack with pal-ddraw. |
| Registry support flags | `Apply-HedzCompat.ps1` sets `Restore16BitDisplayMode`, clears 24H2's `Disable8BitAnd16BitDisplayModeToggle` block, applies POLY14 mitigation, optional true 640×480 4:3 desktop mode. Fully revertible. |

### Task 1 — Crashes

| Class | Status |
|-------|--------|
| C1 DirectDraw surface lock/unlock + flip timing | Superseded by C1b below. The "DxWnd flags" named here (`ForceSurfaceUnlock`, `PartialFlipEmulation`, `SuppressBackbufferRelease`) were **fabricated** and do not exist — DxWnd uses numeric bitmasks. The real configuration is the official H.E.D.Z. profile. |
| **C1b Two DirectDraw layers at once — REPRODUCED** | **Proven fatal on this machine.** With pal-ddraw *and* DxWnd active: `Event 1000 [Application Error] App: Hedz.exe Module: ddraw.dll`, and `Process Exit Exit Status: -1073741819` (**0xC0000005**, ACCESS_VIOLATION) at ~11 s. Same run with pal-ddraw retired: **no new WER entry**, 45 distinct colours on screen, process still alive after 45 s. This is the hard evidence for the one-wrapper rule. `Run-Hedz.ps1` and `Trace-Music.ps1` both retire pal-ddraw automatically. |
| C2 TruePlay.dll movie crash (privileged instructions) | Two documented non-invasive workarounds: play `Movies\*.avi` externally, or rename `TruePlay.dll` → `.DISABLED` so the engine skips cutscenes. No binary patching of the game. |
| C3 CD-access fault on level load | Downstream of Task 2 — resolved by keeping the CD mounted and `InstalledFromDrive` = `"<LETTER>:"` (colon required). Not an independent bug. |
| C4 Palette-menu flicker/misrender | Downstream of Task 3 — resolved by the wrapper. Not an independent bug. |
| C5 Alt-tab crash | Resolved by running windowed (`Windowed=1` in ddraw.ini / DxWnd profile). |

---

## 3. "Black screen, then it just closes" — reproduced, root-caused, **RESOLVED**

This was the blocker. It was **not a crash**: the process exits with code 0.

### Measured symptom (reproducible, `Capture-OnWindow.ps1`)

```
[0.3s] dialog  #32770 'H.E.D.Z.'  796,347 329x387   <- the real front end
        children: New Game | Multi-Player Game | Difficulty Settings |
                  Options | Exit | Play Movies
[1-7s] window  'Vis Interactive'/'Hedz'  0,0  1920x1080  (foreground)
        GAME WINDOW PIXELS: near-black 100%, distinct colours: 1  (#000000)
[+9s ] PROCESS EXITED  code=0
```

The game creates a render window the size of the **whole desktop** (1920x1080),
fills it with **one single colour — pure black** — and covers its own menu dialog
with it. That is the "black screen". Its own strings describe exactly this state:

```
To run this program in a window of this size, please adjust your display
settings for a smaller desktop area or a lower palette size and restart the program.
ERROR: Unable to get screen resolution
ERROR: Unable to determine display from Registery, using defaults
WARNING: Unable to change display mode without restarting computer
Failure getting the surface description of the front buffer before clearing.
```

### What was ruled out, with the experiment that ruled it out

| Candidate cause | Experiment | Verdict |
|---|---|---|
| The game's own display settings | `Test-DisplayModes.ps1` swept `FullScreen` 0/1 × `ResMode` 0-3 (7 combos) | **Ruled out** — every single combination gave the identical 1920x1080, 100% black, 1-colour window |
| pal-ddraw being wrong/broken | `Test-NoWrapper.ps1` renamed `DDRAW.dll` away so the system `ddraw.dll` was used | **Ruled out** — identical dialog + black window. pal-ddraw is neither causing nor curing it |
| pal-ddraw config | `Test-PalDdrawConfig.ps1` swept 5 `ddraw.ini` variants | **Ruled out** — all identical |
| Window merely being sized wrong | `Test-ForceWindowSize.ps1` forced the window to 640x480 via `SetWindowPos` on appearance | **Not the fix** (window collapsed to 0x0 and the process exited *sooner*), but it confirms the game reacts to its window size |
| The DirectDraw provider being absent | `Probe-LoadedModules.ps1` (run from **32-bit** PowerShell — 64-bit cannot enumerate a WOW64 process's 32-bit modules) | Confirmed loaded: `C:\GAMES\HEDZ\DDRAW.dll` (pal-ddraw), `mss32.dll`, `DSOUND.dll`, `TruePlay.dll` |

### Tooling lesson worth keeping

`Get-Process -Modules` from **64-bit** PowerShell on this 32-bit game returns only
`ntdll`/`wow64*.dll` and reports every real module as "NOT LOADED". Any module
question must be asked from `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`.

### RESOLVED — DxWnd with the OFFICIAL H.E.D.Z. profile

The window was the entire problem. The front end was alive and responsive behind it
the whole time; a black full-desktop window on top simply made it unclickable, which
looks indistinguishable from a crash.

DxWnd 2.06.15 ships **two ready-made H.E.D.Z. profiles** in its `exports\` folder:
`HEDZ.dxw` (maintained, stamped v2.04.72.a0) and the older `H.E.D.Z..dxw`. The
maintained one carries a note that is a direct hit on this symptom:

    To see the menu text the "Set texture pixel format" flag must be set

`Install-DxWnd.ps1` copies the maintained profile into `tools\dxwnd\` and rewrites
only `path0` (`D:\Games\HEDZ\HEDZ.EXE` -> the real install path). `Run-Hedz.ps1`
starts the DxWnd server in the tray and hands it the profile via `/Y:<file>`, which
is documented in the distribution's `help\Commandlinearguments.html`.

Measured effect (DxWnd, pal-ddraw retired):

| | before | after |
|---|---|---|
| render window | 1920x1080 at 0,0 | **800x600 at 50,50** |
| frame content | 1 colour (pure black) | 3 colours |
| process lifetime | ~9 s, then clean exit | ~31 s, **and playable into a level** |

Key values, all taken unmodified from the official profile:

    renderer0=3        maxddinterface0=7      sizx0=800          sizy0=600
    flag0=673185824    flagj0=134221952       flagn0=17825796

**And one hard rule, learned the ugly way.** Running this with pal-ddraw *and* DxWnd
active at the same time faults inside `ddraw.dll`:

    Event 1000 [Application Error]  App: Hedz.exe   Module: ddraw.dll
    Process Exit  Exit Status: -1073741819         (0xC0000005 ACCESS_VIOLATION)

Retire pal-ddraw and the identical run is clean: no new WER entry, 45 distinct colours
in frame, process still alive after 45 s. `Run-Hedz.ps1` and `Trace-Music.ps1` both
retire it for the session; do not re-enable it while DxWnd is in use.

**Corrections to earlier revisions of this file:** the hand-written
`tools\dxwnd\HEDZ.dxw` that shipped before was fabricated — invented key names such
as `ForceSurfaceUnlock` and `PartialFlipEmulation` that DxWnd does not use. DxWnd
stores **numeric bitmasks** (`flag0`, `flagg0`, `flagh0`, ...). It has been replaced by
the official profile; do not reintroduce invented keys. This is the third instance of
the same authoring mistake in this project (after the invented `hedz.ini` and the
invented pal-ddraw keys) — always read the real format out of the real artefact first.

Still open, lower priority:

- `SetDisplayMode`'s exact requested depth was never observed directly. The game's
  `c:\hedzdbg.txt` debug log is never written, and the profile's own note hints the
  renderer needs "Set texture pixel format" for menu text.
- Intro/cutscene movies still route through `TruePlay.dll` (Duck TrueMotion `TM20`),
  which no modern Windows codec decodes.
- DxWnd logging is available if either needs chasing: log mode "Overwrite" plus the
  "DxWnd hacks", "DirectDraw trace" and "Direct3D trace" topics produce `dxwnd.log`
  in the game folder (see the distribution's `help\Logs.html`).

---

## 4. Level music (`.mus`) — ROOT-CAUSED AND FIXED

### 4.1 What actually plays level music

HEDZ does **not** route level music through Miles. It plays it itself, from code
at `0045FE60` / `0048BBC0` / `00460A30`:

```
0045FE60(levelNumber)                    called at level entry, from 004154C2
  path = <CD-base>Music<level>.mus       i.e. D:\Hedz\Music\1.mus
  0048BBC0(obj, path, 0x3E800)
      mmioOpenA(path, NULL, MMIO_EXCLUSIVE)   <-- IAT slot 004C035C = WINMM!mmioOpenA
      malloc(256000)
      IDirectSound::CreateSoundBuffer(        <-- a buffer the GAME owns:
          PCM 22050 Hz, 16-bit, stereo,           not a Miles buffer
          256000 bytes, DSBCAPS = 0x000100E0)
  00460A30(path)
      fopen(path, ...)                        <-- the music-area / cue table
  ...then Miles streams the two `.AMB` ambience beds (these always worked)
```

`00460A30` seeks past the 4-byte size prefix and the whole embedded RIFF WAVE and
parses the trailing bytes as the area/cue table — which is why `.mus` looks like
"RIFF but with junk in front", and why the files are 36–57 MB.

A per-frame state machine (`0045FF60`, state in `005DCB7Fh`) then starts and feeds
the track by calling `0048BCF0`, which fills the DirectSound buffer, calls
`Play(DSBPLAY_LOOPING)` and sets `musicObject+2Dh` (`005B93ADh`) = 1. The music
tick (`00475B10`) branches on that byte:

* `obj+2Dh != 0` → keep streaming/feeding (music is playing), or
* `obj+2Dh == 0` → `mmioRead(hmmio, buf, 32768)` then, at EOF,
  `mmioSeek(hmmio, 0, 0)` — a **read-and-discard loop**.

### 4.2 The bug

`MMIO_EXCLUSIVE` makes `mmioOpen` open the file with `FILE_SHARE_NONE`. On Windows
NT that handle denies **every** subsequent open of the same file — including the
game's own `fopen` one instruction later. Process Monitor shows it literally:

```
CreateFile  D:\Hedz\Music\1.mus  ->  SUCCESS
CreateFile  D:\Hedz\Music\1.mus  ->  SHARING VIOLATION     <-- 00460A30's fopen
```

So `00460A30` returns 0, the area list is never built, and the state machine's
third gate (`0045FF9F`, `test [005986F4h]`) fails **on every tick, forever**. The
music object stays *created but never started*: `Play` never reaches DirectSound,
and the 32 KB read/rewind loop runs indefinitely. Because `1.mus` is 57 MB, that
loop looks like steady streaming in a file trace — which is exactly what earlier
sessions mistook it for ("the bytes are read but it is silent, so the fault is in
the handoff to Miles"). It is not: Miles is never involved in level music at all.

### 4.3 Evidence — two independent instruments, before vs after

| Signal | Before the shim | After the shim |
|--------|-----------------|----------------|
| `MusicAreaListHead` (`005986F4h`) | `0` forever | `0x032D1CE0` |
| `musicObject+2Dh` primed/playing (`005B93ADh`) | `0` forever | `1` |
| `MusicState` (`005DCB7Fh`) | `0` forever | `3` (= playing) |
| `MusicArea.current` (`005DCB7Eh`) | `0xFE` (sentinel: none) | `2` |
| `IDirectSoundBuffer::Play` on the 256000-byte stereo buffer | **never called** | called, `hr = 0` |
| `musicObject` file position (`005B9394h`) | frozen at `0` | advancing **~88 KB/s** |

That last row is the proof it is real audio and not another read loop: 88 KB/s is
exactly 22050 Hz x 2 channels x 2 bytes = the PCM data rate of the buffer, and the
DirectSound play cursor (`005B9398h`) wraps the 256000-byte buffer in lockstep.

Both instruments live in `tools\msslog\` — a logging proxy in front of
`mss32.dll` that also (a) hooks the DirectSound vtable the game uses and (b) polls
the music engine's own globals. `Map-PeImports.ps1` resolves
`call dword ptr ds:[004C0378h]`-style sites to real import names, which is what
identified `mmioRead` / `mmioSeek` / `mmioOpenA`.

### 4.4 The fix

One sharing flag, changed at runtime — the original executable is **not** modified
on disk:

* `mmioOpenA` is called by `Hedz.exe` through IAT slot `004C035Ch`.
* The shim verifies that slot really points into `winmm.dll` before touching it,
  then replaces it with a forwarder that turns `MMIO_EXCLUSIVE` (0x10) into
  `MMIO_DENYNONE` (0x40) and calls the original.
* Nothing else is altered: the same `mmioOpenA` opens the same file, it simply
  allows the second open to succeed.

```
SHIM  winmm!mmioOpenA hooked (IAT 004C035C, real=...) - MMIO_EXCLUSIVE relaxed
SHIM  mmioOpenA("D:\Hedz\Music\1.MUS", flags=0x10) -> MMIO_DENYNONE (flags=0x40)
```

### 4.5 Honest caveats

1. **The shim currently lives inside the instrumentation DLL.** It works and is
   proven, but that DLL also logs every Miles call, which is noisy (and is aimed
   at diagnosis, not at shipping). A quiet, standalone shim is the right final
   form — see the follow-up in the session notes.
2. **Why it worked on Windows 98 is not proven here.** Win9x's CD filesystem did
   not enforce NT-style sharing with the same rigour, which is the natural
   explanation, but that is an inference, not something this machine can test.
   The verified statement is narrower and solid: on Windows NT/11 the exclusive
   open blocks the game's own second open, and relaxing it makes the whole music
   chain run.
3. **`C:\Games\HEDZ\Music` is still needed** (as a junction to the disc) for the
   in-level **ambience** that Miles opens from the *install* path. With the
   junction removed, level ambience — which always worked — stops loading.

---

## 2. Open issues / known limitations

1. **pal-ddraw project availability**: the wrapper DLL itself must be built or
   downloaded from its official source (see README Tool inventory). If the
   project is abandoned, DDrawCompat or dgVoodoo2 both implement palette
   emulation; the shipped `ddraw.ini` documents which keys to carry over.
2. **TruePlay cutscenes** remain outside the engine unless someone builds a
   modern replacement decoder DLL. AVIs play fine externally.
3. **Windows updates may re-enable** `Disable8BitAnd16BitDisplayModeToggle`
   or the POLY14 behavior. If crashes return after a feature update, re-run
   `Apply-HedzCompat.ps1 -Action Apply` (idempotent).
4. **Drive-letter dependence**: if you mount the CD image on a different
   letter than `D:`, re-run `Install-Hedz.ps1` (refreshes the registry value) or edit
   the `CD=` line by hand. WinCDEmu does not auto-remount after reboot —
   either re-mount manually or switch to DAEMON Tools Lite / Virtual
   CloneDrive with auto-mount for the correct letter.
5. **16-bit display mode restore flag** (`Restore16BitDisplayMode`) helps
   only apps that query the app-compat engine; the wrapper is what actually
   fixes rendering. Keep both, expect the wrapper to matter.
6. **No game binaries were patched** (constraint honored). The only optional
   in-place change is renaming `TruePlay.dll` to disable it.

---

## 3. Validation checklist after a fresh install

1. `Verify-SetupExe.ps1` prints `[OK]` on all known-good layout entries.
2. `C:\GAMES\HEDZ\` contains Hedz.exe, hedz.hdz, MapFiles\, Movies\, MSS32.DLL, MSS16.DLL, TruePlay.dll — **no `Music\` folder** (by design).
3. `InstalledFromDrive` reads `D:` (32-bit registry view) and the image is mounted on that same letter.
4. `Apply-HedzCompat.ps1 -Action Apply` ran clean; `REG QUERY` shows the POLY14 + Layers values.
5. `ddraw.dll` (pal-ddraw) + `ddraw.ini` present in the game folder.
6. Game launches; menu fades animate smoothly (palette emulation working).
7. Starting any mission produces continuous `D:\Hedz\Music\*.mus` reads in Process Monitor (streaming works).
8. `Get-HedzCrashLog.ps1` shows no new Event 1000/1001 entries after a full session (intro → mission → exit).
