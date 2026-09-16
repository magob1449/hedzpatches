/* =====================================================================
 winmm_stub.c - H.E.D.Z. CD-presence MCI stub (Task 2 fallback)

 Intercepts six winmm entry points and fakes a present, playable
 cdaudio device so a game that verifies the disc via MCI accepts a
 mounted disc image. Every OTHER winmm export is forwarded to the real
 system winmm.dll (copied next to the game as winmm_real.dll by the
 build script) using linker export forwarding - zero code for those,
 so all real audio/joystick/mixer behavior is preserved.

 What it intercepts:
   mciSendCommandA / mciSendCommandW   (MCI message API)
   mciSendStringA   / mciSendStringW   (MCI string API)
   mciGetDeviceIDA  / mciGetDeviceIDW  (alias -> device id)

 What it fakes:
   - "open cdaudio" / MCI_OPEN with MCI_DEVTYPE_CD_AUDIO / opening a
     drive root ("D:\", "d:") -> synthetic device, media present
   - MCI_STATUS: MEDIA_PRESENT=TRUE, READY=TRUE, MODE per state machine,
     POSITION advancing (fake 74-minute disc), LENGTH, TRACKS=1
   - MCI_PLAY/STOP/PAUSE/RESUME/SEEK/SET/GETDEVCAPS/INFO/CLOSE: all
     succeed against the synthetic device
   - mciGetDeviceID("cdaudio" or registered alias) -> synthetic id

 What it does NOT do (and why):
   - GetDriveTypeA/W interception is impossible from a proxy DLL:
     GetDriveType lives in kernel32.dll, which is a KnownDLL - the
     loader NEVER substitutes a local kernel32.dll.
   - Raw IOCTL/medium-type checks (CreateFile on the drive + IOCTL_*)
     go through kernel32 too and cannot be proxied this way. If a game
     checks at that level you need a virtual-drive tool with medium
     spoofing (WinCDEmu/DAEMON Tools) instead of this stub.

 Build 32-bit ONLY (the game is a 32-bit process):
   automated:  powershell -NoProfile -ExecutionPolicy Bypass -File .\build-winmm.ps1
   manual:     x86 Native Tools Command Prompt for VS 2022 ->
     cl /nologo /LD /O2 /W3 /MT winmm_stub.c winmm_forwarders.c ^
        /Fe:winmm.dll /link /DEF:winmm6.def /MACHINE:X86 /NODEFAULTLIB:winmm.lib
   (winmm_forwarders.c and winmm6.def are produced by build-winmm.ps1
    from YOUR system winmm.dll's export table; see readme-stub.txt)

 Revert: delete winmm.dll and winmm_real.dll from the game folder.
=====================================================================*/
#define _CRT_SECURE_NO_WARNINGS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <stdio.h>

/* mmsystem.h declares mciSend* as dllimport (WINMMAPI); this proxy
   DEFINES them locally, which raises C4273. The definition wins and is
   exported via winmm_generated.def - the warning is expected noise. */
#pragma warning(disable: 4273)

#ifdef _WIN64
#error "This DLL must be built 32-bit (x86): the game is a 32-bit process."
#endif

/* ---------------- fake device table ---------------- */
#define FAKE_ID_BASE 0xCDA00000u
#define MAX_FAKE     16
#define DISC_LEN_MS  (74u * 60u * 1000u)   /* classic 74-minute CD */

typedef struct {
    MCIDEVICEID id;
    BOOL        inUse;
    DWORD       state;         /* MCI_MODE_* */
    DWORD       timeFormat;    /* MCI_FORMAT_* */
    DWORD       anchorTick;    /* GetTickCount() when playback (re)started */
    DWORD       accumMs;       /* accumulated position when not playing */
    char        alias[64];
} FAKEDEV;

static FAKEDEV g_devs[MAX_FAKE];
static DWORD   g_nextId = FAKE_ID_BASE;
static CRITICAL_SECTION g_cs;

/* ---------------- real winmm (winmm_real.dll) ---------------- */
typedef MCIERROR   (WINAPI *FN_SENDCOMMAND)(MCIDEVICEID, UINT, DWORD_PTR, DWORD_PTR);
typedef MCIERROR   (WINAPI *FN_SENDSTRINGA)(LPCSTR,   LPSTR,   UINT, HWND);
typedef MCIERROR   (WINAPI *FN_SENDSTRINGW)(LPCWSTR,  LPWSTR,  UINT, HWND);
typedef MCIDEVICEID(WINAPI *FN_GETDEVIDA) (LPCSTR);
typedef MCIDEVICEID(WINAPI *FN_GETDEVIDW) (LPCWSTR);

static HMODULE g_hReal = NULL;
static FN_SENDCOMMAND real_SendCommandA = NULL, real_SendCommandW = NULL;
static FN_SENDSTRINGA real_SendStringA  = NULL;
static FN_SENDSTRINGW real_SendStringW  = NULL;
static FN_GETDEVIDA   real_GetDevIdA    = NULL;
static FN_GETDEVIDW   real_GetDevIdW    = NULL;

#define MCI_FORWARD ((MCIERROR)0xFFFFFFFFu)  /* internal: forward to real winmm */

static void EnsureReal(void)
{
    HMODULE h;
    if (g_hReal) return;
    h = GetModuleHandleW(L"winmm_real.dll");   /* loader loads it for our forwarders anyway */
    if (!h) h = LoadLibraryW(L"winmm_real.dll");
    if (!h) return;
    g_hReal = h;
    real_SendCommandA = (FN_SENDCOMMAND) GetProcAddress(h, "mciSendCommandA");
    real_SendCommandW = (FN_SENDCOMMAND) GetProcAddress(h, "mciSendCommandW");
    real_SendStringA  = (FN_SENDSTRINGA) GetProcAddress(h, "mciSendStringA");
    real_SendStringW  = (FN_SENDSTRINGW) GetProcAddress(h, "mciSendStringW");
    real_GetDevIdA    = (FN_GETDEVIDA)   GetProcAddress(h, "mciGetDeviceIDA");
    real_GetDevIdW    = (FN_GETDEVIDW)   GetProcAddress(h, "mciGetDeviceIDW");
}

BOOL WINAPI DllMain(HINSTANCE hDll, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    switch (reason) {
    case DLL_PROCESS_ATTACH:
        DisableThreadLibraryCalls(hDll);
        InitializeCriticalSection(&g_cs);
        break;
    case DLL_PROCESS_DETACH:
        DeleteCriticalSection(&g_cs);
        break;
    }
    return TRUE;
}

/* ---------------- helpers (L suffix: g_cs held) ---------------- */
static FAKEDEV *FindByIdL(MCIDEVICEID id)
{
    int i;
    for (i = 0; i < MAX_FAKE; i++)
        if (g_devs[i].inUse && g_devs[i].id == id) return &g_devs[i];
    return NULL;
}

static BOOL IsFakeId(MCIDEVICEID id) { return id > FAKE_ID_BASE; }

static DWORD PosMsL(const FAKEDEV *d)
{
    if (d->state == MCI_MODE_PLAY)
        return d->accumMs + (GetTickCount() - d->anchorTick);
    return d->accumMs;
}

static DWORD InDevFormat(const FAKEDEV *d, DWORD ms)
{
    DWORD m, s, f;
    if (d->timeFormat == MCI_FORMAT_TMSF) {
        m = ms / 60000u; s = (ms % 60000u) / 1000u; f = (ms % 1000u) * 75u / 1000u;
        return MCI_MAKE_TMSF(1, (BYTE)m, (BYTE)s, (BYTE)f);
    }
    if (d->timeFormat == MCI_FORMAT_MSF) {
        m = ms / 60000u; s = (ms % 60000u) / 1000u; f = (ms % 1000u) * 75u / 1000u;
        return MCI_MAKE_MSF((BYTE)m, (BYTE)s, (BYTE)f);
    }
    return ms; /* MCI_FORMAT_MILLISECONDS */
}

static BOOL IsRootDriveA(const char *s)
{
    size_t n = s ? strlen(s) : 0;
    if (n == 2 && s[1] == ':') return TRUE;
    if (n == 3 && s[1] == ':' && (s[2] == '\\' || s[2] == '/')) return TRUE;
    return FALSE;
}

static BOOL IsRootDriveW(const wchar_t *s)
{
    size_t n = s ? wcslen(s) : 0;
    if (n == 2 && s[1] == L':') return TRUE;
    if (n == 3 && s[1] == L':' && (s[2] == L'\\' || s[2] == L'/')) return TRUE;
    return FALSE;
}

static FAKEDEV *FakeOpenL(const char *aliasA)   /* takes g_cs itself */
{
    FAKEDEV *d = NULL;
    int i;
    EnterCriticalSection(&g_cs);
    for (i = 0; i < MAX_FAKE; i++) if (!g_devs[i].inUse) { d = &g_devs[i]; break; }
    if (d) {
        memset(d, 0, sizeof(*d));
        d->inUse      = TRUE;
        d->id         = ++g_nextId;
        d->state      = MCI_MODE_STOP;
        d->timeFormat = MCI_FORMAT_MILLISECONDS;
        if (aliasA && aliasA[0]) lstrcpynA(d->alias, aliasA, (int)sizeof(d->alias));
    }
    LeaveCriticalSection(&g_cs);
    return d;
}

static FAKEDEV *LookupByNameL(const char *name) /* g_cs held */
{
    int i;
    if (!name || !name[0]) return NULL;
    for (i = 0; i < MAX_FAKE; i++)
        if (g_devs[i].inUse && g_devs[i].alias[0] && !_stricmp(g_devs[i].alias, name))
            return &g_devs[i];
    if (name[0] >= '0' && name[0] <= '9') {
        unsigned long v = strtoul(name, NULL, 10);
        if (v > FAKE_ID_BASE) return FindByIdL((MCIDEVICEID)v);
    }
    return NULL;
}

/* ---------------- MCI_OPEN detection ---------------- */
static MCIERROR HandleOpenA(DWORD flags, DWORD_PTR parm)
{
    MCI_OPEN_PARMSA *op = (MCI_OPEN_PARMSA *)parm;
    BOOL isCd = FALSE;
    const char *alias = NULL;
    FAKEDEV *d;

    if (!op) return MMSYSERR_INVALPARAM;

    if (flags & MCI_OPEN_TYPE_ID) {
        if ((op->wDeviceID & 0xFFFF) == MCI_DEVTYPE_CD_AUDIO) isCd = TRUE;
    } else if (flags & MCI_OPEN_TYPE) {
        if (op->lpstrDeviceType && !_stricmp(op->lpstrDeviceType, "cdaudio")) isCd = TRUE;
    }
    if (!isCd && (flags & MCI_OPEN_ELEMENT) && IsRootDriveA(op->lpstrElementName))
        isCd = TRUE;

    if (!isCd) return MCI_FORWARD;

    if (flags & MCI_OPEN_ALIAS) alias = op->lpstrAlias;
    d = FakeOpenL(alias ? alias : "cdaudio");
    if (!d) return MMSYSERR_NOMEM;
    op->wDeviceID = d->id;
    return 0;
}

static MCIERROR HandleOpenW(DWORD flags, DWORD_PTR parm)
{
    MCI_OPEN_PARMSW *op = (MCI_OPEN_PARMSW *)parm;
    BOOL isCd = FALSE;
    char aliasA[64] = "";
    FAKEDEV *d;

    if (!op) return MMSYSERR_INVALPARAM;

    if (flags & MCI_OPEN_TYPE_ID) {
        if ((op->wDeviceID & 0xFFFF) == MCI_DEVTYPE_CD_AUDIO) isCd = TRUE;
    } else if (flags & MCI_OPEN_TYPE) {
        if (op->lpstrDeviceType && !_wcsicmp(op->lpstrDeviceType, L"cdaudio")) isCd = TRUE;
    }
    if (!isCd && (flags & MCI_OPEN_ELEMENT) && IsRootDriveW(op->lpstrElementName))
        isCd = TRUE;

    if (!isCd) return MCI_FORWARD;

    if ((flags & MCI_OPEN_ALIAS) && op->lpstrAlias)
        WideCharToMultiByte(CP_UTF8, 0, op->lpstrAlias, -1, aliasA, (int)sizeof(aliasA), NULL, NULL);
    d = FakeOpenL(aliasA[0] ? aliasA : "cdaudio");
    if (!d) return MMSYSERR_NOMEM;
    op->wDeviceID = d->id;
    return 0;
}

/* ---------------- fake-device command handler ----------------
   STATUS/PLAY/SET/GETDEVCAPS parameter blocks have no strings, so the
   A and W forms are binary-identical. INFO carries a string -> isWide. */
static MCIERROR HandleFakeCmd(MCIDEVICEID id, UINT msg, DWORD flags, DWORD_PTR parm, int isWide)
{
    FAKEDEV *d;
    MCIERROR rc = 0;

    EnterCriticalSection(&g_cs);
    d = FindByIdL(id);
    if (!d) { LeaveCriticalSection(&g_cs); return MMSYSERR_INVALPARAM; }

    switch (msg) {
    case MCI_STATUS: {
        MCI_STATUS_PARMS *sp = (MCI_STATUS_PARMS *)parm;
        if ((flags & MCI_STATUS_ITEM) && sp) {
            switch (sp->dwItem) {
            case MCI_STATUS_MEDIA_PRESENT:    sp->dwReturn = TRUE;                          break;
            case MCI_STATUS_MODE:             sp->dwReturn = d->state;                      break;
            case MCI_STATUS_READY:            sp->dwReturn = TRUE;                          break;
            case MCI_STATUS_POSITION:         sp->dwReturn = InDevFormat(d, PosMsL(d));     break;
            case MCI_STATUS_LENGTH:           sp->dwReturn = InDevFormat(d, DISC_LEN_MS);   break;
            case MCI_STATUS_NUMBER_OF_TRACKS: sp->dwReturn = 1;                             break;
            case MCI_STATUS_CURRENT_TRACK:    sp->dwReturn = 1;                             break;
            case MCI_STATUS_TIME_FORMAT:      sp->dwReturn = d->timeFormat;                 break;
            default:                          sp->dwReturn = 0;                             break;
            }
        }
        break;
    }
    case MCI_PLAY: {
        MCI_PLAY_PARMS *pp = (MCI_PLAY_PARMS *)parm;
        (void)pp;
        if (flags & MCI_FROM) d->accumMs = 0;  /* FROM in non-ms formats: start at 0 (simplification) */
        d->anchorTick = GetTickCount();
        d->state = MCI_MODE_PLAY;
        break;
    }
    case MCI_STOP:    d->accumMs = PosMsL(d); d->state = MCI_MODE_STOP;  break;
    case MCI_PAUSE:   d->accumMs = PosMsL(d); d->state = MCI_MODE_PAUSE; break;
    case MCI_RESUME:  d->anchorTick = GetTickCount(); d->state = MCI_MODE_PLAY; break;
    case MCI_SEEK:    d->accumMs = 0;         d->state = MCI_MODE_STOP;  break;
    case MCI_SET: {
        MCI_SET_PARMS *sp = (MCI_SET_PARMS *)parm;
        if ((flags & MCI_SET_TIME_FORMAT) && sp)
            d->timeFormat = (DWORD)sp->dwTimeFormat;
        break;
    }
    case MCI_GETDEVCAPS: {
        MCI_GETDEVCAPS_PARMS *gp = (MCI_GETDEVCAPS_PARMS *)parm;
        if ((flags & MCI_GETDEVCAPS_ITEM) && gp) {
            switch (gp->dwItem) {
            case MCI_GETDEVCAPS_DEVICE_TYPE:     gp->dwReturn = MCI_DEVTYPE_CD_AUDIO; break;
            case MCI_GETDEVCAPS_CAN_EJECT:       gp->dwReturn = TRUE;  break;
            case MCI_GETDEVCAPS_CAN_PLAY:        gp->dwReturn = TRUE;  break;
            case MCI_GETDEVCAPS_CAN_RECORD:      gp->dwReturn = FALSE; break;
            case MCI_GETDEVCAPS_HAS_AUDIO:       gp->dwReturn = TRUE;  break;
            case MCI_GETDEVCAPS_HAS_VIDEO:       gp->dwReturn = FALSE; break;
            case MCI_GETDEVCAPS_USES_FILES:      gp->dwReturn = FALSE; break;
            case MCI_GETDEVCAPS_COMPOUND_DEVICE: gp->dwReturn = FALSE; break;
            default:                             gp->dwReturn = FALSE; break;
            }
        }
        break;
    }
    case MCI_INFO: {
        if (isWide) {
            MCI_INFO_PARMSW *ip = (MCI_INFO_PARMSW *)parm;
            if (ip && ip->lpstrReturn && ip->dwRetSize)
                lstrcpynW(ip->lpstrReturn, L"HEDZ cdaudio (stub)", (int)ip->dwRetSize);
        } else {
            MCI_INFO_PARMS *ip = (MCI_INFO_PARMS *)parm;
            if (ip && ip->lpstrReturn && ip->dwRetSize)
                lstrcpynA(ip->lpstrReturn, "HEDZ cdaudio (stub)", (int)ip->dwRetSize);
        }
        break;
    }
    case MCI_CLOSE:
        d->inUse = FALSE;
        d->alias[0] = 0;
        break;
    default:
        rc = MMSYSERR_NOTSUPPORTED;
        break;
    }
    LeaveCriticalSection(&g_cs);
    return rc;
}

/* ---------------- string API core ---------------- */
static void LowerA(char *s) { for (; *s; s++) if (*s >= 'A' && *s <= 'Z') *s = (char)(*s - 'A' + 'a'); }

#define TOKMAX 12
static int SplitA(char *buf, char *toks[], int maxTok)
{
    int n = 0;
    char *p = buf;
    while (*p && n < maxTok) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        toks[n++] = p;
        while (*p && *p != ' ' && *p != '\t') p++;
        if (*p) *p++ = 0;
    }
    return n;
}

/* returns 0 = handled (result text in out), 1 = forward to real winmm */
static int CoreStringA(const char *cmd, char *out, UINT cchOut, MCIERROR *errOut)
{
    char buf[512];
    char *tok[TOKMAX];
    int  nt, i, rc = 1;
    FAKEDEV *d = NULL;
    char num[24];

    out[0] = 0; *errOut = 0;
    if (!cmd || !cmd[0]) return 1;
    lstrcpynA(buf, cmd, (int)sizeof(buf));
    LowerA(buf);
    nt = SplitA(buf, tok, TOKMAX);
    if (nt < 1) return 1;

    EnterCriticalSection(&g_cs);

    if (!strcmp(tok[0], "open")) {
        BOOL isCd = FALSE;
        const char *alias = NULL;
        for (i = 1; i < nt; i++) {
            if (!strcmp(tok[i], "cdaudio") || !_strnicmp(tok[i], "cdaudio!", 8))
                isCd = TRUE;
            else if (!strcmp(tok[i], "type") && i + 1 < nt && !strcmp(tok[i + 1], "cdaudio"))
                isCd = TRUE;
            else if (IsRootDriveA(tok[i]))
                isCd = TRUE;
            else if (!strcmp(tok[i], "alias") && i + 1 < nt)
                alias = tok[i + 1];
        }
        if (!isCd) goto done;                       /* not ours -> forward */
        d = FakeOpenL(alias ? alias : "cdaudio");
        if (!d) { *errOut = MMSYSERR_NOMEM; rc = 0; goto done; }
        if (cchOut) { sprintf(num, "%u", d->id); lstrcpynA(out, num, (int)cchOut); }
        rc = 0;
        goto done;
    }

    /* every other verb: resolve the target device (token 1) */
    d = (nt >= 2) ? LookupByNameL(tok[1]) : NULL;
    if (!d) goto done;                              /* not ours -> forward */

    if (!strcmp(tok[0], "status")) {
        BOOL qMode = FALSE, qPos = FALSE, qLen = FALSE, qReady = FALSE,
             qTracks = FALSE, qCur = FALSE, qFmt = FALSE, qMedia = FALSE;
        const char *modeStr;
        for (i = 2; i < nt; i++) {
            if      (!strcmp(tok[i], "mode"))         qMode  = TRUE;
            else if (!strcmp(tok[i], "position"))     qPos   = TRUE;
            else if (!strcmp(tok[i], "length"))       qLen   = TRUE;
            else if (!strcmp(tok[i], "ready"))        qReady = TRUE;
            else if (!strcmp(tok[i], "tracks"))       qTracks= TRUE;  /* "number of tracks" */
            else if (!strcmp(tok[i], "track"))        qCur   = TRUE;  /* "current track"    */
            else if (!strcmp(tok[i], "format"))       qFmt   = TRUE;  /* "time format"      */
            else if (!strcmp(tok[i], "present"))      qMedia = TRUE;  /* "media present"    */
        }
        if (cchOut) {
            if      (qMedia) lstrcpynA(out, "true", (int)cchOut);
            else if (qReady) lstrcpynA(out, "true", (int)cchOut);
            else if (qMode) {
                switch (d->state) {
                case MCI_MODE_PLAY:      modeStr = "playing";  break;
                case MCI_MODE_PAUSE:     modeStr = "paused";   break;
                case MCI_MODE_SEEK:      modeStr = "seeking";  break;
                case MCI_MODE_NOT_READY: modeStr = "not ready"; break;
                case MCI_MODE_OPEN:      modeStr = "open";     break;
                default:                 modeStr = "stopped";  break;
                }
                lstrcpynA(out, modeStr, (int)cchOut);
            }
            else if (qPos)   { sprintf(num, "%u", InDevFormat(d, PosMsL(d)));   lstrcpynA(out, num, (int)cchOut); }
            else if (qLen)   { sprintf(num, "%u", InDevFormat(d, DISC_LEN_MS)); lstrcpynA(out, num, (int)cchOut); }
            else if (qTracks) lstrcpynA(out, "1", (int)cchOut);
            else if (qCur)    lstrcpynA(out, "1", (int)cchOut);
            else if (qFmt)    lstrcpynA(out,
                                  d->timeFormat == MCI_FORMAT_TMSF ? "tmsf" :
                                  d->timeFormat == MCI_FORMAT_MSF  ? "msf"  : "milliseconds",
                                  (int)cchOut);
        }
        rc = 0;
        goto done;
    }

    if (!strcmp(tok[0], "play"))   { d->accumMs = 0;        d->anchorTick = GetTickCount(); d->state = MCI_MODE_PLAY;  rc = 0; goto done; }
    if (!strcmp(tok[0], "stop"))   { d->accumMs = PosMsL(d); d->state = MCI_MODE_STOP;  rc = 0; goto done; }
    if (!strcmp(tok[0], "pause"))  { d->accumMs = PosMsL(d); d->state = MCI_MODE_PAUSE; rc = 0; goto done; }
    if (!strcmp(tok[0], "resume")) { d->anchorTick = GetTickCount(); d->state = MCI_MODE_PLAY;  rc = 0; goto done; }
    if (!strcmp(tok[0], "seek"))   { d->accumMs = 0;        d->state = MCI_MODE_STOP;  rc = 0; goto done; }
    if (!strcmp(tok[0], "close"))  { d->inUse = FALSE; d->alias[0] = 0; rc = 0; goto done; }
    if (!strcmp(tok[0], "set")) {
        for (i = 2; i + 1 < nt; i++) {
            if (!strcmp(tok[i], "format") && i >= 3 && !strcmp(tok[i - 1], "time")) {
                if      (!strcmp(tok[i + 1], "milliseconds")) d->timeFormat = MCI_FORMAT_MILLISECONDS;
                else if (!strcmp(tok[i + 1], "tmsf"))         d->timeFormat = MCI_FORMAT_TMSF;
                else if (!strcmp(tok[i + 1], "msf"))          d->timeFormat = MCI_FORMAT_MSF;
            }
        }
        rc = 0;
        goto done;
    }

    /* any other command on OUR fake device: succeed silently */
    rc = 0;

done:
    LeaveCriticalSection(&g_cs);
    return rc;
}

/* ---------------- exported entry points ---------------- */

/* The six functions are exported under their clean winmm names via
   winmm6.def (generated by the build script) - do NOT use dllexport
   here: mmsystem.h already declares them dllimport, which would clash. */
MCIERROR WINAPI mciSendCommandA(MCIDEVICEID wDeviceID, UINT uMsg, DWORD_PTR dwParam1, DWORD_PTR dwParam2)
{
    MCIERROR rc;
    EnsureReal();
    if (uMsg == MCI_OPEN) {
        rc = HandleOpenA((DWORD)dwParam1, dwParam2);
        if (rc != MCI_FORWARD) return rc;
    } else if (IsFakeId(wDeviceID)) {
        return HandleFakeCmd(wDeviceID, uMsg, (DWORD)dwParam1, dwParam2, 0);
    }
    if (!real_SendCommandA) return MMSYSERR_ERROR;
    return real_SendCommandA(wDeviceID, uMsg, dwParam1, dwParam2);
}

MCIERROR WINAPI mciSendCommandW(MCIDEVICEID wDeviceID, UINT uMsg, DWORD_PTR dwParam1, DWORD_PTR dwParam2)
{
    MCIERROR rc;
    EnsureReal();
    if (uMsg == MCI_OPEN) {
        rc = HandleOpenW((DWORD)dwParam1, dwParam2);
        if (rc != MCI_FORWARD) return rc;
    } else if (IsFakeId(wDeviceID)) {
        return HandleFakeCmd(wDeviceID, uMsg, (DWORD)dwParam1, dwParam2, 1);
    }
    if (!real_SendCommandW) return MMSYSERR_ERROR;
    return real_SendCommandW(wDeviceID, uMsg, dwParam1, dwParam2);
}

MCIERROR WINAPI mciSendStringA(LPCSTR lpCommand, LPSTR lpReturn, UINT cchReturn, HWND hwndCallback)
{
    char out[128];
    MCIERROR err = 0;
    EnsureReal();
    if (CoreStringA(lpCommand, out, (UINT)sizeof(out), &err) == 0) {
        if (lpReturn && cchReturn) lstrcpynA(lpReturn, out, (int)cchReturn);
        return err;
    }
    if (!real_SendStringA) return MMSYSERR_ERROR;
    return real_SendStringA(lpCommand, lpReturn, cchReturn, hwndCallback);
}

MCIERROR WINAPI mciSendStringW(LPCWSTR lpCommand, LPWSTR lpReturn, UINT cchReturn, HWND hwndCallback)
{
    char a[512];
    char out[128];
    MCIERROR err = 0;
    EnsureReal();
    if (lpCommand) WideCharToMultiByte(CP_UTF8, 0, lpCommand, -1, a, (int)sizeof(a), NULL, NULL);
    else a[0] = 0;
    if (CoreStringA(a, out, (UINT)sizeof(out), &err) == 0) {
        if (lpReturn && cchReturn) MultiByteToWideChar(CP_UTF8, 0, out, -1, lpReturn, (int)cchReturn);
        return err;
    }
    if (!real_SendStringW) return MMSYSERR_ERROR;
    return real_SendStringW(lpCommand, lpReturn, cchReturn, hwndCallback);
}

MCIDEVICEID WINAPI mciGetDeviceIDA(LPCSTR pszDevice)
{
    FAKEDEV *d;
    EnsureReal();
    if (pszDevice) {
        EnterCriticalSection(&g_cs);
        d = LookupByNameL(pszDevice);
        LeaveCriticalSection(&g_cs);
        if (d) return d->id;
    }
    if (!real_GetDevIdA) return 0;
    return real_GetDevIdA(pszDevice);
}

MCIDEVICEID WINAPI mciGetDeviceIDW(LPCWSTR pszDevice)
{
    char a[256];
    FAKEDEV *d;
    EnsureReal();
    if (pszDevice) {
        WideCharToMultiByte(CP_UTF8, 0, pszDevice, -1, a, (int)sizeof(a), NULL, NULL);
        EnterCriticalSection(&g_cs);
        d = LookupByNameL(a);
        LeaveCriticalSection(&g_cs);
        if (d) return d->id;
    }
    if (!real_GetDevIdW) return 0;
    return real_GetDevIdW(pszDevice);
}
