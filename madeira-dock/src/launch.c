/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * ml1820: launch through Valve's real app manager after authenticated
 * entitlement checks. The installed game, API DLLs and DRM remain unchanged.
 */
#include "launch.h"
#include "scm.h"
#include "validation.h"
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define SH_CONFIG_WAIT_MS (2ULL * 60 * 1000)   /* ml2011 */
#define SH_CONFIG_RETRY_MS 5000
#define SH_SESSION_WAIT_MS (3ULL * 60 * 1000)  /* ml2015 */
#define SH_SESSION_RETRY_MS 15000

#ifdef _WIN64
typedef void *(__thiscall *get_manager_fn)(void *, int32_t, int32_t);
typedef int32_t (__thiscall *install_dir_fn)(void *, uint32_t, char *, int32_t);
typedef uint64_t (__thiscall *launch_fn)(void *, const uint64_t *, uint32_t, int32_t, const char *);
typedef bool (__thiscall *running_fn)(void *, const uint64_t *);
typedef bool (__thiscall *call_result_fn)(void *, int32_t, uint64_t, void *, int32_t, int32_t, bool *);

static bool method_is(HMODULE module, void *object, unsigned slot, uintptr_t rva)
{
    return dock_method_is((uintptr_t)module, object, slot, rva);
}

struct saved_value { HKEY key; const wchar_t *name; DWORD previous, written; bool existed, changed; };
static bool publish(struct saved_value *v, DWORD value)
{
    DWORD type = 0, size = sizeof(DWORD);
    LSTATUS status = RegQueryValueExW(v->key, v->name, NULL, &type, (BYTE *)&v->previous, &size);
    v->existed = status == ERROR_SUCCESS;
    if ((v->existed && (type != REG_DWORD || size != sizeof(DWORD))) ||
        (!v->existed && status != ERROR_FILE_NOT_FOUND)) return false;
    v->written = value;
    if (RegSetValueExW(v->key, v->name, 0, REG_DWORD, (BYTE *)&value, sizeof(value)) != ERROR_SUCCESS) return false;
    v->changed = true;
    return true;
}

static bool restore(struct saved_value *v)
{
    if (!v->changed) return true;
    DWORD current = 0, size = sizeof(current), type = 0;
    if (RegQueryValueExW(v->key, v->name, NULL, &type, (BYTE *)&current, &size) != ERROR_SUCCESS ||
        type != REG_DWORD || current != v->written) return false;
    LSTATUS status = v->existed ?
        RegSetValueExW(v->key, v->name, 0, REG_DWORD, (BYTE *)&v->previous, sizeof(DWORD)) :
        RegDeleteValueW(v->key, v->name);
    return status == ERROR_SUCCESS;
}

static volatile LONG interrupted;
static BOOL WINAPI on_control(DWORD control)
{
    if (control != CTRL_C_EVENT && control != CTRL_BREAK_EVENT) return FALSE;
    InterlockedExchange(&interrupted, 1);
    return TRUE;
}

/* ml1990: ask Valve's client to prepare the user's licensed custom
 * executables (CEG) before LaunchApp, as desktop Steam does. Valve's client
 * reads the files to prepare from the app manifest, extracts their DRM
 * identifiers, and requests the per-user binaries from Valve with this
 * account's own licence. Dock never creates, alters or bypasses them.
 *
 * IClientUserMap slot 71 (both pinned builds): EResult(uint32 AppID,
 * bool bForce, bool bFailFastWhenBusy, uint32 *pJobsStarted). The wrapper
 * sends the pointer's value to the in-process engine, which writes the job
 * count before the call returns; it is never NULL. bForce=false keeps
 * Valve's own identifier extraction (true skips it and reports success
 * without preparing anything). bFailFastWhenBusy=false keeps Valve's own
 * server retry policy; this host bounds the total wait instead.
 */
#define SH_CEG_WAIT_MS (5ULL * 60 * 1000)
#define SH_CEG_BUSY_RETRY_MS 10000
typedef int32_t (__thiscall *ceg_request_fn)(void *, uint32_t, bool, bool, uint32_t *);

static bool wide_flag(const wchar_t *name, wchar_t expected)
{
    wchar_t value[4] = {0};
    return GetEnvironmentVariableW(name, value, 4) == 1 && value[0] == expected;
}

/* Returns 0 once every started job reported success, otherwise 49 (or 12
 * for a malformed callback). Only numeric results are reported: no paths.
 */
static int prepare_custom_binaries(HMODULE module, void *client_user,
                                   const struct sh_api *api, const struct sh_observer *o,
                                   int32_t pipe, uint32_t appid,
                                   const struct dock_client_layout *layout)
{
    if (!layout->ceg_request || !method_is(module, client_user, 71, layout->ceg_request)) {
        o->event("ceg-unsupported-client", 1);
        o->event("ceg-result", -2);
        return 49;
    }
    struct sh_ceg_progress progress = {0};
    uint64_t begin = o->now_ms(), retry_at = begin;
    bool waiting = false;
    unsigned busy = 0, logged_jobs = 0;
    int32_t logged_reply = INT32_MIN;
    while (!InterlockedCompareExchange(&interrupted, 0, 0)) {
        uint64_t now = o->now_ms();
        if (now - begin >= SH_CEG_WAIT_MS) {
            o->event("ceg-finished-jobs", (int32_t)progress.finished);
            o->event("ceg-result", -1);
            return 49;
        }
        if (!waiting && now >= retry_at) {
            uint32_t jobs = UINT32_MAX;
            int32_t status = ((ceg_request_fn)(*(void ***)client_user)[71])(
                client_user, appid, false, false, &jobs);
            enum sh_ceg_step step = sh_ceg_request_step(status, jobs, &progress);
            if (step == SH_CEG_RETRY) {
                if (busy++ == 0) o->event("ceg-request-busy", status);
                retry_at = now + SH_CEG_BUSY_RETRY_MS;
            } else {
                o->event("ceg-request-result", status);
                o->event("ceg-request", jobs == UINT32_MAX ? -1 : (int32_t)jobs);
                if (step != SH_CEG_WAIT) {
                    o->event("ceg-result", progress.failure);
                    return 49;
                }
                waiting = true;
            }
        }
        for (unsigned batch = 0; batch < 64; ++batch) {
            struct sh_callback cb = {0};
            if (!api->get_callback(pipe, &cb)) break;
            bool valid = cb.id > 0 && cb.size >= 0 && (!cb.size || cb.data);
            enum sh_ceg_step step = SH_CEG_WAIT;
            int32_t value = 0;
            if (valid && cb.id == SH_CEG_JOB_FINISHED &&
                sh_decode_ceg_job(cb.data, (size_t)cb.size, appid, &value)) {
                /* A finish before any accepted request cannot be counted. */
                if (waiting) step = sh_ceg_record_job(&progress, value);
                if (waiting && (value != 1 || logged_jobs++ < 8)) o->event("ceg-job-result", value);
            } else if (valid && cb.id == SH_CEG_SERVER_REPLY &&
                       sh_decode_ceg_reply(cb.data, (size_t)cb.size, appid, &value) &&
                       value != logged_reply) {
                o->event("ceg-server-result", value);
                logged_reply = value;
            }
            api->free_callback(pipe);
            if (!valid) return SH_CALLBACK_INVALID;
            if (step == SH_CEG_DONE) {
                o->event("ceg-result", 1);
                return 0;
            }
            if (step == SH_CEG_FAIL) {
                o->event("ceg-finished-jobs", (int32_t)progress.finished);
                o->event("ceg-result", progress.failure);
                return 49;
            }
        }
        o->sleep_ms(50);
    }
    o->event("ceg-result", -3);
    return 49;
}

int sh_launch(HMODULE module, void *engine, void *client_user,
              const struct sh_api *api, const struct sh_observer *o,
              int32_t pipe, int32_t user, uint64_t steamid, uint32_t appid,
              const struct dock_client_layout *layout)
{
    if (!layout || !method_is(module, engine, 43, layout->engine_manager) ||
        !method_is(module, engine, 33, layout->engine_result) ||
        !method_is(module, client_user, 67, layout->running)) return 40;
    void *manager = ((get_manager_fn)(*(void ***)engine)[43])(engine, user, pipe);
    if (!method_is(module, manager, 2, layout->launch) ||
        !method_is(module, manager, 5, layout->install_dir)) return 40;
    char option_text[16] = {0};
    uint32_t launch_option = 0;
    SetLastError(ERROR_SUCCESS);
    DWORD option_length = GetEnvironmentVariableA("MADEIRA_STEAM_HOST_LAUNCH_OPTION", option_text, sizeof(option_text));
    if ((!option_length && GetLastError() != ERROR_ENVVAR_NOT_FOUND) || option_length >= sizeof(option_text) ||
        (option_length && !sh_parse_launch_option(option_text, &launch_option))) {
        o->event("launch-option-invalid", 1);
        return 45;
    }
    o->event("launch-option-index", (int32_t)launch_option);
    static char actual_utf8[32768];
    static wchar_t actual[32768], expected[32768], normalized[32768];
    DWORD length = GetEnvironmentVariableW(L"MADEIRA_STEAM_HOST_EXPECTED_INSTALL", expected, 32768);
    if (!length || length >= 32768) return 41;
    int32_t got = ((install_dir_fn)(*(void ***)manager)[5])(manager, appid, actual_utf8, sizeof(actual_utf8));
    if (got <= 0 || got >= (int32_t)sizeof(actual_utf8) ||
        !memchr(actual_utf8, 0, sizeof(actual_utf8)) ||
        !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, actual_utf8, -1, actual, 32768)) return 41;
    length = GetFullPathNameW(actual, 32768, normalized, NULL);
    if (!length || length >= 32768 || _wcsicmp(normalized, expected)) {
        o->event("launch-install-directory-mismatch", 1);
        return 41;
    }
    o->event("launch-install-directory-verified", 1);
    HKEY active = NULL, machine = NULL;
    int result = 42;
    struct saved_value values[3] = {0};
    /* ml1990: the public app sets MADEIRA_STEAM_HOST_CEG=1 only for an app
     * whose depot manifests flag CustomExecutable files, and records them in
     * the manifest's CheckGuid block. Failure never launches the game.
     * MADEIRA_DOCK_CEG=0 restores the previous direct LaunchApp.
     */
    if (wide_flag(L"MADEIRA_STEAM_HOST_CEG", L'1')) {
        if (wide_flag(L"MADEIRA_DOCK_CEG", L'0')) o->event("ceg-disabled", 1);
        else {
            /* ml2000: Valve's client reaches its own client service through
             * the service manager; start Wine's if this session lacks one.
             * It stays up for the game run and is ended at host exit.
             * MADEIRA_DOCK_CEG_SCM=0 restores the ml1990 behaviour.
             */
            int32_t scm = wide_flag(L"MADEIRA_DOCK_CEG_SCM", L'0') ? 0 : sh_ceg_scm_prepare(o, module);
            if (scm) {
                o->event("ceg-result", scm);
                result = 49;
                goto done;
            }
            result = prepare_custom_binaries(module, client_user, api, o, pipe, appid, layout);
            if (result) goto done;
            result = 42;
        }
    }
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", 0,
                     KEY_QUERY_VALUE | KEY_SET_VALUE, &active) != ERROR_SUCCESS ||
        RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"Software\\Valve\\Steam", 0,
                     KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_WOW64_32KEY, &machine) != ERROR_SUCCESS) goto done;
    values[0] = (struct saved_value){.key=active, .name=L"pid"};
    values[1] = (struct saved_value){.key=active, .name=L"ActiveUser"};
    values[2] = (struct saved_value){.key=machine, .name=L"SteamPID"};
    if (!publish(&values[0], GetCurrentProcessId()) ||
        !publish(&values[1], (DWORD)steamid) || !publish(&values[2], GetCurrentProcessId())) goto done;
    o->event("launch-client-discovery-published", 1);
    SetConsoleCtrlHandler(on_control, TRUE);
    uint64_t gameid = appid;
    /* The game's launch options (Game details › Launch options in Madeira), passed
     * to Valve's client as the user's arguments, the field desktop Steam's "Launch
     * Options" box fills. Empty or unset: none, as before. */
    static char user_args[4096];
    static wchar_t user_args_w[4096];
    user_args[0] = 0;
    DWORD args_len = GetEnvironmentVariableW(L"MADEIRA_DOCK_ARGS", user_args_w, 4096);
    if (args_len && args_len < 4096 &&
        !WideCharToMultiByte(CP_UTF8, 0, user_args_w, -1, user_args, sizeof(user_args), NULL, NULL))
        user_args[0] = 0;
    o->event("launch-user-args", user_args[0] != 0);
    uint64_t call = ((launch_fn)(*(void ***)manager)[2])(manager, &gameid, launch_option, 0, user_args);
    o->event("launch-request-submitted", call != 0);
    if (!call) { result = 43; goto done; }
    uint64_t begin = o->now_ms(), stopped_at = 0;
    bool seen_running = false, result_received = false, result_rejected = false;
    /* ml1970: a content refusal keeps Valve's client alive while it installs
     * what the launch needs, then asks it again. It never turns a refusal
     * into a launch: only Valve's own later success starts the game.
     * MADEIRA_DOCK_CONTENT_WAIT=0 restores the immediate failure.
     */
    wchar_t wait_flag[4] = {0};
    bool content_wait = !(GetEnvironmentVariableW(L"MADEIRA_DOCK_CONTENT_WAIT", wait_flag, 4) == 1 &&
                          wait_flag[0] == L'0');
    /* ml2011: a configuration refusal right after sign-in waits for Valve's client to
     * receive the app's configuration. MADEIRA_DOCK_CONFIG_WAIT=0 fails immediately.
     */
    wchar_t config_flag[4] = {0};
    bool config_wait = !(GetEnvironmentVariableW(L"MADEIRA_DOCK_CONFIG_WAIT", config_flag, 4) == 1 &&
                         config_flag[0] == L'0');
    uint64_t config_began = 0;
    /* ml2015: "another session is playing" also comes back for a session that
     * ended without telling Steam (the app was closed under a running game):
     * Steam's servers keep it until that connection times out. The host asks
     * again for a bounded time; a session that is really playing elsewhere
     * still fails once the bound passes. MADEIRA_DOCK_SESSION_WAIT=0 fails
     * immediately.
     */
    wchar_t session_flag[4] = {0};
    bool session_wait = !(GetEnvironmentVariableW(L"MADEIRA_DOCK_SESSION_WAIT", session_flag, 4) == 1 &&
                          session_flag[0] == L'0');
    uint64_t session_began = 0;
    uint64_t wait_began = 0, retry_at = 0;
    unsigned retries = 0;
    int32_t logged_error = INT32_MIN;
    result = 44;
    while (!InterlockedCompareExchange(&interrupted, 0, 0)) {
        for (unsigned batch = 0; batch < 64; ++batch) {
            struct sh_callback cb = {0};
            if (!api->get_callback(pipe, &cb)) break;
            bool valid = cb.id > 0 && cb.size >= 0 && (!cb.size || cb.data);
            if (valid && cb.id == 703 && cb.size >= 16) {
                uint64_t finished; int32_t kind; uint32_t size;
                memcpy(&finished, cb.data, 8);
                memcpy(&kind, (char *)cb.data+8, 4);
                memcpy(&size, (char *)cb.data+12, 4);
                if (finished == call) {
                    /* Do not print the error-detail string: it can contain
                     * private paths. Only decode the fixed numeric result.
                     */
                    /* This client reports 524 bytes: 8-byte GameID, 4-byte
                     * EAppError and 512 detail bytes, without tail padding.
                     */
                    unsigned char payload[524] = {0};
                    bool failed = false;
                    bool read = kind == 1270027 && size == sizeof(payload) &&
                        ((call_result_fn)(*(void ***)engine)[33])(
                            engine, pipe, call, payload, sizeof(payload), kind, &failed);
                    int32_t error = -1;
                    bool decoded = read && !failed && sh_decode_launch_result(payload, size, gameid, &error);
                    bool missing_option = decoded && error == 22 && sh_launch_option_missing(payload, size, launch_option);
                    if (missing_option) o->event("launch-option-missing", (int32_t)launch_option);
                    /* Repeated requests while waiting report only changes,
                     * keeping the bounded report file small.
                     */
                    if (error != logged_error || !decoded) {
                        o->event("launch-result-kind", kind);
                        o->event("launch-result-size", (int32_t)size);
                        o->event("launch-client-error", error);
                        logged_error = error;
                    }
                    result_received = decoded && error == 0;
                    result_rejected = !result_received;
                    retry_at = 0;
                    if (result_received && wait_began) o->event("launch-update-ready", (int32_t)retries);
                    if (!result_received && decoded && content_wait && !seen_running &&
                        sh_launch_error_waits_for_content(error) &&
                        !sh_launch_content_wait_expired(o->now_ms(), wait_began)) {
                        if (!wait_began) {
                            wait_began = o->now_ms();
                            o->event("launch-update-wait", error);
                        }
                        retry_at = o->now_ms() + sh_launch_retry_delay_ms(retries);
                        result_rejected = false;
                    }
                    else if (!result_received && decoded && config_wait && !seen_running && !missing_option &&
                             sh_launch_error_waits_for_config(error) &&
                             (!config_began || o->now_ms() - config_began < SH_CONFIG_WAIT_MS)) {
                        if (!config_began) {
                            config_began = o->now_ms();
                            o->event("launch-config-wait", error);
                        }
                        retry_at = o->now_ms() + SH_CONFIG_RETRY_MS;
                        result_rejected = false;
                    }
                    else if (!result_received && decoded && session_wait && !seen_running &&
                             sh_launch_error_waits_for_session(error) &&
                             (!session_began || o->now_ms() - session_began < SH_SESSION_WAIT_MS)) {
                        if (!session_began) {
                            session_began = o->now_ms();
                            o->event("launch-session-wait", error);
                        }
                        retry_at = o->now_ms() + SH_SESSION_RETRY_MS;
                        result_rejected = false;
                    }
                    /* A game can start before this callback is decoded. Keep
                     * serving it until exit even if a result is rejected.
                     */
                }
            }
            api->free_callback(pipe);
            if (!valid) { result = SH_CALLBACK_INVALID; goto done; }
        }
        bool running = ((running_fn)(*(void ***)client_user)[67])(client_user, &gameid);
        if (running && !seen_running) {
            o->event("launch-game-running", 1);
            seen_running = true;
            retry_at = 0;
        }
        if (running) stopped_at = 0;
        else if (seen_running) {
            if (!stopped_at) stopped_at = o->now_ms();
            if (o->now_ms() - stopped_at >= 3000) {
                o->event("launch-game-ended", 1);
                result = result_received && !result_rejected ? 0 : 46;
                break;
            }
        }
        /* A queued update is not evidence of download progress. Enforce the
         * bound even when the latest launch request never returns a callback. */
        if (!seen_running && !result_received && sh_launch_error_waits_for_content(logged_error) &&
            sh_launch_content_wait_expired(o->now_ms(), wait_began)) {
            o->event("launch-update-gave-up", (int32_t)retries);
            result = 48;
            break;
        }
        if (retry_at && !seen_running && o->now_ms() >= retry_at) {
            retry_at = 0;
            call = ((launch_fn)(*(void ***)manager)[2])(manager, &gameid, launch_option, 0, user_args);
            ++retries;
            if (retries <= 3 || retries % 60 == 0) o->event("launch-update-retry", (int32_t)retries);
            if (!call) { result = 43; goto done; }
            begin = o->now_ms();
        }
        if (retry_at) { o->sleep_ms(50); continue; }
        if (!seen_running && result_rejected && o->now_ms() - begin > 5000) {
            if (config_began) o->event("launch-config-gave-up", (int32_t)retries);
            if (session_began) o->event("launch-session-gave-up", (int32_t)retries);
            result = wait_began && sh_launch_error_waits_for_content(logged_error) ? 48 : 45;
            break;
        }
        if (!seen_running && o->now_ms() - begin > 90000) break;
        o->sleep_ms(50);
    }
done:
    SetConsoleCtrlHandler(on_control, FALSE);
    bool restored = true;
    /* Another Steam process may have claimed registration while this host was
     * alive. Never restore account metadata over a different current PID.
     */
    if (values[0].changed) {
        DWORD current = 0, bytes = sizeof(current), type = 0;
        if (RegQueryValueExW(active, L"pid", NULL, &type, (BYTE *)&current, &bytes) != ERROR_SUCCESS ||
            type != REG_DWORD || current != GetCurrentProcessId()) restored = false;
    }
    if (restored)
        for (int i = 2; i >= 0; --i) if (!restore(&values[i])) restored = false;
    o->event("launch-discovery-restored", restored);
    if (machine) RegCloseKey(machine);
    if (active) RegCloseKey(active);
    if (!restored) result = 47;
    o->event("launch-host-result", result);
    return result;
}
#else
int sh_launch(HMODULE module, void *engine, void *client_user,
              const struct sh_api *api, const struct sh_observer *o,
              int32_t pipe, int32_t user, uint64_t steamid, uint32_t appid,
              const struct dock_client_layout *layout)
{
    (void)module; (void)engine; (void)client_user; (void)api; (void)o;
    (void)pipe; (void)user; (void)steamid; (void)appid; (void)layout;
    return 40;
}
#endif
