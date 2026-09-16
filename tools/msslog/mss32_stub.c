/* mss32_stub.c - logging proxy for Miles Sound System (mss32.dll), 32-bit x86.
 *
 * WHY THIS EXISTS
 *   H.E.D.Z. streams its level music itself and hands the decoded audio to
 *   Miles.  Measured facts on Windows 11 as of the last Process Monitor run:
 *     - D:\Hedz\Music\1.mus is opened and read continuously in 32 KB chunks
 *       (356 reads over ~85 s) while a level is being played, so the file
 *       access and streaming loop are fine.
 *     - The sound effects play (SoundFX.dat samples) and the title music plays
 *       (F.MUS, IMA ADPCM, opened through AIL_open_stream from the disc).
 *     - The level music is silent anyway.
 *   Read the bytes but hear nothing => the fault is downstream of the read,
 *   somewhere in the handoff to Miles.  This DLL sits in that handoff and
 *   records every call the game makes into the audio layer, with arguments.
 *
 * HOW IT WORKS
 *   Rename the real DLL to mss32_real.dll, install this as mss32.dll.  Windows
 *   resolves the game's mss32.dll import (and any LoadLibrary by name) to this
 *   file first, because the application directory is searched ahead of the
 *   system directories.  Each export below logs, then forwards to the real
 *   DLL resolved once with GetProcAddress.
 *
 *   Only the 31 exports Hedz.exe actually imports are implemented; those are
 *   exactly the game's complete audio requirement.
 *
 *   Log: mss32-proxy.log, beside this DLL (appended, flushed every line, and
 *   mirrored to OutputDebugString so a debug listener can watch it live).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>

#pragma warning(disable:4113)   /* function pointer / data pointer conversion */
#pragma warning(disable:4996)   /* sprintf etc. */

typedef unsigned char  U8;
typedef unsigned short U16;
typedef unsigned int   U32;
typedef int            S32;
typedef void          *HANDLE32;
typedef void          *HDIGDRIVER;
typedef void          *HSAMPLE;
typedef void          *HSTREAM;

static HMODULE           g_self   = NULL;
static HMODULE           g_real   = NULL;
static FILE             *g_log    = NULL;
static CRITICAL_SECTION  g_cs;
static int               g_csInit = 0;
static char              g_dir[MAX_PATH] = {0};
static DWORD             g_t0     = 0;
static unsigned long     g_lines  = 0;

/* ---------------------------------------------------------------- logging -- */
static void logline(const char *fmt, ...)
{
    char    body[1024];
    char    line[1200];
    va_list ap;

    if (!g_csInit) return;
    EnterCriticalSection(&g_cs);

    if (!g_log) {
        char path[MAX_PATH * 2];
        lstrcpynA(path, g_dir, MAX_PATH);
        lstrcatA(path, "mss32-proxy.log");
        g_log = fopen(path, "a");
    }
    va_start(ap, fmt);
    _vsnprintf(body, sizeof(body) - 1, fmt, ap);
    va_end(ap);
    body[sizeof(body) - 1] = 0;

    _snprintf(line, sizeof(line) - 1, "[%7lu ms tid=%5lu] %s",
              (unsigned long)(GetTickCount() - g_t0), (unsigned long)GetCurrentThreadId(), body);
    line[sizeof(line) - 1] = 0;

    if (g_log) { fprintf(g_log, "%s\n", line); fflush(g_log); }
    OutputDebugStringA(line);
    OutputDebugStringA("\n");
    g_lines++;
    LeaveCriticalSection(&g_cs);
}

/* ------------------------------------------------------- real DLL resolve -- */
static void *rproc(const char *name)
{
    void *p;
    if (!g_real) {
        char path[MAX_PATH + 32];
        char dir[MAX_PATH];
        lstrcpynA(dir, g_dir, MAX_PATH);
        lstrcpynA(path, dir, MAX_PATH);
        lstrcatA(path, "mss32_real.dll");
        g_real = LoadLibraryA(path);
        logline("mss32_real = %s  handle=%p  err=%lu", path, (void *)g_real,
                g_real ? 0UL : (unsigned long)GetLastError());
    }
    if (!g_real) return NULL;
    p = (void *)GetProcAddress(g_real, name);
    if (!p) logline("!! real mss32 has no export %s", name);
    return p;
}

/* ====================================================================== *
 * DirectSound vtable hooks
 * ----------------------------------------------------------------------
 * WHY
 *   The game does NOT play level music through Miles.  Its own code (at
 *   0x48BBC0 in Hedz.exe) does this:
 *       mmioOpenA("<install>\\Music\\<n>.mus", NULL, MMIO_EXCLUSIVE)
 *       mmioRead(hmmio, buf, 32768)                       <- the 32 KB reads
 *       IDirectSound::CreateSoundBuffer(DSBUFFERDESC{PCM 22050/16/2, 32768})
 *       <mix buf into that buffer>
 *       IDirectSoundBuffer::Play / SetCurrentPosition / Unlock
 *   ...on the IDirectSound object it obtained from Miles.  So the level-music
 *   path is invisible to a Miles-level log, and it is a SEPARATE path from the
 *   one (Miles streams) that demonstrably works.
 *
 *   Measured with this proxy: AIL_get_DirectSound_info DOES hand the game a
 *   real IDirectSound (0x02B00840) - so the handoff is fine and the fault is
 *   downstream of it, in the buffer creation / playback.  These hooks sit
 *   exactly there.
 *
 * HOW
 *   Patch the COM vtable slots in place (VirtualProtect + swap), forwarding to
 *   the original.  Secondary buffers in dsound share one vtable, so installing
 *   once also covers Miles's own buffers - which is fine because every hook
 *   forwards, and it means Miles's Play/SetVolume calls show up as context.
 *     IDirectSound        +0x0C CreateSoundBuffer   +0x18 SetCooperativeLevel
 *     IDirectSoundBuffer  +0x2C Lock   +0x30 Play   +0x34 SetCurrentPosition
 *                         +0x3C SetVolume   +0x48 Stop   +0x4C Unlock
 * ====================================================================== */
typedef HRESULT (__stdcall *FN_CSB)(void *self, const void *desc, void **out, void *unk);
typedef HRESULT (__stdcall *FN_SCL)(void *self, void *h, DWORD level);
typedef HRESULT (__stdcall *FN_PLAY)(void *self, DWORD r1, DWORD prio, DWORD flags);
typedef HRESULT (__stdcall *FN_SETPOS)(void *self, DWORD pos);
typedef HRESULT (__stdcall *FN_SETVOL)(void *self, long vol);
typedef HRESULT (__stdcall *FN_STOP)(void *self);

static FN_CSB   g_origCSB   = NULL;
static FN_SCL   g_origSCL   = NULL;
static FN_PLAY  g_origPlay  = NULL;
static FN_SETPOS g_origSetPos = NULL;
static FN_SETVOL g_origSetVol = NULL;
static FN_STOP  g_origStop  = NULL;
static void   **g_dsVtbl    = NULL;   /* IDirectSound vtable we patched      */
static void   **g_bufVtbl   = NULL;   /* IDirectSoundBuffer vtable we patched */
static int      g_ourBuffers = 0;

static void patch_slot(void **vtbl, int slot, void *hook, void **origOut)
{
    DWORD old = 0;
    if (!vtbl || !vtbl[slot]) return;
    if (vtbl[slot] == hook) return;                  /* already ours */
    if (origOut && !*origOut) *origOut = vtbl[slot];
    if (!VirtualProtect(&vtbl[slot], sizeof(void *), PAGE_READWRITE, &old)) return;
    vtbl[slot] = hook;
    VirtualProtect(&vtbl[slot], sizeof(void *), old, &old);
}

/* --- IDirectSoundBuffer hooks ------------------------------------------- */
static HRESULT __stdcall Hook_Play(void *self, DWORD r1, DWORD prio, DWORD flags)
{
    HRESULT hr = g_origPlay(self, r1, prio, flags);
    logline("IDirectSoundBuffer::Play(self=%p, reserved=%lu, priority=%lu, flags=%lu) -> hr=0x%08lX%s",
            self, (unsigned long)r1, (unsigned long)prio, (unsigned long)flags,
            (unsigned long)hr, hr ? "   <<< Play FAILED (this is why it is silent)" : "");
    return hr;
}

static HRESULT __stdcall Hook_SetCurrentPosition(void *self, DWORD pos)
{
    HRESULT hr = g_origSetPos(self, pos);
    logline("IDirectSoundBuffer::SetCurrentPosition(self=%p, pos=%lu) -> hr=0x%08lX",
            self, (unsigned long)pos, (unsigned long)hr);
    return hr;
}

static HRESULT __stdcall Hook_SetVolume(void *self, long vol)
{
    HRESULT hr = g_origSetVol(self, vol);
    logline("IDirectSoundBuffer::SetVolume(self=%p, vol=%ld) -> hr=0x%08lX",
            self, vol, (unsigned long)hr);
    return hr;
}

static HRESULT __stdcall Hook_Stop(void *self)
{
    HRESULT hr = g_origStop(self);
    logline("IDirectSoundBuffer::Stop(self=%p) -> hr=0x%08lX", self, (unsigned long)hr);
    return hr;
}

static void hook_buffer(void *buf)
{
    void **vt;
    if (!buf) return;
    vt = *(void ***)buf;
    if (!vt) return;
    if (g_bufVtbl == vt) { g_ourBuffers++; return; }   /* already patched */
    patch_slot(vt, 0x30 / 4, (void *)Hook_Play, (void **)&g_origPlay);
    patch_slot(vt, 0x34 / 4, (void *)Hook_SetCurrentPosition, (void **)&g_origSetPos);
    patch_slot(vt, 0x3C / 4, (void *)Hook_SetVolume, (void **)&g_origSetVol);
    patch_slot(vt, 0x48 / 4, (void *)Hook_Stop, (void **)&g_origStop);
    g_bufVtbl = vt;
    g_ourBuffers++;
    logline("hooked IDirectSoundBuffer vtable %p (Play/SetVolume/SetCurrentPosition/Stop)",(void *)vt);
}

/* --- IDirectSound hooks -------------------------------------------------- */
static HRESULT __stdcall Hook_CreateSoundBuffer(void *self, const void *desc, void **out, void *unk)
{
    const unsigned char *d = (const unsigned char *)desc;
    DWORD  flags = d ? *(const DWORD *)(d + 4) : 0;
    DWORD  bytes = d ? *(const DWORD *)(d + 8) : 0;
    const unsigned char *wfx = NULL;
    void  *buf = NULL;
    HRESULT hr;
    if (d && *(const void **)(d + 16)) wfx = *(const unsigned char *const *)(d + 16);
    if (out) *out = NULL;
    hr = g_origCSB(self, desc, out, unk);
    if (out) buf = *out;
    logline("IDirectSound::CreateSoundBuffer(flags=0x%08lX bytes=%lu wfx={tag=%u ch=%u rate=%lu avg=%lu bits=%u}) -> hr=0x%08lX buffer=%p%s",
            (unsigned long)flags, (unsigned long)bytes,
            wfx ? *(const U16 *)(wfx + 0) : 0, wfx ? *(const U16 *)(wfx + 2) : 0,
            wfx ? *(const U32 *)(wfx + 4) : 0, wfx ? *(const U32 *)(wfx + 8) : 0,
            wfx ? *(const U16 *)(wfx + 14) : 0,
            (unsigned long)hr, buf,
            hr ? "   <<< CreateSoundBuffer FAILED" : "");
    if (buf) hook_buffer(buf);
    return hr;
}

static HRESULT __stdcall Hook_SetCooperativeLevel(void *self, void *h, DWORD level)
{
    HRESULT hr = g_origSCL(self, h, level);
    logline("IDirectSound::SetCooperativeLevel(hwnd=%p, level=%lu) -> hr=0x%08lX",
            h, (unsigned long)level, (unsigned long)hr);
    return hr;
}

static void install_ds_hooks(void *pDS)
{
    void **vt;
    if (!pDS) return;
    vt = *(void ***)pDS;
    if (!vt) return;
    if (g_dsVtbl == vt) return;                       /* already patched */
    g_dsVtbl = vt;
    patch_slot(vt, 0x0C / 4, (void *)Hook_CreateSoundBuffer, (void **)&g_origCSB);
    patch_slot(vt, 0x18 / 4, (void *)Hook_SetCooperativeLevel, (void **)&g_origSCL);
    logline("hooked IDirectSound vtable %p (CreateSoundBuffer/SetCooperativeLevel)", (void *)vt);
}

/* ---------------------------------------------------------------- exports -- */
/* stream / sample handles are logged as pointers: repeated values show reuse. */

__declspec(dllexport) S32 __stdcall AIL_startup(void)
{
    typedef S32 (__stdcall *F)(void);
    static F f = NULL; S32 r;
    if (!f) f = (F)rproc("_AIL_startup@0");
    if (!f) return 0;
    r = f();
    logline("AIL_startup() -> %d", r);
    return r;
}

__declspec(dllexport) void __stdcall AIL_shutdown(void)
{
    typedef void (__stdcall *F)(void);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_shutdown@0");
    logline("AIL_shutdown()");
    if (f) f();
}

__declspec(dllexport) S32 __stdcall AIL_set_preference(U32 number, S32 value)
{
    typedef S32 (__stdcall *F)(U32, S32);
    static F f = NULL; S32 r;
    if (!f) f = (F)rproc("_AIL_set_preference@8");
    if (!f) return 0;
    r = f(number, value);
    logline("AIL_set_preference(number=%lu, value=%d) -> %d", (unsigned long)number, value, r);
    return r;
}

__declspec(dllexport) U32 __stdcall AIL_get_DirectSound_info(HSAMPLE s, void *a, void *b)
{
    typedef U32 (__stdcall *F)(HSAMPLE, void *, void *);
    static F f = NULL; U32 r;
    void *va = NULL, *vb = NULL;
    if (!f) f = (F)rproc("_AIL_get_DirectSound_info@12");
    if (!f) return 0;
    if (a) va = *(void **)a;
    if (b) vb = *(void **)b;
    r = f(s, a, b);
    /* The game READS these two slots after the call: it uses the DirectSound
       object Miles owns to create its own music buffer.  Log before and after,
       then install the DirectSound vtable hooks on whatever came back.        */
    logline("AIL_get_DirectSound_info(arg1=%p, lpDS=%p, lpDSB=%p) -> %lu | before: DS=%p DSB=%p | after: DS=%p DSB=%p",
            s, a, b, (unsigned long)r, va, vb,
            a ? *(void **)a : NULL, b ? *(void **)b : NULL);
    if (a && *(void **)a) install_ds_hooks(*(void **)a);
    return r;
}

__declspec(dllexport) S32 __stdcall AIL_waveOutOpen(void *lphWaveOut, void *lplpDigDriver, S32 devID, void *d)
{
    typedef S32 (__stdcall *F)(void *, void *, S32, void *);
    static F f = NULL; S32 r;
    if (!f) f = (F)rproc("_AIL_waveOutOpen@16");
    if (!f) return 0;
    r = f(lphWaveOut, lplpDigDriver, devID, d);
    logline("AIL_waveOutOpen(hWaveOut=%p, lplpDigDriver=%p, dev=%d, d=%p) -> %d | after: hWaveOut=%p driver=%p wFormat=%u ch=%u rate=%lu bits=%u",
            lphWaveOut, lplpDigDriver, devID, d, r,
            lphWaveOut ? *(void **)lphWaveOut : NULL,
            lplpDigDriver ? *(void **)lplpDigDriver : NULL,
            d ? *(U16 *)d : 0,
            d ? (unsigned)(((U16 *)d)[1]) : 0,
            d ? (unsigned long)(((U32 *)d)[1]) : 0,
            d ? (unsigned)(((U16 *)d)[7]) : 0);
    return r;
}

__declspec(dllexport) S32 __stdcall AIL_WAV_info(void *data, void *info)
{
    typedef S32 (__stdcall *F)(void *, void *);
    static F f = NULL; S32 r;
    if (!f) f = (F)rproc("_AIL_WAV_info@8");
    if (!f) return 0;
    r = f(data, info);
    if (info) {
        U32 *p = (U32 *)info;
        logline("AIL_WAV_info(data=%p) -> %d   [format=%08lX ptr=%08lX len=%lu rate=%lu bits=%lu ch=%lu samples=%lu block=%lu init=%08lX]",
                data, r, (unsigned long)p[0], (unsigned long)p[1], (unsigned long)p[2],
                (unsigned long)p[3], (unsigned long)p[4], (unsigned long)p[5],
                (unsigned long)p[6], (unsigned long)p[7], (unsigned long)p[8]);
    } else {
        logline("AIL_WAV_info(data=%p, info=NULL) -> %d", data, r);
    }
    return r;
}

__declspec(dllexport) HSTREAM __stdcall AIL_open_stream(HDIGDRIVER drv, const char *filename, S32 mem)
{
    typedef HSTREAM (__stdcall *F)(HDIGDRIVER, const char *, S32);
    static F f = NULL; HSTREAM r;
    if (!f) f = (F)rproc("_AIL_open_stream@12");
    if (!f) return NULL;
    logline("AIL_open_stream(drv=%p, file=\"%s\", mem=%d)", drv, filename ? filename : "(null)", mem);
    r = f(drv, filename, mem);
    logline("AIL_open_stream -> stream=%p%s", r, r ? "" : "   <-- FAILED (returned NULL)");
    return r;
}

__declspec(dllexport) void __stdcall AIL_close_stream(HSTREAM h)
{
    typedef void (__stdcall *F)(HSTREAM);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_close_stream@4");
    logline("AIL_close_stream(stream=%p)", h);
    if (f) f(h);
}

__declspec(dllexport) void __stdcall AIL_start_stream(HSTREAM h)
{
    typedef void (__stdcall *F)(HSTREAM);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_start_stream@4");
    logline("AIL_start_stream(stream=%p)", h);
    if (f) f(h);
}

__declspec(dllexport) void __stdcall AIL_pause_stream(HSTREAM h, S32 pause)
{
    typedef void (__stdcall *F)(HSTREAM, S32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_pause_stream@8");
    logline("AIL_pause_stream(stream=%p, pause=%d)", h, pause);
    if (f) f(h, pause);
}

__declspec(dllexport) void __stdcall AIL_set_stream_volume(HSTREAM h, S32 vol)
{
    typedef void (__stdcall *F)(HSTREAM, S32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_stream_volume@8");
    logline("AIL_set_stream_volume(stream=%p, volume=%d)", h, vol);
    if (f) f(h, vol);
}

__declspec(dllexport) void __stdcall AIL_set_stream_loop_count(HSTREAM h, S32 n)
{
    typedef void (__stdcall *F)(HSTREAM, S32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_stream_loop_count@8");
    logline("AIL_set_stream_loop_count(stream=%p, count=%d)", h, n);
    if (f) f(h, n);
}

__declspec(dllexport) HSAMPLE __stdcall AIL_allocate_sample_handle(HDIGDRIVER drv)
{
    typedef HSAMPLE (__stdcall *F)(HDIGDRIVER);
    static F f = NULL; HSAMPLE r;
    if (!f) f = (F)rproc("_AIL_allocate_sample_handle@4");
    if (!f) return NULL;
    r = f(drv);
    logline("AIL_allocate_sample_handle(drv=%p) -> sample=%p", drv, r);
    return r;
}

__declspec(dllexport) void __stdcall AIL_init_sample(HSAMPLE s)
{
    typedef void (__stdcall *F)(HSAMPLE);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_init_sample@4");
    logline("AIL_init_sample(sample=%p)", s);
    if (f) f(s);
}

__declspec(dllexport) void __stdcall AIL_set_sample_address(HSAMPLE s, void *start, U32 len)
{
    typedef void (__stdcall *F)(HSAMPLE, void *, U32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_sample_address@12");
    logline("AIL_set_sample_address(sample=%p, start=%p, len=%lu)", s, start, (unsigned long)len);
    if (f) f(s, start, len);
}

__declspec(dllexport) void __stdcall AIL_set_sample_type(HSAMPLE s, S32 fmt, U32 flags)
{
    typedef void (__stdcall *F)(HSAMPLE, S32, U32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_sample_type@12");
    logline("AIL_set_sample_type(sample=%p, format=0x%X, flags=0x%X)", s, fmt, flags);
    if (f) f(s, fmt, flags);
}

__declspec(dllexport) void __stdcall AIL_set_sample_playback_rate(HSAMPLE s, S32 rate)
{
    typedef void (__stdcall *F)(HSAMPLE, S32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_sample_playback_rate@8");
    logline("AIL_set_sample_playback_rate(sample=%p, rate=%d)", s, rate);
    if (f) f(s, rate);
}

__declspec(dllexport) void __stdcall AIL_set_sample_volume(HSAMPLE s, S32 vol)
{
    typedef void (__stdcall *F)(HSAMPLE, S32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_sample_volume@8");
    logline("AIL_set_sample_volume(sample=%p, volume=%d)", s, vol);
    if (f) f(s, vol);
}

__declspec(dllexport) void __stdcall AIL_set_sample_pan(HSAMPLE s, S32 pan)
{
    typedef void (__stdcall *F)(HSAMPLE, S32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_sample_pan@8");
    logline("AIL_set_sample_pan(sample=%p, pan=%d)", s, pan);
    if (f) f(s, pan);
}

__declspec(dllexport) void __stdcall AIL_set_sample_loop_count(HSAMPLE s, S32 n)
{
    typedef void (__stdcall *F)(HSAMPLE, S32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_sample_loop_count@8");
    logline("AIL_set_sample_loop_count(sample=%p, count=%d)", s, n);
    if (f) f(s, n);
}

__declspec(dllexport) void __stdcall AIL_set_sample_adpcm_block_size(HSAMPLE s, U32 bs)
{
    typedef void (__stdcall *F)(HSAMPLE, U32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_sample_adpcm_block_size@8");
    logline("AIL_set_sample_adpcm_block_size(sample=%p, block_size=%lu)", s, (unsigned long)bs);
    if (f) f(s, bs);
}

__declspec(dllexport) void __stdcall AIL_set_sample_ms_position(HSAMPLE s, S32 ms)
{
    typedef void (__stdcall *F)(HSAMPLE, S32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_set_sample_ms_position@8");
    logline("AIL_set_sample_ms_position(sample=%p, ms=%d)", s, ms);
    if (f) f(s, ms);
}

__declspec(dllexport) void __stdcall AIL_sample_ms_position(HSAMPLE s, S32 *total, S32 *cur)
{
    typedef void (__stdcall *F)(HSAMPLE, S32 *, S32 *);
    static F f = NULL; S32 t = -1, c = -1;
    if (!f) f = (F)rproc("_AIL_sample_ms_position@12");
    if (f) f(s, total ? total : &t, cur ? cur : &c);
    if (g_lines < 4000)
        logline("AIL_sample_ms_position(sample=%p) -> total=%d ms, current=%d ms",
                s, total ? *total : t, cur ? *cur : c);
}

__declspec(dllexport) S32 __stdcall AIL_sample_status(HSAMPLE s)
{
    typedef S32 (__stdcall *F)(HSAMPLE);
    static F f = NULL; S32 r;
    if (!f) f = (F)rproc("_AIL_sample_status@4");
    if (!f) return 0;
    r = f(s);
    if (g_lines < 4000)
        logline("AIL_sample_status(sample=%p) -> %d  (0=none 1=done 2=playing 3=stopped)", s, r);
    return r;
}

__declspec(dllexport) void __stdcall AIL_start_sample(HSAMPLE s)
{
    typedef void (__stdcall *F)(HSAMPLE);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_start_sample@4");
    logline("AIL_start_sample(sample=%p)", s);
    if (f) f(s);
}

__declspec(dllexport) void __stdcall AIL_stop_sample(HSAMPLE s)
{
    typedef void (__stdcall *F)(HSAMPLE);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_stop_sample@4");
    logline("AIL_stop_sample(sample=%p)", s);
    if (f) f(s);
}

__declspec(dllexport) void __stdcall AIL_resume_sample(HSAMPLE s)
{
    typedef void (__stdcall *F)(HSAMPLE);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_resume_sample@4");
    logline("AIL_resume_sample(sample=%p)", s);
    if (f) f(s);
}

__declspec(dllexport) void __stdcall AIL_end_sample(HSAMPLE s)
{
    typedef void (__stdcall *F)(HSAMPLE);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_end_sample@4");
    logline("AIL_end_sample(sample=%p)", s);
    if (f) f(s);
}

__declspec(dllexport) void *__stdcall AIL_mem_alloc_lock(U32 size)
{
    typedef void *(__stdcall *F)(U32);
    static F f = NULL; void *r;
    if (!f) f = (F)rproc("_AIL_mem_alloc_lock@4");
    if (!f) return NULL;
    r = f(size);
    logline("AIL_mem_alloc_lock(size=%lu) -> %p", (unsigned long)size, r);
    return r;
}

__declspec(dllexport) void __stdcall AIL_mem_free_lock(void *p)
{
    typedef void (__stdcall *F)(void *);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_mem_free_lock@4");
    logline("AIL_mem_free_lock(ptr=%p)", p);
    if (f) f(p);
}

__declspec(dllexport) void __stdcall AIL_redbook_stop(U32 dev)
{
    typedef void (__stdcall *F)(U32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_redbook_stop@4");
    logline("AIL_redbook_stop(dev=%lu)", (unsigned long)dev);
    if (f) f(dev);
}

__declspec(dllexport) void __stdcall AIL_redbook_close(U32 dev)
{
    typedef void (__stdcall *F)(U32);
    static F f = NULL;
    if (!f) f = (F)rproc("_AIL_redbook_close@4");
    logline("AIL_redbook_close(dev=%lu)", (unsigned long)dev);
    if (f) f(dev);
}

/* ====================================================================== *
 * winmm!mmioOpenA share-mode shim
 * ----------------------------------------------------------------------
 * WHY
 *   Hedz.exe's level-music setup (0045FE60) builds
 *
 *       D:\Hedz\Music\<level>.mus
 *
 *   and then does two things with that ONE file, in this order:
 *
 *     0048BBC0  mmioOpenA(path, NULL, MMIO_EXCLUSIVE)   <- held all level
 *     00460A30  fopen(path, ...)                        <- the area table
 *
 *   MMIO_EXCLUSIVE makes mmioOpen open with FILE_SHARE_NONE (dwShareMode 0),
 *   and on Windows NT a handle opened that way denies EVERY later open of the
 *   file - including the game's own fopen one instruction later.  Process
 *   Monitor shows exactly that:
 *
 *     CreateFile D:\Hedz\Music\1.mus  -> SUCCESS
 *     CreateFile D:\Hedz\Music\1.mus  -> SHARING VIOLATION
 *
 *   fopen then returns NULL, 00460A30 returns 0, the music-area table is never
 *   built (005986F4h stays NULL), and the per-frame music state machine
 *   (0045FF60) bails on its third gate every single tick.  The music object is
 *   left created-but-never-started, which is why the tick only ever does the
 *   32768-byte read/rewind loop and Play is never called.
 *
 * WHAT IT DOES
 *   Hedz.exe calls mmioOpenA through IAT slot 004C035Ch; this patches that slot
 *   to strip MMIO_EXCLUSIVE and ask for MMIO_DENYNONE instead.  Nothing on disk
 *   is modified and the original function still does the work - the shim only
 *   changes one sharing argument at runtime.  This is the same class of fix as
 *   the README-level "force share mode" compatibility shims used for other
 *   Win9x titles, and it is what makes the second open legal.
 * ====================================================================== */
#define MMIO_EXCLUSIVE_ 0x00000010u
#define MMIO_DENYNONE_  0x00000040u
#define IAT_MMIOOPENA_  0x004C035Cu
#define IMAGE_BASE_     0x00400000u

typedef void *(WINAPI *FN_MMIOOPEN)(char *, void *, unsigned long);
static FN_MMIOOPEN g_origMmioOpenA = NULL;
static int         g_mmioHooked    = 0;

static void *WINAPI Hook_mmioOpenA(char *name, void *info, unsigned long flags)
{
    unsigned long f = flags;
    if (f & MMIO_EXCLUSIVE_) {
        f = (f & ~MMIO_EXCLUSIVE_) | MMIO_DENYNONE_;
        logline("SHIM  mmioOpenA(\"%s\", flags=0x%lX) -> MMIO_DENYNONE (flags=0x%lX)",
                name ? name : "(null)", flags, f);
    }
    return g_origMmioOpenA(name, info, f);
}

static void install_mmio_shim(void)
{
    unsigned char *base = (unsigned char *)GetModuleHandleA(NULL);
    void **slot;
    DWORD  old = 0;
    HMODULE winmm;

    if (g_mmioHooked) return;
    winmm = GetModuleHandleA("winmm.dll");
    if (!base) return;
    if (!winmm) { logline("SHIM  mmioOpenA: winmm.dll not loaded yet - will retry"); return; }

    slot = (void **)(base + (IAT_MMIOOPENA_ - IMAGE_BASE_));
    /* Sanity: the slot must already point into winmm.dll, otherwise our VA is
       wrong (different build) and patching it would corrupt the process.     */
    if ((unsigned char *)*slot < (unsigned char *)winmm ||
        (unsigned char *)*slot > (unsigned char *)winmm + 0x400000) {
        logline("SHIM  mmioOpenA: IAT slot %p does not point into winmm.dll (%p) - NOT patched",
                *slot, (void *)winmm);
        g_mmioHooked = -1;   /* do not retry */
        return;
    }
    g_origMmioOpenA = (FN_MMIOOPEN)*slot;
    if (!VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &old)) {
        logline("SHIM  mmioOpenA: VirtualProtect failed (%lu)", (unsigned long)GetLastError());
        return;
    }
    *slot = (void *)Hook_mmioOpenA;
    VirtualProtect(slot, sizeof(void *), old, &old);
    g_mmioHooked = 1;
    logline("SHIM  winmm!mmioOpenA hooked (IAT %p, real=%p) - MMIO_EXCLUSIVE relaxed",
            slot, (void *)g_origMmioOpenA);
}

/* ====================================================================== *
 * Hedz.exe music-state poller
 * ----------------------------------------------------------------------
 * WHY
 *   Static analysis of the retail build says the level-music engine is this:
 *
 *     obj = 005B9380h   (the "music object")
 *       obj+04h hmmio                  obj+10h bufSize (256000)
 *       obj+08h malloc'd src buffer    obj+14h file position
 *       obj+0Ch LPDIRECTSOUNDBUFFER    obj+2Dh PRIMED/PLAYING flag
 *
 *     0048BBC0(obj, path, 256000)  create: mmioOpenA(MMIO_EXCLUSIVE) +
 *                                  CreateSoundBuffer(22050/16/2 PCM)
 *                                  and CLEARS obj+2Dh
 *     0048BCF0(obj, offset)        fill the buffer, Play(LOOPING), then SETS
 *                                  obj+2Dh = 1
 *     0048BE30(obj)                steady-state refill/mixer
 *
 *   The per-frame music tick (00475B10) branches on obj+2Dh (== 005B93ADh):
 *     != 0 -> call 0048BE30  (keep playing)
 *     == 0 -> mmioRead(hmmio, buf, 32768); mmioSeek(hmmio,0,0) at EOF
 *
 *   So obj+2Dh == 0 does NOT mean "idle": it means "created but never started",
 *   and the 32768-byte read/rewind loop is what a never-started music object
 *   does forever.  That is exactly the file activity measured on this machine
 *   (32 KB reads, repeating, no sound) - so the readable question is now just
 *   WHERE the interactive-music state machine fails to start a track.
 *
 *   005DCB7Fh is that state machine's state; 0045FF60 is its per-frame update.
 *   This poller samples the engine's own globals so its behaviour becomes a
 *   timeline instead of an inference.
 *
 * HOW
 *   Reads Hedz.exe's own data (base from GetModuleHandleA(NULL), preferred base
 *   0x400000) on a timer, guarded by SEH, and logs every change.  Read-only -
 *   it observes the game's state machine, it never alters it.
 * ====================================================================== */
typedef struct { unsigned int va; const char *name; int wide; } WATCH;

static const WATCH g_watch[] = {
    { 0x5E4A5E, "musicEnabled          (005E4A5Eh)", 0 },
    { 0x5B93AD, "MusicObj.PRIMED/PLAYING(005B93ADh)", 0 },
    { 0x5DCB7F, "MusicState            (005DCB7Fh)", 1 },
    { 0x5DCB7E, "MusicArea.current     (005DCB7Eh)", 0 },
    { 0x5DCB7D, "MusicArea.prev        (005DCB7Dh)", 0 },
    { 0x5DCB73, "MusicFlag_73          (005DCB73h)", 0 },
    { 0x598704, "MusicFadeCounter      (00598704h)", 0 },
    { 0x4CE47C, "MusicTransitionFlag   (004CE47Ch)", 0 },
    { 0x5B9384, "MusicObj.hmmio        (005B9384h)", 1 },
    { 0x5B9388, "MusicObj.buf          (005B9388h)", 1 },
    { 0x5B938C, "MusicObj.bufSize      (005B938Ch)", 1 },
    { 0x5B9394, "MusicObj.filePos      (005B9394h)", 1 },
    { 0x5B9398, "MusicObj.playPos      (005B9398h)", 1 },
    { 0x5B939C, "MusicObj.writtenPos   (005B939Ch)", 1 },
    { 0x5B93A0, "MusicObj.f20          (005B93A0h)", 1 },
    { 0x5B93A4, "MusicObj.f24          (005B93A4h)", 1 },
    { 0x5986F4, "MusicAreaListHead     (005986F4h)", 1 },
    { 0x5DF318, "levelObjPtr           (005DF318h)", 1 },
    { 0x4D8248, "gate_4D8248           (004D8248h)", 1 },
    { 0x5E45D0, "gate_5E45D0           (005E45D0h)", 1 },
    { 0x4D1648, "tickCountdown         (004D1648h)", 0 },
};
#define NWATCH ((int)(sizeof(g_watch) / sizeof(g_watch[0])))

static DWORD g_watchLast[NWATCH];
static int   g_watchHave = 0;
static int   g_pollerRun = 0;

static DWORD WINAPI state_poller(LPVOID param)
{
    unsigned char *base;
    int i, snap = 0;
    (void)param;
    for (;;) {
        Sleep(250);
        base = (unsigned char *)GetModuleHandleA(NULL);   /* Hedz.exe */
        if (!base) continue;
        if (g_mmioHooked == 0) install_mmio_shim();
        snap++;
        __try {
            for (i = 0; i < NWATCH; i++) {
                DWORD v;
                if (g_watch[i].wide) v = *(DWORD *)(base + (g_watch[i].va - 0x400000));
                else                 v = (DWORD)(*(unsigned char *)(base + (g_watch[i].va - 0x400000)));
                if (!g_watchHave || v != g_watchLast[i]) {
                    g_watchLast[i] = v;
                    logline("STATE  %s = 0x%08lX", g_watch[i].name, (unsigned long)v);
                }
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            logline("STATE  poll faulted - image ranges not all mapped");
            return 0;
        }
        g_watchHave = 1;
        if ((snap % 8) == 0) {   /* ~2 s heartbeat: shows the file position advancing */
            logline("STATE  ..heartbeat filePos=%lu primed=%lu state=%lu area=%lu",
                    (unsigned long)g_watchLast[11], (unsigned long)g_watchLast[1],
                    (unsigned long)g_watchLast[2], (unsigned long)g_watchLast[3]);
        }
    }
    return 0;
}

/* ----------------------------------------------------------------- DllMain -- */
BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = hinst;
        GetModuleFileNameA(hinst, g_dir, MAX_PATH);
        {   /* strip the DLL filename, keep the trailing backslash */
            char *p = g_dir + lstrlenA(g_dir);
            while (p > g_dir && *p != '\\') p--;
            if (*p == '\\') *(p + 1) = 0;
        }
        InitializeCriticalSection(&g_cs);
        g_csInit = 1;
        g_t0 = GetTickCount();
        logline("================ HEDZ mss32 logging proxy loaded ================");
        logline("proxy     : %s", g_dir);
        logline("pid       : %lu", (unsigned long)GetCurrentProcessId());
        if (!g_pollerRun) {
            g_pollerRun = 1;
            CreateThread(NULL, 0, state_poller, NULL, 0, NULL);
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        logline("================ proxy unloaded ================");
        if (g_csInit) { DeleteCriticalSection(&g_cs); g_csInit = 0; }
        if (g_log) { fclose(g_log); g_log = NULL; }
    }
    return TRUE;
}
