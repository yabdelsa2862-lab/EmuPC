/* Host-path regression test. LGPL-2.1-or-later, like the source under test.
 * Standalone native Windows test: includes the production XInput implementation
 * and supplies a synthetic NtUserCallTwoParam import. Never starts Wine or uses
 * a physical controller. See xinput-host.md for build instructions. */
#include "../../dlls/xinput1_3/main.c"
#include <stdio.h>

static XINPUT_STATE sample;
static BOOL connected[XUSER_MAX_COUNT] = { TRUE, FALSE, FALSE, FALSE };
static XINPUT_VIBRATION motors[XUSER_MAX_COUNT];
static BOOL battery_published, foreground_owner;
static XINPUT_BATTERY_INFORMATION host_battery;

static ULONG_PTR WINAPI query(ULONG_PTR arg1, ULONG_PTR arg2, ULONG code)
{
    UINT index = arg1 & 0xff, op = (arg1 >> 8) & 0xff;
    assert(code == NtUserCallTwoParam_GetGamepadState);
    assert(index < XUSER_MAX_COUNT && arg2);
    if (op == NtUserGamepadOp_Foreground)
    {
        /* ml2115: index ignored; 0 leaves the buffer alone, like an older win32u. */
        if (!foreground_owner) return 0;
        *(DWORD *)arg2 = NtUserGamepadForeground_Rule | NtUserGamepadForeground_Owner;
        return 1;
    }
    if (!connected[index]) return 0;
    if (op == NtUserGamepadOp_State) *(XINPUT_STATE *)arg2 = sample;
    else if (op == NtUserGamepadOp_Caps)
    {
        XINPUT_CAPABILITIES *caps = (void *)arg2;
        memset(caps, 0, sizeof(*caps));
        caps->Type = XINPUT_DEVTYPE_GAMEPAD;
        caps->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    }
    else if (op == NtUserGamepadOp_SetVibration) motors[index] = *(XINPUT_VIBRATION *)arg2;
    else if (op == NtUserGamepadOp_Battery)
    {
        if (!battery_published) return 0;
        *(XINPUT_BATTERY_INFORMATION *)arg2 = host_battery;
    }
    else assert(0);
    return 1;
}

/* Redirect only the test binary's import. No installed DLL is modified. */
ULONG_PTR (WINAPI *__imp_NtUserCallTwoParam)(ULONG_PTR, ULONG_PTR, ULONG) = query;
const char * __cdecl __wine_dbg_strdup(const char *str) { return str; }
int __cdecl __wine_dbg_output(const char *str) { return 0; }
int __cdecl __wine_dbg_header(enum __wine_debug_class cls,
        struct __wine_debug_channel *channel, const char *function) { return -1; }

int main(void)
{
    XINPUT_STATE state;
    XINPUT_CAPABILITIES caps;
    XINPUT_KEYSTROKE key;
    XINPUT_VIBRATION vibration = {0};
    XINPUT_BATTERY_INFORMATION battery;
    GUID render, capture;

    sample.dwPacketNumber = 42;
    sample.Gamepad.wButtons = XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_GUIDE;
    sample.Gamepad.sThumbLX = -32768;
    sample.Gamepad.sThumbLY = 32767;
    sample.Gamepad.bLeftTrigger = 255;
    assert(XInputGetState(0, &state) == ERROR_SUCCESS);
    assert(state.dwPacketNumber == 42 && state.Gamepad.wButtons == XINPUT_GAMEPAD_A);
    assert(state.Gamepad.sThumbLX == -32768 && state.Gamepad.sThumbLY == 32767);
    assert(XInputGetStateEx(0, &state) == ERROR_SUCCESS);
    assert(state.Gamepad.wButtons & XINPUT_GAMEPAD_GUIDE);
    assert(XInputGetState(4, &state) == ERROR_BAD_ARGUMENTS);
    assert(XInputGetState(0, NULL) == ERROR_BAD_ARGUMENTS);
    assert(XInputGetCapabilities(0, 0, &caps) == ERROR_SUCCESS && caps.Flags == 0);
    assert(XInputGetCapabilities(0, 0, NULL) == ERROR_BAD_ARGUMENTS);
    vibration.wLeftMotorSpeed = 0x8000;
    vibration.wRightMotorSpeed = 0x1234;
    assert(XInputSetState(0, &vibration) == ERROR_SUCCESS);
    assert(motors[0].wLeftMotorSpeed == 0x8000 && motors[0].wRightMotorSpeed == 0x1234);
    assert(XInputSetState(0, NULL) == ERROR_BAD_ARGUMENTS);
    assert(XInputGetKeystroke(0, 0, &key) == ERROR_SUCCESS);
    assert(key.VirtualKey == VK_PAD_A && key.Flags == XINPUT_KEYSTROKE_KEYDOWN);
    sample.Gamepad.wButtons = 0;
    assert(XInputGetKeystroke(0, 0, &key) == ERROR_SUCCESS);
    assert(key.VirtualKey == VK_PAD_A && key.Flags == XINPUT_KEYSTROKE_KEYUP);
    assert(XInputGetKeystroke(0, 0, NULL) == ERROR_BAD_ARGUMENTS);
    XInputEnable(FALSE);
    assert(!motors[0].wLeftMotorSpeed && !motors[0].wRightMotorSpeed);
    assert(XInputGetState(0, &state) == ERROR_SUCCESS);
    XINPUT_GAMEPAD zero = {0};
    assert(!memcmp(&state.Gamepad, &zero, sizeof(zero)));
    /* ml2115: a disable while the caller owns the foreground window is stale. */
    foreground_owner = TRUE;
    assert(XInputGetState(0, &state) == ERROR_SUCCESS && state.Gamepad.bLeftTrigger == 255);
    foreground_owner = FALSE;
    assert(XInputGetState(0, &state) == ERROR_SUCCESS && !state.Gamepad.bLeftTrigger);
    vibration.wLeftMotorSpeed = 0x4000;
    assert(XInputSetState(0, &vibration) == ERROR_SUCCESS);
    assert(!motors[0].wLeftMotorSpeed && !motors[0].wRightMotorSpeed);
    XInputEnable(TRUE);
    assert(motors[0].wLeftMotorSpeed == 0x4000 && motors[0].wRightMotorSpeed == 0x1234);
    assert(XInputGetState(0, &state) == ERROR_SUCCESS && state.Gamepad.bLeftTrigger == 255);
    DllMain(NULL, DLL_PROCESS_DETACH, NULL);
    assert(!motors[0].wLeftMotorSpeed && !motors[0].wRightMotorSpeed);
    assert(XInputGetBatteryInformation(0, BATTERY_DEVTYPE_GAMEPAD, &battery) == ERROR_SUCCESS);
    assert(battery.BatteryType == BATTERY_TYPE_UNKNOWN);
    battery_published = TRUE;
    host_battery.BatteryType = BATTERY_TYPE_NIMH;
    host_battery.BatteryLevel = BATTERY_LEVEL_LOW;
    assert(XInputGetBatteryInformation(0, BATTERY_DEVTYPE_GAMEPAD, &battery) == ERROR_SUCCESS);
    assert(battery.BatteryType == BATTERY_TYPE_NIMH && battery.BatteryLevel == BATTERY_LEVEL_LOW);
    assert(XInputGetBatteryInformation(0, BATTERY_DEVTYPE_HEADSET, &battery) == ERROR_SUCCESS);
    assert(battery.BatteryType == BATTERY_TYPE_DISCONNECTED);
    assert(XInputGetBatteryInformation(0, BATTERY_DEVTYPE_GAMEPAD, NULL) == ERROR_BAD_ARGUMENTS);
    assert(XInputGetBatteryInformation(1, BATTERY_DEVTYPE_GAMEPAD, &battery) == ERROR_DEVICE_NOT_CONNECTED);
    assert(XInputGetDSoundAudioDeviceGuids(0, &render, &capture) == ERROR_NOT_SUPPORTED);
    assert(XInputGetDSoundAudioDeviceGuids(1, &render, &capture) == ERROR_DEVICE_NOT_CONNECTED);
    connected[0] = FALSE;
    assert(!host_pad_state(0, &state));
    assert(!memcmp(&state.Gamepad, &zero, sizeof(zero)));
    puts("PASS: host XInput state/caps/edges/disable, vibration, invalid arguments, stale disable (ml2115), unknown and published battery, and per-index audio");
    return 0;
}
