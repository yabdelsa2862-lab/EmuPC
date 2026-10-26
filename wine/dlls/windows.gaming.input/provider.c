/* WinRT Windows.Gaming.Input implementation
 *
 * Copyright 2022 Rémi Bernon for CodeWeavers
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#include "private.h"

#include "initguid.h"
#include "ddk/hidsdi.h"
#include "dinput.h"
#include "provider.h"
#include "hidusage.h"
#include "xinput.h"

/* Madeira/iOS: NtUserGetGamepadState, the host gamepad snapshot that xinput reads. */
#include "ntuser.h"

#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(input);

DEFINE_GUID( device_path_guid, 0x00000000, 0x0000, 0x0000, 0x8d, 0x4a, 0x23, 0x90, 0x3f, 0xb6, 0xbd, 0xf8 );

static CRITICAL_SECTION provider_cs;
static CRITICAL_SECTION_DEBUG provider_cs_debug =
{
    0, 0, &provider_cs,
    { &provider_cs_debug.ProcessLocksList, &provider_cs_debug.ProcessLocksList },
      0, 0, { (DWORD_PTR)(__FILE__ ": provider_cs") }
};
static CRITICAL_SECTION provider_cs = { &provider_cs_debug, -1, 0, 0, 0, 0 };

static struct list provider_list = LIST_INIT( provider_list );

struct provider
{
    IWineGameControllerProvider IWineGameControllerProvider_iface;
    IGameControllerProvider IGameControllerProvider_iface;
    LONG ref;

    IDirectInputDevice8W *dinput_device;
    WCHAR device_path[MAX_PATH];
    struct list entry;

    struct WineGameControllerVibration vibration;

    char *report_buf;
    PHIDP_PREPARSED_DATA preparsed;
    HIDP_VALUE_CAPS haptics_rumble_caps;
    HIDP_VALUE_CAPS haptics_buzz_caps;
    HIDP_VALUE_CAPS haptics_left_caps;
    HIDP_VALUE_CAPS haptics_right_caps;
    BYTE haptics_report;
    HIDP_CAPS caps;
    HANDLE device;

    /* Madeira/iOS: >= 0 for a host pad slot (no dinput device, no HID handle);
     * its state comes from the same in-process snapshot xinput reads. */
    int host_index;
};

/* Madeira/iOS: the host gamepad snapshot. TRUE when a pad is published in that slot. */
static BOOL host_pad_read( UINT index, XINPUT_STATE *state )
{
    memset( state, 0, sizeof(*state) );
    if (index >= XUSER_MAX_COUNT) return FALSE;
    return NtUserGetGamepadState( index, NtUserGamepadOp_State, state );
}

static void host_pad_path( UINT index, WCHAR *path )
{
    swprintf( path, MAX_PATH, L"\\\\?\\MADEIRA#HOSTPAD&XI_%02u#%u", index, index );
}

static inline struct provider *impl_from_IWineGameControllerProvider( IWineGameControllerProvider *iface )
{
    return CONTAINING_RECORD( iface, struct provider, IWineGameControllerProvider_iface );
}

static HRESULT WINAPI wine_provider_QueryInterface( IWineGameControllerProvider *iface, REFIID iid, void **out )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );

    TRACE( "iface %p, iid %s, out %p.\n", iface, debugstr_guid( iid ), out );

    if (IsEqualGUID( iid, &IID_IUnknown ) ||
        IsEqualGUID( iid, &IID_IInspectable ) ||
        IsEqualGUID( iid, &IID_IAgileObject ) ||
        IsEqualGUID( iid, &IID_IWineGameControllerProvider ))
    {
        IInspectable_AddRef( (*out = &impl->IWineGameControllerProvider_iface) );
        return S_OK;
    }

    if (IsEqualGUID( iid, &IID_IGameControllerProvider ))
    {
        IInspectable_AddRef( (*out = &impl->IGameControllerProvider_iface) );
        return S_OK;
    }

    FIXME( "%s not implemented, returning E_NOINTERFACE.\n", debugstr_guid( iid ) );
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG WINAPI wine_provider_AddRef( IWineGameControllerProvider *iface )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    ULONG ref = InterlockedIncrement( &impl->ref );
    TRACE( "iface %p increasing refcount to %lu.\n", iface, ref );
    return ref;
}

static ULONG WINAPI wine_provider_Release( IWineGameControllerProvider *iface )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    ULONG ref = InterlockedDecrement( &impl->ref );

    TRACE( "iface %p decreasing refcount to %lu.\n", iface, ref );

    if (!ref)
    {
        if (impl->dinput_device) IDirectInputDevice8_Release( impl->dinput_device );
        if (impl->preparsed) HidD_FreePreparsedData( impl->preparsed );
        CloseHandle( impl->device );
        free( impl->report_buf );
        free( impl );
    }

    return ref;
}

static HRESULT WINAPI wine_provider_GetIids( IWineGameControllerProvider *iface, ULONG *iid_count, IID **iids )
{
    FIXME( "iface %p, iid_count %p, iids %p stub!\n", iface, iid_count, iids );
    return E_NOTIMPL;
}

static HRESULT WINAPI wine_provider_GetRuntimeClassName( IWineGameControllerProvider *iface, HSTRING *class_name )
{
    FIXME( "iface %p, class_name %p stub!\n", iface, class_name );
    return E_NOTIMPL;
}

static HRESULT WINAPI wine_provider_GetTrustLevel( IWineGameControllerProvider *iface, TrustLevel *trust_level )
{
    FIXME( "iface %p, trust_level %p stub!\n", iface, trust_level );
    return E_NOTIMPL;
}

static HRESULT WINAPI wine_provider_get_NonRoamableId( IWineGameControllerProvider *iface, HSTRING *value )
{
    FIXME( "iface %p, value %p stub!\n", iface, value );
    return E_NOTIMPL;
}

static HRESULT WINAPI wine_provider_get_DisplayName( IWineGameControllerProvider *iface, HSTRING *value )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    DIDEVICEINSTANCEW instance = {.dwSize = sizeof(DIDEVICEINSTANCEW)};
    HRESULT hr;

    TRACE( "iface %p, value %p\n", iface, value );

    if (impl->host_index >= 0)
    {
        static const WCHAR name[] = L"Controller (Xbox 360 For Windows)";
        return WindowsCreateString( name, wcslen( name ), value );
    }
    if (FAILED(hr = IDirectInputDevice8_GetDeviceInfo( impl->dinput_device, &instance ))) return hr;
    return WindowsCreateString( instance.tszProductName, wcslen( instance.tszProductName ), value );
}

static BOOL CALLBACK count_ffb_axes( const DIDEVICEOBJECTINSTANCEW *obj, void *args )
{
    DWORD *count = args;
    if (obj->dwType & DIDFT_FFACTUATOR) (*count)++;
    return DIENUM_CONTINUE;
}

static HRESULT WINAPI wine_provider_get_Type( IWineGameControllerProvider *iface, WineGameControllerType *value )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    DIDEVICEINSTANCEW instance = {.dwSize = sizeof(DIDEVICEINSTANCEW)};
    const WCHAR *tmp;
    HRESULT hr;

    TRACE( "iface %p, value %p.\n", iface, value );

    if (impl->host_index >= 0)
    {
        *value = WineGameControllerType_Gamepad;
        return S_OK;
    }
    if (FAILED(hr = IDirectInputDevice8_GetDeviceInfo( impl->dinput_device, &instance ))) return hr;

    if ((tmp = wcschr( impl->device_path + 8, '#' )) && !wcsnicmp( tmp - 6, L"&XI_", 4 ))
        *value = WineGameControllerType_Gamepad;
    else switch (GET_DIDEVICE_TYPE( instance.dwDevType ))
    {
    case DI8DEVTYPE_DRIVING: *value = WineGameControllerType_RacingWheel; break;
    default:
    {
        DWORD count = 0;
        hr = IDirectInputDevice8_EnumObjects( impl->dinput_device, count_ffb_axes, &count, DIDFT_AXIS );
        if (SUCCEEDED(hr) && count == 1) *value = WineGameControllerType_RacingWheel;
        else *value = WineGameControllerType_Joystick;
        break;
    }
    }

    return S_OK;
}

static HRESULT WINAPI wine_provider_get_AxisCount( IWineGameControllerProvider *iface, INT32 *value )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    DIDEVCAPS caps = {.dwSize = sizeof(DIDEVCAPS)};
    HRESULT hr;

    TRACE( "iface %p, value %p.\n", iface, value );

    if (impl->host_index >= 0)
    {
        *value = 6;
        return S_OK;
    }

    if (SUCCEEDED(hr = IDirectInputDevice8_GetCapabilities( impl->dinput_device, &caps )))
        *value = caps.dwAxes;
    return hr;
}

static HRESULT WINAPI wine_provider_get_ButtonCount( IWineGameControllerProvider *iface, INT32 *value )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    DIDEVCAPS caps = {.dwSize = sizeof(DIDEVCAPS)};
    HRESULT hr;

    TRACE( "iface %p, value %p.\n", iface, value );

    if (impl->host_index >= 0)
    {
        *value = 10;
        return S_OK;
    }

    if (SUCCEEDED(hr = IDirectInputDevice8_GetCapabilities( impl->dinput_device, &caps )))
        *value = caps.dwButtons;
    return hr;
}

static HRESULT WINAPI wine_provider_get_SwitchCount( IWineGameControllerProvider *iface, INT32 *value )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    DIDEVCAPS caps = {.dwSize = sizeof(DIDEVCAPS)};
    HRESULT hr;

    TRACE( "iface %p, value %p.\n", iface, value );

    if (impl->host_index >= 0)
    {
        *value = 1;
        return S_OK;
    }

    if (SUCCEEDED(hr = IDirectInputDevice8_GetCapabilities( impl->dinput_device, &caps )))
        *value = caps.dwPOVs;
    return hr;
}

static HRESULT WINAPI wine_provider_get_State( IWineGameControllerProvider *iface, struct WineGameControllerState *out )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    DIJOYSTATE2 state = {0};
    UINT32 i = 0;
    HRESULT hr;

    TRACE( "iface %p, out %p.\n", iface, out );

    if (impl->host_index >= 0)
    {
        XINPUT_STATE xs;
        WORD b;

        /* Disconnected: a neutral reading. The provider itself is removed by the scan. */
        host_pad_read( impl->host_index, &xs );
        b = xs.Gamepad.wButtons;
        memset( out, 0, sizeof(*out) );

        /* The xusb button order gamepad.c reads: A B X Y LB RB View Menu LS RS. */
        out->buttons[0] = !!(b & XINPUT_GAMEPAD_A);
        out->buttons[1] = !!(b & XINPUT_GAMEPAD_B);
        out->buttons[2] = !!(b & XINPUT_GAMEPAD_X);
        out->buttons[3] = !!(b & XINPUT_GAMEPAD_Y);
        out->buttons[4] = !!(b & XINPUT_GAMEPAD_LEFT_SHOULDER);
        out->buttons[5] = !!(b & XINPUT_GAMEPAD_RIGHT_SHOULDER);
        out->buttons[6] = !!(b & XINPUT_GAMEPAD_BACK);
        out->buttons[7] = !!(b & XINPUT_GAMEPAD_START);
        out->buttons[8] = !!(b & XINPUT_GAMEPAD_LEFT_THUMB);
        out->buttons[9] = !!(b & XINPUT_GAMEPAD_RIGHT_THUMB);

        switch (b & (XINPUT_GAMEPAD_DPAD_UP | XINPUT_GAMEPAD_DPAD_DOWN | XINPUT_GAMEPAD_DPAD_LEFT | XINPUT_GAMEPAD_DPAD_RIGHT))
        {
        case XINPUT_GAMEPAD_DPAD_UP: out->switches[0] = GameControllerSwitchPosition_Up; break;
        case XINPUT_GAMEPAD_DPAD_UP | XINPUT_GAMEPAD_DPAD_RIGHT: out->switches[0] = GameControllerSwitchPosition_UpRight; break;
        case XINPUT_GAMEPAD_DPAD_RIGHT: out->switches[0] = GameControllerSwitchPosition_Right; break;
        case XINPUT_GAMEPAD_DPAD_DOWN | XINPUT_GAMEPAD_DPAD_RIGHT: out->switches[0] = GameControllerSwitchPosition_DownRight; break;
        case XINPUT_GAMEPAD_DPAD_DOWN: out->switches[0] = GameControllerSwitchPosition_Down; break;
        case XINPUT_GAMEPAD_DPAD_DOWN | XINPUT_GAMEPAD_DPAD_LEFT: out->switches[0] = GameControllerSwitchPosition_DownLeft; break;
        case XINPUT_GAMEPAD_DPAD_LEFT: out->switches[0] = GameControllerSwitchPosition_Left; break;
        case XINPUT_GAMEPAD_DPAD_UP | XINPUT_GAMEPAD_DPAD_LEFT: out->switches[0] = GameControllerSwitchPosition_UpLeft; break;
        default: out->switches[0] = GameControllerSwitchPosition_Center; break;
        }

        /* gamepad.c: LeftX = 2*axes[1]-1, LeftY = 2*axes[0]-1, RightX = 2*axes[3]-1,
         * RightY = 2*axes[2]-1, LeftTrigger = axes[4], RightTrigger = axes[5].
         * XInput and Windows.Gaming.Input both have +Y up. */
        out->axes[0] = (xs.Gamepad.sThumbLY + 32768) / 65535.;
        out->axes[1] = (xs.Gamepad.sThumbLX + 32768) / 65535.;
        out->axes[2] = (xs.Gamepad.sThumbRY + 32768) / 65535.;
        out->axes[3] = (xs.Gamepad.sThumbRX + 32768) / 65535.;
        out->axes[4] = xs.Gamepad.bLeftTrigger / 255.;
        out->axes[5] = xs.Gamepad.bRightTrigger / 255.;
        out->timestamp = GetTickCount64();
        return S_OK;
    }

    if (FAILED(hr = IDirectInputDevice8_GetDeviceState( impl->dinput_device, sizeof(state), &state )))
    {
        WARN( "Failed to read device state, hr %#lx\n", hr );
        return S_OK;
    }

    i = ARRAY_SIZE(state.rgbButtons);
    while (i--) out->buttons[i] = (state.rgbButtons[i] != 0);

    i = ARRAY_SIZE(state.rgdwPOV);
    while (i--)
    {
        if (state.rgdwPOV[i] == ~0) out->switches[i] = GameControllerSwitchPosition_Center;
        else out->switches[i] = state.rgdwPOV[i] * 8 / 36000 + 1;
    }

    i = 0;
    out->axes[i++] = state.lX / 65535.;
    out->axes[i++] = state.lY / 65535.;
    out->axes[i++] = state.lZ / 65535.;
    out->axes[i++] = state.lRx / 65535.;
    out->axes[i++] = state.lRy / 65535.;
    out->axes[i++] = state.lRz / 65535.;
    out->axes[i++] = state.rglSlider[0] / 65535.;
    out->axes[i++] = state.rglSlider[1] / 65535.;
    out->axes[i++] = state.lVX / 65535.;
    out->axes[i++] = state.lVY / 65535.;
    out->axes[i++] = state.lVZ / 65535.;
    out->axes[i++] = state.lVRx / 65535.;
    out->axes[i++] = state.lVRy / 65535.;
    out->axes[i++] = state.lVRz / 65535.;
    out->axes[i++] = state.rglVSlider[0] / 65535.;
    out->axes[i++] = state.rglVSlider[1] / 65535.;
    out->axes[i++] = state.lAX / 65535.;
    out->axes[i++] = state.lAY / 65535.;
    out->axes[i++] = state.lAZ / 65535.;
    out->axes[i++] = state.lARx / 65535.;
    out->axes[i++] = state.lARy / 65535.;
    out->axes[i++] = state.lARz / 65535.;
    out->axes[i++] = state.rglASlider[0] / 65535.;
    out->axes[i++] = state.rglASlider[1] / 65535.;
    out->axes[i++] = state.lFX / 65535.;
    out->axes[i++] = state.lFY / 65535.;
    out->axes[i++] = state.lFZ / 65535.;
    out->axes[i++] = state.lFRx / 65535.;
    out->axes[i++] = state.lFRy / 65535.;
    out->axes[i++] = state.lFRz / 65535.;
    out->axes[i++] = state.rglFSlider[0] / 65535.;
    out->axes[i++] = state.rglFSlider[1] / 65535.;
    out->timestamp = GetTickCount64();

    return S_OK;
}

static HRESULT WINAPI wine_provider_get_Vibration( IWineGameControllerProvider *iface, struct WineGameControllerVibration *out )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    TRACE( "iface %p, out %p.\n", iface, out );
    *out = impl->vibration;
    return S_OK;
}

static HRESULT WINAPI wine_provider_put_Vibration( IWineGameControllerProvider *iface, struct WineGameControllerVibration value )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    ULONG report_len = impl->caps.OutputReportByteLength;
    PHIDP_PREPARSED_DATA preparsed = impl->preparsed;
    char *report_buf = impl->report_buf;
    USHORT collection;
    NTSTATUS status;
    BOOL ret;

    TRACE( "iface %p, value %p.\n", iface, &value );

    if (!memcmp( &impl->vibration, &value, sizeof(value) )) return S_OK;
    impl->vibration = value;
    if (impl->host_index >= 0 || !impl->device) return S_OK;

    status = HidP_InitializeReportForID( HidP_Output, impl->haptics_report, preparsed, report_buf, report_len );
    if (status != HIDP_STATUS_SUCCESS) WARN( "HidP_InitializeReportForID returned %#lx\n", status );

    collection = impl->haptics_rumble_caps.LinkCollection;
    status = HidP_SetUsageValue( HidP_Output, HID_USAGE_PAGE_HAPTICS, collection, HID_USAGE_HAPTICS_INTENSITY,
                                 impl->vibration.rumble, preparsed, report_buf, report_len );
    if (status != HIDP_STATUS_SUCCESS) WARN( "HidP_SetUsageValue INTENSITY returned %#lx\n", status );

    collection = impl->haptics_buzz_caps.LinkCollection;
    status = HidP_SetUsageValue( HidP_Output, HID_USAGE_PAGE_HAPTICS, collection, HID_USAGE_HAPTICS_INTENSITY,
                                 impl->vibration.buzz, preparsed, report_buf, report_len );
    if (status != HIDP_STATUS_SUCCESS) WARN( "HidP_SetUsageValue INTENSITY returned %#lx\n", status );

    collection = impl->haptics_left_caps.LinkCollection;
    status = HidP_SetUsageValue( HidP_Output, HID_USAGE_PAGE_HAPTICS, collection, HID_USAGE_HAPTICS_INTENSITY,
                                 impl->vibration.left, preparsed, report_buf, report_len );
    if (status != HIDP_STATUS_SUCCESS) WARN( "HidP_SetUsageValue INTENSITY returned %#lx\n", status );

    collection = impl->haptics_right_caps.LinkCollection;
    status = HidP_SetUsageValue( HidP_Output, HID_USAGE_PAGE_HAPTICS, collection, HID_USAGE_HAPTICS_INTENSITY,
                                 impl->vibration.right, preparsed, report_buf, report_len );
    if (status != HIDP_STATUS_SUCCESS) WARN( "HidP_SetUsageValue INTENSITY returned %#lx\n", status );

    ret = HidD_SetOutputReport( impl->device, report_buf, report_len );
    if (!ret) WARN( "HidD_SetOutputReport failed with error %lu\n", GetLastError() );

    return S_OK;
}

static HRESULT WINAPI wine_provider_get_ForceFeedbackMotor( IWineGameControllerProvider *iface, IForceFeedbackMotor **value )
{
    struct provider *impl = impl_from_IWineGameControllerProvider( iface );
    DIDEVCAPS caps = {.dwSize = sizeof(DIDEVCAPS)};
    HRESULT hr;

    TRACE( "iface %p, value %p.\n", iface, value );

    if (impl->host_index < 0 &&
        SUCCEEDED(hr = IDirectInputDevice8_GetCapabilities( impl->dinput_device, &caps )) && (caps.dwFlags & DIDC_FORCEFEEDBACK))
        return force_feedback_motor_create( impl->dinput_device, value );

    *value = NULL;
    return S_OK;
}

static const struct IWineGameControllerProviderVtbl wine_provider_vtbl =
{
    wine_provider_QueryInterface,
    wine_provider_AddRef,
    wine_provider_Release,
    /* IInspectable methods */
    wine_provider_GetIids,
    wine_provider_GetRuntimeClassName,
    wine_provider_GetTrustLevel,
    /* IWineGameControllerProvider methods */
    wine_provider_get_NonRoamableId,
    wine_provider_get_DisplayName,
    wine_provider_get_Type,
    wine_provider_get_AxisCount,
    wine_provider_get_ButtonCount,
    wine_provider_get_SwitchCount,
    wine_provider_get_State,
    wine_provider_get_Vibration,
    wine_provider_put_Vibration,
    wine_provider_get_ForceFeedbackMotor,
};

DEFINE_IINSPECTABLE( game_provider, IGameControllerProvider, struct provider, IWineGameControllerProvider_iface )

static HRESULT WINAPI game_provider_get_FirmwareVersionInfo( IGameControllerProvider *iface, GameControllerVersionInfo *value )
{
    FIXME( "iface %p, value %p stub!\n", iface, value );
    return E_NOTIMPL;
}

static HRESULT WINAPI game_provider_get_HardwareProductId( IGameControllerProvider *iface, UINT16 *value )
{
    DIPROPDWORD vid_pid = {.diph = {.dwHeaderSize = sizeof(DIPROPHEADER), .dwSize = sizeof(DIPROPDWORD)}};
    struct provider *impl = impl_from_IGameControllerProvider( iface );
    HRESULT hr;

    TRACE( "iface %p, value %p.\n", iface, value );

    if (impl->host_index >= 0)
    {
        *value = 0x028e; /* Xbox 360 controller */
        return S_OK;
    }
    if (SUCCEEDED(hr = IDirectInputDevice8_GetProperty( impl->dinput_device, DIPROP_VIDPID, &vid_pid.diph )))
        *value = HIWORD(vid_pid.dwData);
    return hr;
}

static HRESULT WINAPI game_provider_get_HardwareVendorId( IGameControllerProvider *iface, UINT16 *value )
{
    DIPROPDWORD vid_pid = {.diph = {.dwHeaderSize = sizeof(DIPROPHEADER), .dwSize = sizeof(DIPROPDWORD)}};
    struct provider *impl = impl_from_IGameControllerProvider( iface );
    HRESULT hr;

    TRACE( "iface %p, value %p.\n", iface, value );

    if (impl->host_index >= 0)
    {
        *value = 0x045e; /* Microsoft */
        return S_OK;
    }
    if (SUCCEEDED(hr = IDirectInputDevice8_GetProperty( impl->dinput_device, DIPROP_VIDPID, &vid_pid.diph )))
        *value = LOWORD(vid_pid.dwData);
    return hr;
}

static HRESULT WINAPI game_provider_get_HardwareVersionInfo( IGameControllerProvider *iface, GameControllerVersionInfo *value )
{
    FIXME( "iface %p, value %p stub!\n", iface, value );
    return E_NOTIMPL;
}

static HRESULT WINAPI game_provider_get_IsConnected( IGameControllerProvider *iface, boolean *value )
{
    FIXME( "iface %p, value %p stub!\n", iface, value );
    return E_NOTIMPL;
}

static const struct IGameControllerProviderVtbl game_provider_vtbl =
{
    game_provider_QueryInterface,
    game_provider_AddRef,
    game_provider_Release,
    /* IInspectable methods */
    game_provider_GetIids,
    game_provider_GetRuntimeClassName,
    game_provider_GetTrustLevel,
    /* IGameControllerProvider methods */
    game_provider_get_FirmwareVersionInfo,
    game_provider_get_HardwareProductId,
    game_provider_get_HardwareVendorId,
    game_provider_get_HardwareVersionInfo,
    game_provider_get_IsConnected,
};

static void check_haptics_caps( struct provider *provider, HANDLE device, PHIDP_PREPARSED_DATA preparsed,
                                HIDP_LINK_COLLECTION_NODE *collections, HIDP_VALUE_CAPS *caps )
{
    USHORT count, report_len = provider->caps.FeatureReportByteLength;
    ULONG parent = caps->LinkCollection, waveform = 0;
    char *report_buf = provider->report_buf;
    HIDP_VALUE_CAPS value_caps;
    USAGE_AND_PAGE phy_usages;
    NTSTATUS status;

    while (collections[parent].LinkUsagePage != HID_USAGE_PAGE_HAPTICS ||
           collections[parent].LinkUsage != HID_USAGE_HAPTICS_SIMPLE_CONTROLLER)
        if (!(parent = collections[parent].Parent)) break;

    if (collections[parent].LinkUsagePage != HID_USAGE_PAGE_HAPTICS ||
        collections[parent].LinkUsage != HID_USAGE_HAPTICS_SIMPLE_CONTROLLER)
    {
        WARN( "Failed to find haptics simple controller collection\n" );
        return;
    }
    phy_usages.UsagePage = collections[collections[parent].Parent].LinkUsagePage;
    phy_usages.Usage = collections[collections[parent].Parent].LinkUsage;

    status = HidP_InitializeReportForID( HidP_Feature, caps->ReportID, preparsed, report_buf, report_len );
    if (status != HIDP_STATUS_SUCCESS) WARN( "HidP_InitializeReportForID returned %#lx\n", status );
    if (!HidD_GetFeature( device, report_buf, report_len ))
    {
        WARN( "Failed to get waveform list report, error %lu\n", GetLastError() );
        return;
    }

    status = HidP_GetUsageValue( HidP_Feature, caps->UsagePage, caps->LinkCollection,
                                 caps->NotRange.Usage, &waveform, preparsed, report_buf, report_len );
    if (status != HIDP_STATUS_SUCCESS) WARN( "HidP_GetUsageValue returned %#lx\n", status );

    count = 1;
    status = HidP_GetSpecificValueCaps( HidP_Output, HID_USAGE_PAGE_HAPTICS, parent,
                                        HID_USAGE_HAPTICS_INTENSITY, &value_caps, &count, preparsed );
    if (status != HIDP_STATUS_SUCCESS || !count) WARN( "Failed to get waveform intensity caps, status %#lx\n", status );
    else if (phy_usages.UsagePage == HID_USAGE_PAGE_GENERIC && phy_usages.Usage == HID_USAGE_GENERIC_Z)
    {
        TRACE( "Found left rumble caps, report %u collection %u\n", value_caps.ReportID, value_caps.LinkCollection );
        provider->haptics_report = value_caps.ReportID;
        provider->haptics_left_caps = value_caps;
    }
    else if (phy_usages.UsagePage == HID_USAGE_PAGE_GENERIC && phy_usages.Usage == HID_USAGE_GENERIC_RZ)
    {
        TRACE( "Found right rumble caps, report %u collection %u\n", value_caps.ReportID, value_caps.LinkCollection );
        provider->haptics_report = value_caps.ReportID;
        provider->haptics_right_caps = value_caps;
    }
    else if (waveform == HID_USAGE_HAPTICS_WAVEFORM_RUMBLE)
    {
        TRACE( "Found rumble caps, report %u collection %u\n", value_caps.ReportID, value_caps.LinkCollection );
        provider->haptics_report = value_caps.ReportID;
        provider->haptics_rumble_caps = value_caps;
    }
    else if (waveform == HID_USAGE_HAPTICS_WAVEFORM_BUZZ)
    {
        TRACE( "Found buzz caps, report %u collection %u\n", value_caps.ReportID, value_caps.LinkCollection );
        provider->haptics_report = value_caps.ReportID;
        provider->haptics_buzz_caps = value_caps;
    }
    else FIXME( "Unsupported waveform type %#lx\n", waveform );
}

static void open_haptics_device( struct provider *provider )
{
    HIDP_LINK_COLLECTION_NODE *collections;
    PHIDP_PREPARSED_DATA preparsed = NULL;
    ULONG i, size, coll_count = 0;
    USHORT count, caps_count = 0;
    HIDP_VALUE_CAPS caps[8];
    NTSTATUS status;
    HANDLE device;

    device = CreateFileW( provider->device_path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                          NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED | FILE_FLAG_NO_BUFFERING, 0 );
    if (device == INVALID_HANDLE_VALUE) return;

    if (!HidD_GetPreparsedData( device, &preparsed )) goto failed;
    if (HidP_GetCaps( preparsed, &provider->caps ) != HIDP_STATUS_SUCCESS) goto failed;

    size = max( provider->caps.OutputReportByteLength, provider->caps.FeatureReportByteLength );
    if (!(provider->report_buf = malloc( size ))) goto failed;

    coll_count = provider->caps.NumberLinkCollectionNodes;
    if (!(collections = malloc( sizeof(*collections) * coll_count ))) goto failed;

    status = HidP_GetLinkCollectionNodes( collections, &coll_count, preparsed );
    if (status != HIDP_STATUS_SUCCESS) WARN( "HidP_GetLinkCollectionNodes returned %#lx\n", status );
    else for (i = 0; i < coll_count; ++i)
    {
        if (collections[i].LinkUsagePage != HID_USAGE_PAGE_HAPTICS) continue;
        if (collections[i].LinkUsage == HID_USAGE_HAPTICS_WAVEFORM_LIST)
        {
            count = ARRAY_SIZE(caps) - caps_count;
            status = HidP_GetSpecificValueCaps( HidP_Feature, HID_USAGE_PAGE_ORDINAL, i, 0,
                                                caps + caps_count, &count, preparsed );
            if (status == HIDP_STATUS_SUCCESS) caps_count += count;
        }
    }
    for (i = 0; i < caps_count; ++i) check_haptics_caps( provider, device, preparsed, collections, caps + i );
    free( collections );

    provider->preparsed = preparsed;
    provider->device = device;
    return;

failed:
    free( provider->report_buf );
    provider->report_buf = NULL;
    HidD_FreePreparsedData( preparsed );
    CloseHandle( device );
}

static const DIOBJECTDATAFORMAT data_format_xusb_objs[] =
{
    {NULL,DIJOFS_X,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_Y,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_Z,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_RX,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_RY,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_RZ,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_POV(0),DIDFT_OPTIONAL|DIDFT_POV|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(0),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(1),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(2),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(3),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(4),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(5),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(6),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(7),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(8),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(9),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(10),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(11),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(12),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(13),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(14),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(15),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
};

static const DIDATAFORMAT data_format_xusb =
{
    sizeof(DIDATAFORMAT),
    sizeof(DIOBJECTDATAFORMAT),
    DIDF_ABSAXIS,
    sizeof(DIJOYSTATE2),
    ARRAY_SIZE(data_format_xusb_objs),
    (LPDIOBJECTDATAFORMAT)data_format_xusb_objs
};

static const DIOBJECTDATAFORMAT data_format_hid_objs[] =
{
    {&GUID_XAxis,DIJOFS_X,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {&GUID_YAxis,DIJOFS_Y,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {&GUID_ZAxis,DIJOFS_Z,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {&GUID_RxAxis,DIJOFS_RX,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {&GUID_RyAxis,DIJOFS_RY,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {&GUID_RzAxis,DIJOFS_RZ,DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_SLIDER(0),DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_SLIDER(1),DIDFT_OPTIONAL|DIDFT_AXIS|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_POV(0),DIDFT_OPTIONAL|DIDFT_POV|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_POV(1),DIDFT_OPTIONAL|DIDFT_POV|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_POV(2),DIDFT_OPTIONAL|DIDFT_POV|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_POV(3),DIDFT_OPTIONAL|DIDFT_POV|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(0),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(1),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(2),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(3),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(4),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(5),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(6),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(7),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(8),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(9),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(10),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(11),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(12),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(13),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(14),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(15),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(16),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(17),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(18),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(19),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(20),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(21),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(22),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(23),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(24),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(25),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(26),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(27),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(28),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(29),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(30),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(31),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(32),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(33),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(34),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(35),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(36),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(37),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(38),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(39),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(40),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(41),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(42),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(43),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(44),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(45),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(46),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(47),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(48),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(49),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(50),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(51),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(52),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(53),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(54),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(55),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(56),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(57),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(58),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(59),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(60),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(61),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(62),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(63),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(64),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(65),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(66),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(67),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(68),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(69),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(70),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(71),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(72),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(73),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(74),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(75),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(76),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(77),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(78),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(79),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(80),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(81),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(82),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(83),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(84),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(85),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(86),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(87),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(88),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(89),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(90),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(91),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(92),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(93),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(94),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(95),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(96),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(97),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(98),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(99),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(100),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(101),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(102),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(103),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(104),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(105),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(106),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(107),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(108),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(109),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(110),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(111),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(112),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(113),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(114),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(115),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(116),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(117),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(118),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(119),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(120),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(121),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(122),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(123),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(124),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(125),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(126),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
    {NULL,DIJOFS_BUTTON(127),DIDFT_OPTIONAL|DIDFT_BUTTON|DIDFT_ANYINSTANCE},
};

static const DIDATAFORMAT data_format_hid =
{
    sizeof(DIDATAFORMAT),
    sizeof(DIOBJECTDATAFORMAT),
    DIDF_ABSAXIS,
    sizeof(DIJOYSTATE2),
    ARRAY_SIZE(data_format_hid_objs),
    (LPDIOBJECTDATAFORMAT)data_format_hid_objs
};

void provider_create( const WCHAR *device_path )
{
    IDirectInputDevice8W *dinput_device;
    IGameControllerProvider *provider;
    struct provider *impl, *entry;
    GUID guid = device_path_guid;
    const DIDATAFORMAT *format;
    IDirectInput8W *dinput;
    BOOL found = FALSE;
    const WCHAR *tmp;
    HRESULT hr;

    if (wcsnicmp( device_path, L"\\\\?\\HID#", 8 )) return;
    if ((tmp = wcschr( device_path + 8, '#' )) && !wcsnicmp( tmp - 6, L"&IG_", 4 )) return;
    if (tmp && !wcsnicmp( tmp - 6, L"&XI_", 4 )) format = &data_format_xusb;
    else format = &data_format_hid;

    TRACE( "device_path %s\n", debugstr_w( device_path ) );

    *(const WCHAR **)&guid = device_path;
    if (FAILED(DirectInput8Create( windows_gaming_input, DIRECTINPUT_VERSION, &IID_IDirectInput8W,
                                   (void **)&dinput, NULL ))) return;
    hr = IDirectInput8_CreateDevice( dinput, &guid, &dinput_device, NULL );
    IDirectInput8_Release( dinput );
    if (FAILED(hr)) return;

    if (FAILED(hr = IDirectInputDevice8_SetCooperativeLevel( dinput_device, 0, DISCL_BACKGROUND | DISCL_NONEXCLUSIVE ))) goto done;
    if (FAILED(hr = IDirectInputDevice8_SetDataFormat( dinput_device, format ))) goto done;
    if (FAILED(hr = IDirectInputDevice8_Acquire( dinput_device ))) goto done;

    if (!(impl = calloc( 1, sizeof(*impl) ))) goto done;
    impl->IWineGameControllerProvider_iface.lpVtbl = &wine_provider_vtbl;
    impl->IGameControllerProvider_iface.lpVtbl = &game_provider_vtbl;
    IDirectInputDevice_AddRef( dinput_device );
    impl->dinput_device = dinput_device;
    impl->ref = 1;
    impl->host_index = -1;

    wcscpy( impl->device_path, device_path );
    list_init( &impl->entry );
    open_haptics_device( impl );

    provider = &impl->IGameControllerProvider_iface;
    TRACE( "created WineGameControllerProvider %p\n", provider );

    EnterCriticalSection( &provider_cs );
    LIST_FOR_EACH_ENTRY( entry, &provider_list, struct provider, entry )
        if ((found = !wcsicmp( entry->device_path, device_path ))) break;
    if (!found) list_add_tail( &provider_list, &impl->entry );
    LeaveCriticalSection( &provider_cs );

    if (found) IGameControllerProvider_Release( provider );
    else manager_on_provider_created( provider );
done:
    IDirectInputDevice_Release( dinput_device );
}

void provider_remove( const WCHAR *device_path )
{
    IGameControllerProvider *provider;
    struct provider *entry;
    BOOL found = FALSE;

    TRACE( "device_path %s\n", debugstr_w( device_path ) );

    EnterCriticalSection( &provider_cs );
    LIST_FOR_EACH_ENTRY( entry, &provider_list, struct provider, entry )
        if ((found = !wcsicmp( entry->device_path, device_path ))) break;
    if (found) list_remove( &entry->entry );
    LeaveCriticalSection( &provider_cs );

    if (!found) WARN( "provider not found for device %s\n", debugstr_w( device_path ) );
    else
    {
        provider = &entry->IGameControllerProvider_iface;
        manager_on_provider_removed( provider );
        IGameControllerProvider_Release( provider );
    }
}

/* madeira-bcd: Madeira's host pads as Windows.Gaming.Input gamepads, opt-in
 * with MADEIRA_WGI_HOST_PADS=1 (tools/patch-wine-wgi-host-pads.py). A pad
 * reaches Windows games on iOS through the snapshot Madeira's XInput reads;
 * there is no HID device for it in XInput mode, and this DLL adopts only HID
 * devices, so a game reading only Windows.Gaming.Input.Gamepad (Horizon Zero
 * Dawn) saw no controller. Each connected XInput slot becomes a Gamepad
 * provider; the monitor thread polls the slots twice a second. */
struct madeira_xstate          /* XINPUT_STATE */
{
    DWORD packet;
    WORD buttons;
    BYTE left_trigger;
    BYTE right_trigger;
    SHORT lx;
    SHORT ly;
    SHORT rx;
    SHORT ry;
};

struct madeira_xvibration      /* XINPUT_VIBRATION */
{
    WORD left_motor;
    WORD right_motor;
};

typedef DWORD (WINAPI *madeira_xget_fn)( DWORD index, struct madeira_xstate *state );
typedef DWORD (WINAPI *madeira_xset_fn)( DWORD index, struct madeira_xvibration *vibration );

static madeira_xget_fn madeira_xget;
static madeira_xset_fn madeira_xset;
static BOOL madeira_host_pads_on;

static BOOL WINAPI madeira_host_pads_init( INIT_ONCE *once, void *param, void **context )
{
    WCHAR value[8];
    DWORD len = GetEnvironmentVariableW( L"MADEIRA_WGI_HOST_PADS", value, ARRAY_SIZE(value) );
    HMODULE xinput;

    if (!len || len >= ARRAY_SIZE(value) || wcscmp( value, L"1" )) return TRUE;
    if (!(xinput = LoadLibraryW( L"xinput1_4.dll" )))
    {
        ERR( "[wgi-host] MADEIRA_WGI_HOST_PADS=1, but xinput1_4.dll did not load (error %lu)\n", GetLastError() );
        return TRUE;
    }
    madeira_xget = (madeira_xget_fn)GetProcAddress( xinput, "XInputGetState" );
    madeira_xset = (madeira_xset_fn)GetProcAddress( xinput, "XInputSetState" );
    madeira_host_pads_on = madeira_xget != NULL;
    ERR( "[wgi-host] XInput pads %s as Windows.Gaming.Input gamepads (MADEIRA_WGI_HOST_PADS=1)\n",
         madeira_host_pads_on ? "are published" : "are NOT published (no XInputGetState)" );
    return TRUE;
}

static BOOL madeira_host_pads_enabled( void )
{
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    InitOnceExecuteOnce( &once, madeira_host_pads_init, NULL, NULL );
    return madeira_host_pads_on;
}

/* A thumbstick value as the [0, 1] axis gamepad.c expects. */
static DOUBLE madeira_host_axis( SHORT value )
{
    DOUBLE v = value < 0 ? value / 32768. : value / 32767.;
    return (v + 1.) / 2.;
}

/* XINPUT_STATE to what gamepad.c reads: LeftThumbstickX = 2 * axes[1] - 1,
 * LeftThumbstickY = 2 * axes[0] - 1 (up positive, as in XInput),
 * RightThumbstickX = 2 * axes[3] - 1, RightThumbstickY = 2 * axes[2] - 1,
 * the triggers axes[4] and axes[5], buttons 0-9 A B X Y LB RB View Menu LS RS,
 * the d-pad in switches[0]. */
static void madeira_host_state( const struct madeira_xstate *in, struct WineGameControllerState *out )
{
    static const WORD bits[10] = { 0x1000, 0x2000, 0x4000, 0x8000, 0x0100, 0x0200, 0x0020, 0x0010, 0x0040, 0x0080 };
    static const GameControllerSwitchPosition hat[16] =   /* index: up 1, down 2, left 4, right 8 */
    {
        GameControllerSwitchPosition_Center, GameControllerSwitchPosition_Up,
        GameControllerSwitchPosition_Down, GameControllerSwitchPosition_Center,
        GameControllerSwitchPosition_Left, GameControllerSwitchPosition_UpLeft,
        GameControllerSwitchPosition_DownLeft, GameControllerSwitchPosition_Left,
        GameControllerSwitchPosition_Right, GameControllerSwitchPosition_UpRight,
        GameControllerSwitchPosition_DownRight, GameControllerSwitchPosition_Right,
        GameControllerSwitchPosition_Center, GameControllerSwitchPosition_Up,
        GameControllerSwitchPosition_Down, GameControllerSwitchPosition_Center,
    };
    UINT i;

    memset( out, 0, sizeof(*out) );
    out->axes[0] = madeira_host_axis( in->ly );
    out->axes[1] = madeira_host_axis( in->lx );
    out->axes[2] = madeira_host_axis( in->ry );
    out->axes[3] = madeira_host_axis( in->rx );
    out->axes[4] = in->left_trigger / 255.;
    out->axes[5] = in->right_trigger / 255.;
    for (i = 0; i < ARRAY_SIZE(bits); i++) out->buttons[i] = (in->buttons & bits[i]) != 0;
    out->switches[0] = hat[in->buttons & 0xf];
}

struct host_provider
{
    IWineGameControllerProvider IWineGameControllerProvider_iface;
    IGameControllerProvider IGameControllerProvider_iface;
    LONG ref;
    DWORD index;
    struct WineGameControllerVibration vibration;
};

static inline struct host_provider *host_impl_from_IWineGameControllerProvider( IWineGameControllerProvider *iface )
{
    return CONTAINING_RECORD( iface, struct host_provider, IWineGameControllerProvider_iface );
}

static HRESULT WINAPI host_provider_QueryInterface( IWineGameControllerProvider *iface, REFIID iid, void **out )
{
    struct host_provider *impl = host_impl_from_IWineGameControllerProvider( iface );

    TRACE( "iface %p, iid %s, out %p.\n", iface, debugstr_guid( iid ), out );

    if (IsEqualGUID( iid, &IID_IUnknown ) ||
        IsEqualGUID( iid, &IID_IInspectable ) ||
        IsEqualGUID( iid, &IID_IAgileObject ) ||
        IsEqualGUID( iid, &IID_IWineGameControllerProvider ))
    {
        IInspectable_AddRef( (*out = &impl->IWineGameControllerProvider_iface) );
        return S_OK;
    }

    if (IsEqualGUID( iid, &IID_IGameControllerProvider ))
    {
        IInspectable_AddRef( (*out = &impl->IGameControllerProvider_iface) );
        return S_OK;
    }

    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG WINAPI host_provider_AddRef( IWineGameControllerProvider *iface )
{
    struct host_provider *impl = host_impl_from_IWineGameControllerProvider( iface );
    return InterlockedIncrement( &impl->ref );
}

static ULONG WINAPI host_provider_Release( IWineGameControllerProvider *iface )
{
    struct host_provider *impl = host_impl_from_IWineGameControllerProvider( iface );
    ULONG ref = InterlockedDecrement( &impl->ref );
    if (!ref) free( impl );
    return ref;
}

static HRESULT WINAPI host_provider_GetIids( IWineGameControllerProvider *iface, ULONG *iid_count, IID **iids )
{
    return E_NOTIMPL;
}

static HRESULT WINAPI host_provider_GetRuntimeClassName( IWineGameControllerProvider *iface, HSTRING *class_name )
{
    return E_NOTIMPL;
}

static HRESULT WINAPI host_provider_GetTrustLevel( IWineGameControllerProvider *iface, TrustLevel *trust_level )
{
    return E_NOTIMPL;
}

static HRESULT WINAPI host_provider_get_NonRoamableId( IWineGameControllerProvider *iface, HSTRING *value )
{
    return E_NOTIMPL;
}

static HRESULT WINAPI host_provider_get_DisplayName( IWineGameControllerProvider *iface, HSTRING *value )
{
    static const WCHAR name[] = L"Controller (Xbox 360 For Windows)";
    return WindowsCreateString( name, wcslen( name ), value );
}

static HRESULT WINAPI host_provider_get_Type( IWineGameControllerProvider *iface, WineGameControllerType *value )
{
    *value = WineGameControllerType_Gamepad;
    return S_OK;
}

static HRESULT WINAPI host_provider_get_AxisCount( IWineGameControllerProvider *iface, INT32 *value )
{
    *value = 6;
    return S_OK;
}

static HRESULT WINAPI host_provider_get_ButtonCount( IWineGameControllerProvider *iface, INT32 *value )
{
    *value = 10;
    return S_OK;
}

static HRESULT WINAPI host_provider_get_SwitchCount( IWineGameControllerProvider *iface, INT32 *value )
{
    *value = 1;
    return S_OK;
}

static HRESULT WINAPI host_provider_get_State( IWineGameControllerProvider *iface, struct WineGameControllerState *out )
{
    struct host_provider *impl = host_impl_from_IWineGameControllerProvider( iface );
    struct madeira_xstate state = {0};

    if (!madeira_xget || madeira_xget( impl->index, &state )) memset( &state, 0, sizeof(state) );
    madeira_host_state( &state, out );
    out->timestamp = GetTickCount64();
    return S_OK;
}

static HRESULT WINAPI host_provider_get_Vibration( IWineGameControllerProvider *iface, struct WineGameControllerVibration *out )
{
    struct host_provider *impl = host_impl_from_IWineGameControllerProvider( iface );
    *out = impl->vibration;
    return S_OK;
}

static HRESULT WINAPI host_provider_put_Vibration( IWineGameControllerProvider *iface, struct WineGameControllerVibration value )
{
    struct host_provider *impl = host_impl_from_IWineGameControllerProvider( iface );
    struct madeira_xvibration motors = { value.rumble, value.buzz };

    if (!memcmp( &impl->vibration, &value, sizeof(value) )) return S_OK;
    impl->vibration = value;
    if (madeira_xset) madeira_xset( impl->index, &motors );
    return S_OK;
}

static HRESULT WINAPI host_provider_get_ForceFeedbackMotor( IWineGameControllerProvider *iface, IForceFeedbackMotor **value )
{
    *value = NULL;
    return S_OK;
}

static const struct IWineGameControllerProviderVtbl host_wine_provider_vtbl =
{
    host_provider_QueryInterface,
    host_provider_AddRef,
    host_provider_Release,
    /* IInspectable methods */
    host_provider_GetIids,
    host_provider_GetRuntimeClassName,
    host_provider_GetTrustLevel,
    /* IWineGameControllerProvider methods */
    host_provider_get_NonRoamableId,
    host_provider_get_DisplayName,
    host_provider_get_Type,
    host_provider_get_AxisCount,
    host_provider_get_ButtonCount,
    host_provider_get_SwitchCount,
    host_provider_get_State,
    host_provider_get_Vibration,
    host_provider_put_Vibration,
    host_provider_get_ForceFeedbackMotor,
};

DEFINE_IINSPECTABLE_( host_game_provider, IGameControllerProvider, struct host_provider,
                      host_impl_from_IGameControllerProvider, IGameControllerProvider_iface,
                      &impl->IWineGameControllerProvider_iface )

static HRESULT WINAPI host_game_provider_get_FirmwareVersionInfo( IGameControllerProvider *iface, GameControllerVersionInfo *value )
{
    return E_NOTIMPL;
}

static HRESULT WINAPI host_game_provider_get_HardwareProductId( IGameControllerProvider *iface, UINT16 *value )
{
    *value = 0x028e;   /* Xbox 360 Controller */
    return S_OK;
}

static HRESULT WINAPI host_game_provider_get_HardwareVendorId( IGameControllerProvider *iface, UINT16 *value )
{
    *value = 0x045e;   /* Microsoft */
    return S_OK;
}

static HRESULT WINAPI host_game_provider_get_HardwareVersionInfo( IGameControllerProvider *iface, GameControllerVersionInfo *value )
{
    return E_NOTIMPL;
}

static HRESULT WINAPI host_game_provider_get_IsConnected( IGameControllerProvider *iface, boolean *value )
{
    *value = TRUE;
    return S_OK;
}

static const struct IGameControllerProviderVtbl host_game_provider_vtbl =
{
    host_game_provider_QueryInterface,
    host_game_provider_AddRef,
    host_game_provider_Release,
    /* IInspectable methods */
    host_game_provider_GetIids,
    host_game_provider_GetRuntimeClassName,
    host_game_provider_GetTrustLevel,
    /* IGameControllerProvider methods */
    host_game_provider_get_FirmwareVersionInfo,
    host_game_provider_get_HardwareProductId,
    host_game_provider_get_HardwareVendorId,
    host_game_provider_get_HardwareVersionInfo,
    host_game_provider_get_IsConnected,
};

static struct host_provider *madeira_host_providers[4];

/* On the monitor thread: one provider per connected XInput slot. */
void madeira_host_pads_poll( void )
{
    DWORD i;

    if (!madeira_host_pads_enabled()) return;
    for (i = 0; i < ARRAY_SIZE(madeira_host_providers); i++)
    {
        struct madeira_xstate state;
        BOOL connected = !madeira_xget( i, &state );
        struct host_provider *impl;

        EnterCriticalSection( &provider_cs );
        impl = madeira_host_providers[i];
        if (connected == (impl != NULL))
        {
            LeaveCriticalSection( &provider_cs );
            continue;
        }
        if (connected)
        {
            if (!(impl = calloc( 1, sizeof(*impl) )))
            {
                LeaveCriticalSection( &provider_cs );
                continue;
            }
            impl->IWineGameControllerProvider_iface.lpVtbl = &host_wine_provider_vtbl;
            impl->IGameControllerProvider_iface.lpVtbl = &host_game_provider_vtbl;
            impl->ref = 1;
            impl->index = i;
        }
        madeira_host_providers[i] = connected ? impl : NULL;
        LeaveCriticalSection( &provider_cs );

        if (connected)
        {
            ERR( "[wgi-host] XInput slot %lu connected: a Windows.Gaming.Input gamepad\n", i );
            manager_on_provider_created( &impl->IGameControllerProvider_iface );
        }
        else
        {
            ERR( "[wgi-host] XInput slot %lu disconnected: its gamepad is removed\n", i );
            manager_on_provider_removed( &impl->IGameControllerProvider_iface );
            IGameControllerProvider_Release( &impl->IGameControllerProvider_iface );
        }
    }
}

/* The monitor thread's wait: as before without host pads; with them, a poll at
 * least every 500 ms. FALSE ends the thread, as a failed wait did before. */
BOOL madeira_host_pads_wait( void )
{
    static DWORD last_poll;
    BOOL on = madeira_host_pads_enabled();
    DWORD ret = MsgWaitForMultipleObjectsEx( 0, NULL, on ? 500 : INFINITE, QS_ALLINPUT, MWMO_ALERTABLE );

    if (on && (ret == WAIT_TIMEOUT || GetTickCount() - last_poll >= 500))
    {
        last_poll = GetTickCount();
        madeira_host_pads_poll();
    }
    return ret == WAIT_OBJECT_0 || (on && ret == WAIT_TIMEOUT);
}
