/*
 * ml734 Theorafile call tracer (x86-64 PE, opt-in diagnostic).
 *
 * The intro video decodes and plays, the file reaches a clean
 * STATUS_END_OF_FILE after 37,530 reads, the decoder then stops reading --
 * and the game never leaves VideoContext. The filesystem layer is therefore
 * exonerated, but file EOF is NOT decoder EOS: we still cannot see whether
 * tf_eos() is even called, what it returns, or whether tf_close() happens.
 *
 * A counter-only tail-jump trampoline cannot settle that. "tf_eos was called
 * 900 times" is equally consistent with it returning false forever AND with
 * it returning true while the managed side ignores the result. Only the
 * RETURN VALUE splits those, so these are call-and-return wrappers.
 *
 * Written in C and compiled, not hand-encoded: the ABI details (shadow space,
 * alignment, which registers survive the inner call) are exactly the kind of
 * thing that is easy to get subtly wrong by hand and expensive to debug on a
 * device.
 *
 * The loader fills tft_real[] with the original export addresses and rewrites
 * libtheorafile's export address table to point at these wrappers. Records go
 * into a plain ring buffer that native code reads; nothing here calls back
 * into the host.
 */
#include <stdint.h>

#define TFT_SLOTS 5
enum { TF_FOPEN = 0, TF_READVIDEO, TF_READAUDIO, TF_EOS, TF_CLOSE };

/* Filled in by the loader before any wrapper can run. */
__declspec(dllexport) void *tft_real[TFT_SLOTS];

/* Reporting goes out through OutputDebugStringA, which lands in the host log
 * directly. The alternative -- a ring buffer read by native code -- needs the
 * reader to learn this module's base, and that tracking lives in a third build
 * (the emulator), so it would have meant touching three build chains to print
 * five numbers. Bounded and state-change-only, so a per-frame decode call
 * cannot turn logging into the thing being measured. */
__declspec(dllimport) void __stdcall OutputDebugStringA(const char *);

static char *tft_hex(char *o, unsigned long long v)
{
    static const char *H = "0123456789abcdef";
    int i, lead = 0;
    *o++ = '0'; *o++ = 'x';
    for (i = 60; i >= 0; i -= 4)
    {
        int d = (int)((v >> i) & 0xf);
        if (d || lead || i == 0) { *o++ = H[d]; lead = 1; }
    }
    return o;
}

static char *tft_str(char *o, const char *s)
{
    while (*s) *o++ = *s++;
    return o;
}

/* Ring buffer retained so a native reader can be added later without changing
 * the wrappers. */
typedef struct {
    uint32_t idx;
    uint32_t reserved;
    uint64_t handle;
    uint64_t result;
    uint64_t seq;
} tft_rec;

__declspec(dllexport) volatile uint64_t tft_seq;
__declspec(dllexport) tft_rec tft_ring[256];
__declspec(dllexport) volatile uint64_t tft_calls[TFT_SLOTS];
/* LIVE state, deliberately outside the capped event log. The cap exists so a
 * per-frame decode call cannot drown the log, but it must never be able to
 * hide a late tf_eos 0->1 or a terminal read result -- so the last value of
 * every function is always current here, however many calls were capped. */
__declspec(dllexport) volatile uint64_t tft_last[TFT_SLOTS];
__declspec(dllexport) volatile uint64_t tft_last_handle[TFT_SLOTS];
__declspec(dllexport) volatile uint64_t tft_magic = 0x5446545241434531ULL; /* "TFTRACE1" */

/* Record first call, every state change, and every terminal result -- not
 * every call. tf_readvideo runs per frame; logging all of it would drown the
 * log and change the timing we are measuring. */
static void tft_emit(const char *tag, uint32_t idx, uint64_t handle, uint64_t result, uint64_t n)
{
    static const char * const nm[TFT_SLOTS] =
        { "tf_fopen", "tf_readvideo", "tf_readaudio", "tf_eos", "tf_close" };
    char buf[200], *o = buf;
    o = tft_str( o, "[tf-trace] ml735 " );
    o = tft_str( o, tag );
    o = tft_str( o, " " );
    o = tft_str( o, nm[idx] );
    o = tft_str( o, " call#" );   o = tft_hex( o, n );
    o = tft_str( o, " handle=" ); o = tft_hex( o, handle );
    o = tft_str( o, " -> " );     o = tft_hex( o, result );
    if (idx == TF_EOS && result) o = tft_str( o, "   <== EOS TRUE" );
    if (idx == TF_CLOSE)         o = tft_str( o, "   <== CLOSED" );
    *o++ = '\n'; *o = 0;
    OutputDebugStringA( buf );
}

static void tft_note(uint32_t idx, uint64_t handle, uint64_t result)
{
    static uint64_t seen[TFT_SLOTS];
    uint64_t prev = tft_last[idx];
    uint64_t n = ++tft_calls[idx];

    /* live state first, always */
    tft_last[idx] = result;
    tft_last_handle[idx] = handle;

    /* ml735: the previous build capped at 64 records per function and treated
     * every zero return as interesting. tf_readvideo returns 0 whenever no
     * frame is ready, which is most calls, so the budget was spent within
     * seconds and the log stopped at call #65 of many thousands -- exactly the
     * "a cap must never hide a late tf_eos 0->1" failure. Three rules now:
     *
     *   1. a TRANSITION (result != previous) is always reported, uncapped.
     *      This is the event we are hunting and it is rare by construction.
     *   2. the first call of each function is reported once.
     *   3. a periodic heartbeat proves the function is still being called and
     *      carries the live totals, so silence is never ambiguous.
     */
    if (result != prev)
    {
        tft_emit( "CHANGE", idx, handle, result, n );
        /* ml736: when end-of-stream first goes true, dump EVERY counter and
         * last return in one place. Without this the log only shows state
         * changes and a 4,096-call heartbeat, so "the caller stopped polling"
         * and "the caller kept polling and kept getting the same answer" look
         * identical -- and so do "the audio reader was called once" and "it was
         * called 4,000 times returning the same count". Both distinctions were
         * asserted from the log when the log could not support them. The
         * counters already exist; this just prints them at the one moment that
         * matters. */
        if (idx == TF_EOS && result)
        {
            int k;
            for (k = 0; k < TFT_SLOTS; k++)
                tft_emit( "ATEOS ", (uint32_t)k, tft_last_handle[k], tft_last[k], tft_calls[k] );
        }
        return;
    }
    if (n == 1) { tft_emit( "FIRST ", idx, handle, result, n ); return; }
    if (!(n % 4096)) { tft_emit( "ALIVE ", idx, handle, result, n ); return; }
    (void)seen;
}

typedef int  (*fn_fopen)(const char *, void **);
typedef int  (*fn_rv)(void *, void *, int);
typedef int  (*fn_ra)(void *, void *, int);
typedef int  (*fn_eos)(void *);
typedef void (*fn_close)(void **);

__declspec(dllexport) int tft_tf_fopen(const char *path, void **out)
{
    int r = ((fn_fopen)tft_real[TF_FOPEN])(path, out);
    tft_note(TF_FOPEN, (uint64_t)(uintptr_t)(out ? *out : 0), (uint64_t)(uint32_t)r);
    return r;
}

__declspec(dllexport) int tft_tf_readvideo(void *f, void *buf, int n)
{
    int r = ((fn_rv)tft_real[TF_READVIDEO])(f, buf, n);
    tft_note(TF_READVIDEO, (uint64_t)(uintptr_t)f, (uint64_t)(uint32_t)r);
    return r;
}

__declspec(dllexport) int tft_tf_readaudio(void *f, void *buf, int n)
{
    int r = ((fn_ra)tft_real[TF_READAUDIO])(f, buf, n);
    tft_note(TF_READAUDIO, (uint64_t)(uintptr_t)f, (uint64_t)(uint32_t)r);
    return r;
}

__declspec(dllexport) int tft_tf_eos(void *f)
{
    int r = ((fn_eos)tft_real[TF_EOS])(f);
    tft_note(TF_EOS, (uint64_t)(uintptr_t)f, (uint64_t)(uint32_t)r);
    return r;
}

__declspec(dllexport) void tft_tf_close(void **f)
{
    tft_note(TF_CLOSE, (uint64_t)(uintptr_t)(f ? *f : 0), 0);
    ((fn_close)tft_real[TF_CLOSE])(f);
}


/* ================= ml736 FAudio voice tracing =================
 *
 * The cutscene is silent while the splash is not, and the video's audio
 * reader was seen returning a count once. FNA streams video audio through a
 * DynamicSoundEffectInstance, which polls FAudioSourceVoice_GetState,
 * compares BuffersQueued, and only then asks managed code for more data --
 * so the queue state is what decides whether playback ever completes.
 *
 * Every line carries the voice pointer, because the splash and the video are
 * different voices and conflating them would make the trace meaningless.
 */
typedef struct { void *ctx; uint32_t BuffersQueued; uint64_t SamplesPlayed; } FAVoiceState;
typedef struct { uint32_t Flags; uint32_t AudioBytes; const uint8_t *pAudioData; } FABufferHead;

enum { FA_CREATE = 0, FA_START, FA_SUBMIT, FA_GETSTATE, FA_STOP, FA_DESTROY, FA_SLOTS };
__declspec(dllexport) void *fa_real[FA_SLOTS];
__declspec(dllexport) volatile uint64_t fa_calls[FA_SLOTS];

static void fa_emit(const char *what, void *voice, uint64_t a, uint64_t b, uint64_t n)
{
    char buf[200], *o = buf;
    o = tft_str( o, "[fa-trace] ml736 " );
    o = tft_str( o, what );
    o = tft_str( o, " voice=" ); o = tft_hex( o, (uint64_t)(uintptr_t)voice );
    o = tft_str( o, " a=" );     o = tft_hex( o, a );
    o = tft_str( o, " b=" );     o = tft_hex( o, b );
    o = tft_str( o, " call#" );  o = tft_hex( o, n );
    *o++ = '\n'; *o = 0;
    OutputDebugStringA( buf );
}

typedef uint32_t (*fn_create)(void*, void**, const void*, uint32_t, float, void*, const void*, const void*);
typedef uint32_t (*fn_start)(void*, uint32_t, uint32_t);
typedef uint32_t (*fn_submit)(void*, const void*, const void*);
typedef void     (*fn_getstate)(void*, FAVoiceState*, uint32_t);
typedef uint32_t (*fn_stop)(void*, uint32_t, uint32_t);
typedef void     (*fn_destroy)(void*);

__declspec(dllexport) uint32_t fa_CreateSourceVoice(void *fa, void **ppv, const void *fmt,
        uint32_t flags, float ratio, void *cb, const void *sends, const void *fx)
{
    uint32_t r = ((fn_create)fa_real[FA_CREATE])(fa, ppv, fmt, flags, ratio, cb, sends, fx);
    fa_emit( "CREATE  ", ppv ? *ppv : 0, r, (uint64_t)(uintptr_t)cb, ++fa_calls[FA_CREATE] );
    return r;
}

__declspec(dllexport) uint32_t fa_Start(void *v, uint32_t f, uint32_t op)
{
    uint32_t r = ((fn_start)fa_real[FA_START])(v, f, op);
    fa_emit( "START   ", v, r, 0, ++fa_calls[FA_START] );
    return r;
}

__declspec(dllexport) uint32_t fa_SubmitSourceBuffer(void *v, const void *b, const void *wma)
{
    uint32_t bytes = b ? ((const FABufferHead *)b)->AudioBytes : 0;
    uint32_t r = ((fn_submit)fa_real[FA_SUBMIT])(v, b, wma);
    fa_emit( "SUBMIT  ", v, bytes, r, ++fa_calls[FA_SUBMIT] );
    return r;
}

/* Polled every frame, so report only when the queue depth actually changes or
 * playback stalls -- otherwise this becomes the thing being measured. */
__declspec(dllexport) void fa_GetState(void *v, FAVoiceState *st, uint32_t flags)
{
    static void *last_voice; static uint32_t last_q = 0xffffffff; static uint64_t last_played;
    uint64_t n = ++fa_calls[FA_GETSTATE];
    ((fn_getstate)fa_real[FA_GETSTATE])(v, st, flags);
    if (!st) return;
    if (v != last_voice || st->BuffersQueued != last_q ||
        (!(n % 4096) && st->SamplesPlayed == last_played))
    {
        fa_emit( "STATE   ", v, st->BuffersQueued, st->SamplesPlayed, n );
        last_voice = v; last_q = st->BuffersQueued; last_played = st->SamplesPlayed;
    }
}

__declspec(dllexport) uint32_t fa_Stop(void *v, uint32_t f, uint32_t op)
{
    uint32_t r = ((fn_stop)fa_real[FA_STOP])(v, f, op);
    fa_emit( "STOP    ", v, r, 0, ++fa_calls[FA_STOP] );
    return r;
}

__declspec(dllexport) void fa_DestroyVoice(void *v)
{
    fa_emit( "DESTROY ", v, 0, 0, ++fa_calls[FA_DESTROY] );
    ((fn_destroy)fa_real[FA_DESTROY])(v);
}

/* ---------------------------------------------------------------------------
 * Steam Overlay live callback delivery (steamclient64.dll).
 *
 * Steamworks games poll Steam_BGetCallback / Steam_FreeLastCallback every frame
 * (both legacy SteamAPI_RunCallbacks and SDK 1.50+ ManualDispatch). When the
 * user accepts an invite or clicks Join in Madeira's Steam Overlay while a
 * game is running, Swift writes C:\madeira\steam_join_cb.bin and the next poll
 * delivers GameLobbyJoinRequested_t (333) or GameRichPresenceJoinRequested_t
 * (337) directly into the running game.
 * --------------------------------------------------------------------------- */

#define ST_SLOTS 2
enum { ST_BGET = 0, ST_FREE };

__declspec(dllexport) void *st_real[ST_SLOTS];

__declspec(dllimport) void *__stdcall CreateFileA(
    const char *, uint32_t, uint32_t, void *, uint32_t, uint32_t, void *);
__declspec(dllimport) int __stdcall ReadFile(
    void *, void *, uint32_t, uint32_t *, void *);
__declspec(dllimport) int __stdcall CloseHandle(void *);
__declspec(dllimport) int __stdcall DeleteFileA(const char *);

#pragma pack(push, 8)
typedef struct {
    int32_t  m_hSteamUser;
    int32_t  m_iCallback;
    uint8_t *m_pubParam;
    int32_t  m_cubParam;
} SteamCallbackMsg;

typedef struct {
    uint64_t m_steamIDLobby;
    uint64_t m_steamIDFriend;
} SteamLobbyJoinReq;

typedef struct {
    uint64_t m_steamIDFriend;
    char     m_rgchConnect[256];
} SteamRichPresenceJoinReq;
#pragma pack(pop)

#pragma pack(push, 1)
typedef struct {
    uint32_t magic;       /* 0x4D4A4E31 ('MJN1') */
    int32_t  callback_id; /* 333 = LobbyJoin, 337 = RichPresenceJoin */
    uint64_t lobby_id;
    uint64_t friend_id;
    char     connect[256];
} MadeiraJoinPayload;
#pragma pack(pop)

typedef uint8_t (*fn_st_bget)(int32_t, SteamCallbackMsg *, void *, void *);
typedef void    (*fn_st_free)(int32_t, void *);

static int32_t                  st_last_user = 1;
static int32_t                  st_injected_pipe = 0;
static uint64_t                 st_polls = 0;
static SteamLobbyJoinReq        st_lobby_req;
static SteamRichPresenceJoinReq st_rp_req;

static void st_emit(const char *tag, uint64_t a, uint64_t b)
{
    char buf[128], *p = buf;
    p = tft_str( p, "[steam-overlay] " );
    p = tft_str( p, tag );
    p = tft_str( p, " a=" ); p = tft_hex( p, a );
    p = tft_str( p, " b=" ); p = tft_hex( p, b );
    *p++ = '\n'; *p = 0;
    OutputDebugStringA( buf );
}

__declspec(dllexport) int st_BGetCallback(int32_t pipe, SteamCallbackMsg *cb, void *a3, void *a4)
{
    uint8_t r = ((fn_st_bget)st_real[ST_BGET])(pipe, cb, a3, a4);
    if (r)
    {
        if (cb && cb->m_hSteamUser > 0)
            st_last_user = cb->m_hSteamUser;
        return 1;
    }

    if (pipe > 0 && cb && st_injected_pipe == 0)
    {
        uint64_t n = ++st_polls;
        if (n > 120 && (n & 31) == 0)
        {
            void *h = CreateFileA( "C:\\madeira\\steam_join_cb.bin",
                                   0x80000000U, 7U, 0, 3U, 0, 0 );
            if (h != (void *)(intptr_t)-1)
            {
                MadeiraJoinPayload payload;
                uint32_t nread = 0;
                int ok = ReadFile( h, &payload, sizeof(payload), &nread, 0 );
                CloseHandle( h );
                DeleteFileA( "C:\\madeira\\steam_join_cb.bin" );

                if (ok && nread >= 24 && payload.magic == 0x4D4A4E31U)
                {
                    if (payload.callback_id == 333 && payload.lobby_id != 0)
                    {
                        st_lobby_req.m_steamIDLobby  = payload.lobby_id;
                        st_lobby_req.m_steamIDFriend = payload.friend_id;
                        cb->m_hSteamUser = st_last_user ? st_last_user : 1;
                        cb->m_iCallback  = 333;
                        cb->m_pubParam   = (uint8_t *)&st_lobby_req;
                        cb->m_cubParam   = (int32_t)sizeof(st_lobby_req);
                        st_injected_pipe = pipe;
                        st_emit( "GameLobbyJoinRequested_t", payload.lobby_id, payload.friend_id );
                        return 1;
                    }
                    else if (payload.callback_id == 337 && payload.connect[0] != 0)
                    {
                        int i;
                        st_rp_req.m_steamIDFriend = payload.friend_id;
                        for (i = 0; i < 255 && payload.connect[i]; i++)
                            st_rp_req.m_rgchConnect[i] = payload.connect[i];
                        st_rp_req.m_rgchConnect[i] = 0;
                        cb->m_hSteamUser = st_last_user ? st_last_user : 1;
                        cb->m_iCallback  = 337;
                        cb->m_pubParam   = (uint8_t *)&st_rp_req;
                        cb->m_cubParam   = (int32_t)sizeof(st_rp_req);
                        st_injected_pipe = pipe;
                        st_emit( "GameRichPresenceJoinRequested_t", payload.friend_id, (uint64_t)i );
                        return 1;
                    }
                }
            }
        }
    }
    return 0;
}

__declspec(dllexport) void st_FreeLastCallback(int32_t pipe, void *a2)
{
    if (st_injected_pipe != 0 && st_injected_pipe == pipe)
    {
        st_injected_pipe = 0;
        return;
    }
    ((fn_st_free)st_real[ST_FREE])(pipe, a2);
}

int __stdcall DllMainCRTStartup(void *h, unsigned r, void *x) { (void)h;(void)r;(void)x; return 1; }
