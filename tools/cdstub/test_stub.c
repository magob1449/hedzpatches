/* test_stub.c - 32-bit functional test for the HEDZ winmm proxy.
   Sits in the same folder as the built winmm.dll + winmm_real.dll;
   the loader's app-dir-first search resolves "winmm.dll" to the proxy. */
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#pragma warning(disable:4273)

typedef MCIERROR (WINAPI *FN_SSA)(LPCSTR, LPSTR, UINT, HWND);

static FN_SSA pSend;

static void T(const char *cmd, const char *expect)
{
    char buf[128] = "";
    MCIERROR rc = pSend(cmd, buf, (UINT)sizeof(buf), NULL);
    printf("%-34s rc=%lu  ->'%s'%s%s\n", cmd, (unsigned long)rc, buf,
           expect ? "  [expect " : "", expect ? expect : "");
}

int main(void)
{
    HMODULE h = LoadLibraryA("winmm.dll");
    if (!h) { printf("FAIL: LoadLibrary(winmm.dll)\n"); return 1; }
    pSend = (FN_SSA)GetProcAddress(h, "mciSendStringA");
    if (!pSend) { printf("FAIL: GetProcAddress(mciSendStringA)\n"); return 1; }

    T("open cdaudio alias testcd",  "rc=0");
    T("status testcd media present","'true'");
    T("status testcd mode",         "'stopped'");
    T("status testcd ready",        "'true'");
    T("play testcd",                "rc=0");
    T("status testcd mode",         "'playing'");
    T("status testcd position",     "advancing number");
    T("set testcd time format tmsf","rc=0");
    T("seek testcd to start",       "rc=0");
    T("close testcd",               "rc=0");

    T("sysinfo all quantity",       "forwarded to real winmm");
    printf("DONE\n");
    FreeLibrary(h);
    return 0;
}
