winmm.dll CD-presence stub - H.E.D.Z. Task 2 fallback
=====================================================

PURPOSE
-------
Only needed if HEDZ refuses a mounted disc image with an MCI-level
CD-presence check (open cdaudio / MCI_STATUS_MEDIA_PRESENT) instead of a
simple file-path check. Community reports for this title say the game
does a PATH check (reads <CD>:\Hedz\Music\*.mus) - so most users never
need this stub at all. Build it only if Process Monitor shows the game
probing MCI cdaudio and failing.

WHAT IT DOES
------------
winmm.dll is a proxy: six entry points are reimplemented, everything
else is forwarded by the linker to the real system winmm.dll (copied
next to the game as winmm_real.dll).

Intercepted and faked:
  mciSendCommandA/W   - "open cdaudio", MCI_DEVTYPE_CD_AUDIO, or opening
                        a drive root -> synthetic device; STATUS returns
                        MEDIA_PRESENT=TRUE, READY, MODE, POSITION, LENGTH;
                        PLAY/STOP/PAUSE/RESUME/SEEK/SET/GETDEVCAPS/INFO/
                        CLOSE all succeed.
  mciSendStringA/W    - "open cdaudio alias cd", "status cd media
                        present" -> "true", "status cd mode" -> "playing",
                        etc.
  mciGetDeviceIDA/W   - alias/id lookup for the synthetic device.

WHAT IT CANNOT DO (read this)
-----------------------------
GetDriveTypeA/W and raw IOCTL medium checks CANNOT be intercepted by
this proxy: they live in kernel32.dll, which is on the KnownDLLs list -
the Windows loader will never load a local kernel32.dll substitute.
If the game checks the disc at that level, this stub will not help; use
a virtual-drive tool with medium-type spoofing (WinCDEmu/DAEMON Tools)
or accept the file-path reality. No binary ships here precisely because
a proxy only makes sense built against YOUR system's winmm.dll.

FILES
-----
  winmm_stub.c        full C source (single file): MCI cdaudio emulation
                      for the six intercepted entry points
  build-winmm.ps1     automated build: copies the real winmm.dll, generates
                      winmm_forwarders.c (linker forwarders for every other
                      export, parsed from YOUR system winmm.dll) + winmm6.def
                      (the six implemented exports), compiles 32-bit,
                      verifies output, optional -DeployTo game folder
  test_stub.c         32-bit functional test (open/status/play/forwarding)
  _test_stub.ps1      builds + runs the functional test
  readme-stub.txt     this file

BUILD (automated, needs VS 2022 with "Desktop development with C++")
--------------------------------------------------------------------
  powershell -NoProfile -ExecutionPolicy Bypass -File .\build-winmm.ps1 -DeployTo C:\GAMES\HEDZ

BUILD (manual)
--------------
  1. Install Visual Studio 2022 Community + "Desktop development with C++".
  2. Open the "x86 Native Tools Command Prompt for VS 2022".
  3. Run build-winmm.ps1 once from any PowerShell - it copies the real
     winmm.dll and generates build\winmm_forwarders.c + winmm6.def
     (even on a machine without Visual Studio).
  4. In the x86 prompt:

       cd /d <repo>\tools\cdstub\build
       cl /nologo /LD /O2 /W3 /MT winmm_stub.c winmm_forwarders.c /Fe:winmm.dll /link /DEF:winmm6.def /MACHINE:X86 /NODEFAULTLIB:winmm.lib

  5. Copy winmm.dll AND winmm_real.dll into C:\GAMES\HEDZ\.

DEPLOY LAYOUT
-------------
  C:\GAMES\HEDZ\Hedz.exe
  C:\GAMES\HEDZ\winmm.dll         <- the proxy (32-bit, locally built)
  C:\GAMES\HEDZ\winmm_real.dll    <- byte-copy of SysWOW64\winmm.dll

  BOTH files are required: the proxy's forwarded exports point at
  winmm_real.dll; a missing copy = game fails to start at load time.

VERIFICATION
------------
  * build-winmm.ps1 self-verifies: x86 machine type + expected exports
    (mciSendCommandA, timeGetTime, joyGetPosEx, ...) present.
  * Functional test (32-bit): powershell -File .\_test_stub.ps1
    Verified on this machine: open cdaudio -> synthetic device id,
    media present -> "true", play -> mode "playing", and non-intercepted
    calls forwarded to the real winmm.dll (sysinfo answered by it).
  * In-game: if the game previously said "insert CD" with the image
    mounted and now proceeds, the stub did its job.
  * Process Monitor: MCI calls resolve inside winmm.dll (proxy) and
    winmm_real.dll; Music\*.mus reads still come from the real files.

REVERT
------
  Delete winmm.dll and winmm_real.dll from the game folder.
  No registry, no other files touched.

NOTES
-----
  * 32-bit ONLY. The game is a 32-bit process; a 64-bit build of this
    DLL makes the game fail to launch (ERROR_BAD_EXE_FORMAT). The
    source #errors on _WIN64, and the build script enforces x86.
  * Static CRT (/MT): no extra runtime dependencies.
  * Licensing: built from your own toolchain + a copy of YOUR system's
    winmm.dll. No third-party middleware involved.
