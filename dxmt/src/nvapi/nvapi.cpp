#include "../d3d11/d3d11_interfaces.hpp"
#include "../dxgi/dxgi_interfaces.h"
#include "com/com_pointer.hpp"
#include "log/log.hpp"
#include "nvapi_lite_common.h"
#include "util_string.hpp"
#include "winemetal.h"
#include "wsi_monitor.hpp"
#include <string>
#define __NVAPI_EMPTY_SAL
#include "nvapi.h"
#include "nvapi_interface.h"
#include "nvShaderExtnEnums.h"
#undef __NVAPI_EMPTY_SAL

namespace dxmt {
Logger Logger::s_instance("nvapi.log");

static std::atomic_uint32_t s_initialization_count = 0;

/*
 * The caller's NvAPI_ShortString is not zeroed, so the copy has to end in a NUL
 */
static void
CopyShortString(NvAPI_ShortString dst, const std::string &src) {
  size_t size = std::min<size_t>(src.size(), NVAPI_SHORT_STRING_MAX - 1);
  memcpy(dst, src.c_str(), size);
  dst[size] = '\0';
}

/*
 * Driver 581.57 (branch r580_00), the same driver the display adapter's registry
 * entry names; titles that check for a minimum driver accept it
 */
static constexpr NvU32 kDriverVersion = 58157;
static constexpr const char *kDriverBranch = "r580_00";

NVAPI_INTERFACE
NvAPI_Initialize() {
  if (FAILED(DXGIGetDebugInterface1(0, DXMT_NVEXT_GUID, nullptr))) {
    return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
  }
  s_initialization_count++;
  return NVAPI_OK;
};

NVAPI_INTERFACE
NvAPI_Unload() {
  if (!s_initialization_count)
    return NVAPI_API_NOT_INITIALIZED;
  s_initialization_count--;
  return NVAPI_OK;
};

NVAPI_INTERFACE
NvAPI_SYS_GetDriverAndBranchVersion(NvU32 *pDriverVersion,
                                    NvAPI_ShortString szBuildBranchString) {
  std::string build_str = kDriverBranch;

  if (!pDriverVersion || !szBuildBranchString)
    return NVAPI_INVALID_ARGUMENT;

  CopyShortString(szBuildBranchString, build_str);
  *pDriverVersion = kDriverVersion;

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GetDisplayDriverVersion(NvDisplayHandle hNvDisplay, NV_DISPLAY_DRIVER_VERSION *pVersion) {
  std::string build_str = kDriverBranch;
  std::string adapter_str = "NVIDIA GeForce RTX";

  if (!pVersion)
    return NVAPI_INVALID_ARGUMENT;

  if (pVersion->version != NV_DISPLAY_DRIVER_VERSION_VER)
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;

  pVersion->drvVersion = kDriverVersion;
  pVersion->bldChangeListNum = 0;
  CopyShortString(pVersion->szBuildBranchString, build_str);
  CopyShortString(pVersion->szAdapterString, adapter_str);

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GetInterfaceVersionString(NvAPI_ShortString szDesc) {
  std::string version_str = "NVAPI Open Source Interface (DXMT-NVAPI)";

  if (!szDesc)
    return NVAPI_INVALID_ARGUMENT;

  CopyShortString(szDesc, version_str);

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_D3D_GetCurrentSLIState(IUnknown *pDevice,
                             NV_GET_CURRENT_SLI_STATE *pSliState) {
  if (!pDevice || !pSliState)
    return NVAPI_INVALID_ARGUMENT;

  switch (pSliState->version) {
  case NV_GET_CURRENT_SLI_STATE_VER1:
    pSliState->maxNumAFRGroups = 1;
    pSliState->numAFRGroups = 1;
    pSliState->currentAFRIndex = 0;
    pSliState->nextFrameAFRIndex = 0;
    pSliState->previousFrameAFRIndex = 0;
    pSliState->bIsCurAFRGroupNew = FALSE;
    break;
  case NV_GET_CURRENT_SLI_STATE_VER2:
    pSliState->maxNumAFRGroups = 1;
    pSliState->numAFRGroups = 1;
    pSliState->currentAFRIndex = 0;
    pSliState->nextFrameAFRIndex = 0;
    pSliState->previousFrameAFRIndex = 0;
    pSliState->bIsCurAFRGroupNew = FALSE;
    pSliState->numVRSLIGpus = 0;
    break;
  default:
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  return NVAPI_OK;
}

NVAPI_INTERFACE NvAPI_GetErrorMessage(NvAPI_Status nr,
                                      NvAPI_ShortString szDesc) {
  szDesc[0] = '\0';
  return NVAPI_OK;
}

Com<IMTLD3D11ContextExt> GetD3D11ContextExt(IUnknown *pDeviceOrContext) {
  Com<IMTLD3D11ContextExt> context_ext;
  if (FAILED(pDeviceOrContext->QueryInterface(IID_PPV_ARGS(&context_ext)))) {
    Com<ID3D11Device> device;
    if (FAILED(pDeviceOrContext->QueryInterface(IID_PPV_ARGS(&device)))) {
      return nullptr;
    }
    Com<ID3D11DeviceContext> context;
    device->GetImmediateContext(&context);
    if (FAILED(context->QueryInterface(IID_PPV_ARGS(&context_ext)))) {
      return nullptr;
    }
  }
  return context_ext;
}

NVAPI_INTERFACE NvAPI_D3D11_BeginUAVOverlap(__in IUnknown *pDeviceOrContext) {
  if (!pDeviceOrContext)
    return NVAPI_INVALID_ARGUMENT;
  auto context = GetD3D11ContextExt(pDeviceOrContext);
  if (!context)
    return NVAPI_INVALID_ARGUMENT;
  context->BeginUAVOverlap();
  return NVAPI_OK;
}

NVAPI_INTERFACE NvAPI_D3D11_EndUAVOverlap(__in IUnknown *pDeviceOrContext) {
  if (!pDeviceOrContext)
    return NVAPI_INVALID_ARGUMENT;
  auto context = GetD3D11ContextExt(pDeviceOrContext);
  if (!context)
    return NVAPI_INVALID_ARGUMENT;
  context->EndUAVOverlap();
  return NVAPI_OK;
}

NVAPI_INTERFACE NvAPI_D3D11_SetDepthBoundsTest(IUnknown *pDeviceOrContext,
                                               NvU32 bEnable, float fMinDepth,
                                               float fMaxDepth) {
  return NVAPI_NOT_SUPPORTED;
}

NVAPI_INTERFACE NvAPI_D3D11_IsNvShaderExtnOpCodeSupported(
    __in IUnknown *pDev, __in NvU32 opCode, __out bool *pSupported) {
  switch (opCode) {
  /*
   * UnrealEngine queries it for checking if Nanite capability
   */
  case NV_EXTN_OP_UINT64_ATOMIC:
  /*
   * UnrealEngine queries it for checking if GPU support time query (NVIDIA-specific workaround)
   */
  case NV_EXTN_OP_SHFL:
  /*
   * SOTTR and ROTTR queries it.
   */
  case NV_EXTN_OP_FP16_ATOMIC:
    *pSupported = false;
    break;
  default:
    WARN("nvapi: unsupported shader extension opcode ", opCode);
    *pSupported = false;
    break;
  }
  return NVAPI_OK;
}

Com<IMTLD3D11DeviceExt> GetD3D11DeviceExt(IUnknown *pDevice) {
  Com<IMTLD3D11DeviceExt> device_ext;
  if (FAILED(pDevice->QueryInterface(IID_PPV_ARGS(&device_ext)))) {
    return nullptr;
  }
  return device_ext;
}

NVAPI_INTERFACE NvAPI_D3D11_SetNvShaderExtnSlot(__in IUnknown *pDev,
                                                __in NvU32 uavSlot) {
  auto device_ext = GetD3D11DeviceExt(pDev);
  if (!device_ext)
    return NVAPI_INVALID_ARGUMENT;
  device_ext->SetShaderExtensionSlot(uavSlot);
  return NVAPI_OK;
}

static bool
IsPrimaryAdapterName(const char *name) {
  DISPLAY_DEVICEA device = {};
  device.cb = sizeof(device);
  for (DWORD i = 0; name && EnumDisplayDevicesA(nullptr, i, &device, 0); i++) {
    if ((device.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) && !_stricmp(device.DeviceName, name))
      return true;
    device = {};
    device.cb = sizeof(device);
  }
  return false;
}

NVAPI_INTERFACE
NvAPI_DISP_GetDisplayIdByDisplayName(const char *displayName, NvU32 *displayId) {
  struct MonitorEnumInfo {
    std::string name;
    HMONITOR handle;
    bool is_primary;
  };

  MonitorEnumInfo info;
  info.name = displayName;
  info.handle = nullptr;
  ::EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR hmon, HDC hdc, LPRECT rect, LPARAM lp) -> BOOL {
        auto data = reinterpret_cast<MonitorEnumInfo *>(lp);

        ::MONITORINFOEXW monitor_info;
        monitor_info.cbSize = sizeof(monitor_info);

        if (!::GetMonitorInfoW(hmon, reinterpret_cast<MONITORINFO *>(&monitor_info)))
          return TRUE;

        if (data->name != str::fromws(monitor_info.szDevice))
          return TRUE;

        data->handle = hmon;
        data->is_primary = monitor_info.dwFlags & MONITORINFOF_PRIMARY;
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&info)
  );

  /*
   * The GDI name of the primary adapter (what DXGI_OUTPUT_DESC and
   * EnumDisplayDevices report) is the primary display, even when user32
   * names its monitor differently
   */
  if (!info.handle && IsPrimaryAdapterName(displayName)) {
    *displayId = WMTGetPrimaryDisplayId();
    return NVAPI_OK;
  }

  if (!info.handle)
    return NVAPI_NVIDIA_DEVICE_NOT_FOUND;

  *displayId = info.is_primary ? WMTGetPrimaryDisplayId() : WMTGetSecondaryDisplayId();

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_D3D_GetObjectHandleForResource(IUnknown *pDevice, IUnknown *pResource, NVDX_ObjectHandle *pHandle) {
  /*
   * SLI related API, return resource pointer as fake handle, since we won't use the handle anyway
   */
  *pHandle = (NVDX_ObjectHandle)pResource;
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_D3D_SetResourceHint(
    IUnknown *pDev, NVDX_ObjectHandle obj, NVAPI_D3D_SETRESOURCEHINT_CATEGORY dwHintCategory, NvU32 dwHintName,
    NvU32 *pdwHintValue
) {
  /*
   * SLI related API, just do nothing
   */
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_EnumPhysicalGPUs(NvPhysicalGpuHandle nvGPUHandle[NVAPI_MAX_PHYSICAL_GPUS], NvU32 *pGpuCount) {
  if (!nvGPUHandle || !pGpuCount)
    return NVAPI_INVALID_ARGUMENT;

  auto devices = WMT::CopyAllDevices();
  auto adapter_count = devices.count();
  if (adapter_count == 0)
    return NVAPI_NVIDIA_DEVICE_NOT_FOUND;

  *pGpuCount = adapter_count;
  for (unsigned i = 0; i < adapter_count; i++) {
    nvGPUHandle[i] = (NvPhysicalGpuHandle)devices.object(i).registryID();
  }

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_EnumLogicalGPUs(NvLogicalGpuHandle nvGPUHandle[NVAPI_MAX_LOGICAL_GPUS], NvU32 *pGpuCount) {
  if (!nvGPUHandle || !pGpuCount)
    return NVAPI_INVALID_ARGUMENT;

  auto devices = WMT::CopyAllDevices();
  auto adapter_count = devices.count();
  if (adapter_count == 0)
    return NVAPI_NVIDIA_DEVICE_NOT_FOUND;

  *pGpuCount = adapter_count;
  for (unsigned i = 0; i < adapter_count; i++) {
    nvGPUHandle[i] = (NvLogicalGpuHandle)devices.object(i).registryID();
  }

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GetPhysicalGPUsFromDisplay(NvDisplayHandle hNvDisp, NvPhysicalGpuHandle nvGPUHandle[NVAPI_MAX_PHYSICAL_GPUS], NvU32 *pGpuCount) {
  if (!hNvDisp || !nvGPUHandle || !pGpuCount)
    return NVAPI_INVALID_ARGUMENT;

  HMONITOR monitor = (HMONITOR)hNvDisp;
  if (!monitor)
    return NVAPI_NVIDIA_DEVICE_NOT_FOUND;

  auto devices = WMT::CopyAllDevices();
  auto adapter_count = devices.count();
  if (adapter_count == 0)
    return NVAPI_NVIDIA_DEVICE_NOT_FOUND;

  unsigned count_devices = 0;
  for (unsigned i = 0; i < adapter_count; i++) {
    // TODO: Currently assuming all GPU instances are connected to specific monitor
    nvGPUHandle[count_devices++] = (NvPhysicalGpuHandle)devices.object(i).registryID();
  }
  *pGpuCount = count_devices;

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_Disp_GetHdrCapabilities(NvU32 displayId, NV_HDR_CAPABILITIES *pHdrCapabilities) {
  WMTDisplayDescription desc;
  WMTGetDisplayDescription(displayId, &desc);

  switch (pHdrCapabilities->version) {
  case NV_HDR_CAPABILITIES_VER1: {
    *reinterpret_cast<NV_HDR_CAPABILITIES_V1 *>(pHdrCapabilities) = {};
    pHdrCapabilities->version = NV_HDR_CAPABILITIES_VER1;
    break;
  }
  case NV_HDR_CAPABILITIES_VER2: {
    *reinterpret_cast<NV_HDR_CAPABILITIES_V2 *>(pHdrCapabilities) = {};
    pHdrCapabilities->version = NV_HDR_CAPABILITIES_VER2;
    break;
  }
  case NV_HDR_CAPABILITIES_VER3: {
    *pHdrCapabilities = {};
    pHdrCapabilities->version = NV_HDR_CAPABILITIES_VER3;
    break;
  }
  default:
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  auto cap_out = reinterpret_cast<NV_HDR_CAPABILITIES_V1 *>(pHdrCapabilities);

  cap_out->isST2084EotfSupported = desc.maximum_potential_edr_color_component_value > 1.0;

  cap_out->display_data.displayPrimary_x0 = desc.red_primaries[0] * 50000;
  cap_out->display_data.displayPrimary_y0 = desc.red_primaries[1] * 50000;
  cap_out->display_data.displayPrimary_x1 = desc.green_primaries[0] * 50000;
  cap_out->display_data.displayPrimary_y1 = desc.green_primaries[1] * 50000;
  cap_out->display_data.displayPrimary_x2 = desc.blue_primaries[0] * 50000;
  cap_out->display_data.displayPrimary_y2 = desc.blue_primaries[1] * 50000;
  cap_out->display_data.displayWhitePoint_x = desc.white_points[0] * 50000;
  cap_out->display_data.displayWhitePoint_y = desc.white_points[1] * 50000;
  cap_out->display_data.desired_content_max_luminance = desc.maximum_potential_edr_color_component_value * 100;
  cap_out->display_data.desired_content_min_luminance = 1;
  cap_out->display_data.desired_content_max_frame_average_luminance =
      cap_out->display_data.desired_content_max_luminance;

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_Disp_HdrColorControl(NvU32 displayId, NV_HDR_COLOR_DATA *pHdrColorData) {
  switch (pHdrColorData->version) {
  case NV_HDR_COLOR_DATA_VER1:
  case NV_HDR_COLOR_DATA_VER2:
    break;
  default:
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  WMTHDRMetadata metadata;
  WMTColorSpace colorspace = WMTColorSpaceSRGB;

  if (pHdrColorData->cmd == NV_HDR_CMD_GET) {
    if (WMTQueryDisplaySetting(displayId, &colorspace, &metadata)) {
      pHdrColorData->hdrMode = colorspace == WMTColorSpaceHDR_scRGB ? NV_HDR_MODE_UHDA
                               : colorspace == WMTColorSpaceHDR_PQ  ? NV_HDR_MODE_UHDA_PASSTHROUGH
                                                                    : NV_HDR_MODE_OFF;
      pHdrColorData->mastering_display_data.displayPrimary_x0 = metadata.red_primary[0];
      pHdrColorData->mastering_display_data.displayPrimary_y0 = metadata.red_primary[1];
      pHdrColorData->mastering_display_data.displayPrimary_x1 = metadata.green_primary[0];
      pHdrColorData->mastering_display_data.displayPrimary_y1 = metadata.green_primary[1];
      pHdrColorData->mastering_display_data.displayPrimary_x2 = metadata.blue_primary[0];
      pHdrColorData->mastering_display_data.displayPrimary_y2 = metadata.blue_primary[1];
      pHdrColorData->mastering_display_data.displayWhitePoint_x = metadata.white_point[0];
      pHdrColorData->mastering_display_data.displayWhitePoint_y = metadata.white_point[1];
      pHdrColorData->mastering_display_data.max_display_mastering_luminance = metadata.max_mastering_luminance;
      pHdrColorData->mastering_display_data.min_display_mastering_luminance = metadata.min_mastering_luminance;
      pHdrColorData->mastering_display_data.max_content_light_level = metadata.max_content_light_level;
      pHdrColorData->mastering_display_data.max_frame_average_light_level = metadata.max_frame_average_light_level;
    } else {
      WMTDisplayDescription desc;
      WMTGetDisplayDescription(displayId, &desc);
      pHdrColorData->hdrMode = NV_HDR_MODE_OFF;
      pHdrColorData->mastering_display_data.displayPrimary_x0 = desc.red_primaries[0] * 50000;
      pHdrColorData->mastering_display_data.displayPrimary_y0 = desc.red_primaries[1] * 50000;
      pHdrColorData->mastering_display_data.displayPrimary_x1 = desc.green_primaries[0] * 50000;
      pHdrColorData->mastering_display_data.displayPrimary_y1 = desc.green_primaries[1] * 50000;
      pHdrColorData->mastering_display_data.displayPrimary_x2 = desc.blue_primaries[0] * 50000;
      pHdrColorData->mastering_display_data.displayPrimary_y2 = desc.blue_primaries[1] * 50000;
      pHdrColorData->mastering_display_data.displayWhitePoint_x = desc.white_points[0] * 50000;
      pHdrColorData->mastering_display_data.displayWhitePoint_y = desc.white_points[1] * 50000;
      pHdrColorData->mastering_display_data.max_display_mastering_luminance =
          desc.maximum_potential_edr_color_component_value * 100;
      pHdrColorData->mastering_display_data.min_display_mastering_luminance = 1;
      pHdrColorData->mastering_display_data.max_content_light_level =
          desc.maximum_potential_edr_color_component_value * 100;
      pHdrColorData->mastering_display_data.max_frame_average_light_level =
          desc.maximum_potential_edr_color_component_value * 100;
    }
  } else {
    if (pHdrColorData->hdrMode != NV_HDR_MODE_OFF) {
      metadata.red_primary[0] = pHdrColorData->mastering_display_data.displayPrimary_x0;
      metadata.red_primary[1] = pHdrColorData->mastering_display_data.displayPrimary_y0;
      metadata.green_primary[0] = pHdrColorData->mastering_display_data.displayPrimary_x1;
      metadata.green_primary[1] = pHdrColorData->mastering_display_data.displayPrimary_y1;
      metadata.blue_primary[0] = pHdrColorData->mastering_display_data.displayPrimary_x2;
      metadata.blue_primary[1] = pHdrColorData->mastering_display_data.displayPrimary_y2;
      metadata.white_point[0] = pHdrColorData->mastering_display_data.displayWhitePoint_x;
      metadata.white_point[1] = pHdrColorData->mastering_display_data.displayWhitePoint_y;
      metadata.max_mastering_luminance = pHdrColorData->mastering_display_data.max_display_mastering_luminance;
      metadata.min_mastering_luminance = pHdrColorData->mastering_display_data.min_display_mastering_luminance;
      metadata.max_content_light_level = pHdrColorData->mastering_display_data.max_content_light_level;
      metadata.max_frame_average_light_level = pHdrColorData->mastering_display_data.max_frame_average_light_level;
      colorspace = pHdrColorData->hdrMode == NV_HDR_MODE_UHDA ? WMTColorSpaceHDR_scRGB : WMTColorSpaceHDR_PQ;
      WMTUpdateDisplaySetting(displayId, colorspace, &metadata);
    } else {
      WMTUpdateDisplaySetting(displayId, WMTColorSpaceSRGB, nullptr);
    }
  }

  if (pHdrColorData->version == NV_HDR_COLOR_DATA_VER2) {
    auto pHDRColorDataV2 = reinterpret_cast<NV_HDR_COLOR_DATA_V2 *>(pHdrColorData);
    if (pHDRColorDataV2->cmd == NV_HDR_CMD_GET) {
      pHDRColorDataV2->hdrColorFormat = NV_COLOR_FORMAT_RGB;
      pHDRColorDataV2->hdrDynamicRange = NV_DYNAMIC_RANGE_VESA;
      pHDRColorDataV2->hdrBpc = NV_BPC_10;
    }
  }

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_EnumNvidiaDisplayHandle(NvU32 thisEnum, NvDisplayHandle *pNvDispHandle) {
  if (!pNvDispHandle)
    return NVAPI_INVALID_ARGUMENT;

  HMONITOR monitor = wsi::enumMonitors(thisEnum);

  if (!monitor)
    return NVAPI_END_ENUMERATION;
  *pNvDispHandle = (NvDisplayHandle)monitor;
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GPU_GetConnectedDisplayIds(
    NvPhysicalGpuHandle hPhysicalGpu, NV_GPU_DISPLAYIDS *pDisplayIds, NvU32 *pDisplayIdCount, NvU32 flags
) {
  if (pDisplayIdCount == nullptr)
    return NVAPI_INVALID_ARGUMENT;

  auto primary_display_id = WMTGetPrimaryDisplayId();
  auto nonprimary_display_id = WMTGetSecondaryDisplayId();

  unsigned count = primary_display_id != 0 ? nonprimary_display_id != 0 ? 2 : 1 : 0;
  if (pDisplayIds == nullptr) {
    *pDisplayIdCount = count;
    return NVAPI_OK;
  }

  if (*pDisplayIdCount < count) {
    *pDisplayIdCount = count;
    return NVAPI_INSUFFICIENT_BUFFER;
  }

  for (unsigned i = 0; i < count; i++) {
    auto version = pDisplayIds[i].version;
    switch (version) {
    case NV_GPU_DISPLAYIDS_VER1:
    case NV_GPU_DISPLAYIDS_VER2:
      break;
    default:
      return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
    }
    pDisplayIds[i] = {};
    pDisplayIds[i].version = version;
    pDisplayIds[i].displayId = i ? nonprimary_display_id : primary_display_id;
    pDisplayIds[i].connectorType = NV_MONITOR_CONN_TYPE_UNKNOWN;
    pDisplayIds[i].isActive = true;
    pDisplayIds[i].isConnected = true;
    pDisplayIds[i].isPhysicallyConnected = true;
  }
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_DISP_GetMonitorCapabilities(__in NvU32 displayId, __inout NV_MONITOR_CAPABILITIES *pMonitorCapabilities) {
  if (!pMonitorCapabilities)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_NOT_SUPPORTED;
}

NVAPI_INTERFACE
NvAPI_GPU_GetAllClockFrequencies(__in NvPhysicalGpuHandle hPhysicalGPU,
                                 __inout NV_GPU_CLOCK_FREQUENCIES *pClkFreqs) {
  if (!pClkFreqs)
    return NVAPI_INVALID_ARGUMENT;

  NvU32 version = pClkFreqs->version;
  switch (version) {
  case NV_GPU_CLOCK_FREQUENCIES_VER_1:
  case NV_GPU_CLOCK_FREQUENCIES_VER_2:
  case NV_GPU_CLOCK_FREQUENCIES_VER_3:
    break;
  default:
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  // NVIDIA GeForce RTX 4090: base 2235 MHz, boost 2520 MHz, memory 10501 MHz (in kHz)
  // V1 has no clock type and reports the current clocks
  bool boost = version != NV_GPU_CLOCK_FREQUENCIES_VER_1 &&
               pClkFreqs->ClockType == NV_GPU_CLOCK_FREQUENCIES_BOOST_CLOCK;
  memset(pClkFreqs->domain, 0, sizeof(pClkFreqs->domain));
  pClkFreqs->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].bIsPresent = 1;
  pClkFreqs->domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS].frequency = boost ? 2520000 : 2235000;
  pClkFreqs->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].bIsPresent = 1;
  pClkFreqs->domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY].frequency = 10501000;

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GPU_GetArchInfo(NvPhysicalGpuHandle hPhysicalGpu, NV_GPU_ARCH_INFO *pGpuArchInfo) {
  if (!hPhysicalGpu || !pGpuArchInfo)
    return NVAPI_INVALID_ARGUMENT;

  // NVIDIA GeForce RTX 4090
  switch (pGpuArchInfo->version) {
    case NV_GPU_ARCH_INFO_VER_1: {
      auto pGpuArchInfoV1 = (NV_GPU_ARCH_INFO_V1 *)(pGpuArchInfo);
      pGpuArchInfoV1->architecture = NV_GPU_ARCHITECTURE_AD100;
      pGpuArchInfoV1->implementation = NV_GPU_ARCH_IMPLEMENTATION_AD102;
      pGpuArchInfoV1->revision = NV_GPU_CHIP_REV_UNKNOWN;
      break;
    }
    case NV_GPU_ARCH_INFO_VER_2:
      pGpuArchInfo->architecture_id = NV_GPU_ARCHITECTURE_AD100;
      pGpuArchInfo->implementation_id = NV_GPU_ARCH_IMPLEMENTATION_AD102;
      pGpuArchInfo->revision_id = NV_GPU_CHIP_REV_UNKNOWN;
      break;
    default:
      return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GPU_GetGpuCoreCount(NvPhysicalGpuHandle hPhysicalGpu, NvU32 *pCount) {
  if (!hPhysicalGpu || !pCount)
    return NVAPI_INVALID_ARGUMENT;

  // NVIDIA GeForce RTX 4090
  *pCount = 16384;
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GPU_GetBusId(NvPhysicalGpuHandle hPhysicalGpu, NvU32 *pBusId) {
  if (!hPhysicalGpu || !pBusId)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_NOT_SUPPORTED;
}

NVAPI_INTERFACE
NvAPI_GPU_GetBusType(NvPhysicalGpuHandle hPhysicalGpu, NV_GPU_BUS_TYPE *pBusType) {
  if (!hPhysicalGpu || !pBusType)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_NOT_SUPPORTED;
}

NVAPI_INTERFACE
NvAPI_GPU_GetMemoryInfo(NvPhysicalGpuHandle hPhysicalGpu, NV_DISPLAY_DRIVER_MEMORY_INFO *pMemoryInfo) {
  if (!hPhysicalGpu || !pMemoryInfo)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_NOT_SUPPORTED;
}

NVAPI_INTERFACE
NvAPI_GPU_GetMemoryInfoEx(NvPhysicalGpuHandle hPhysicalGpu, NV_GPU_MEMORY_INFO_EX *pMemoryInfo) {
  if (!hPhysicalGpu || !pMemoryInfo)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_NOT_SUPPORTED;
}

NVAPI_INTERFACE
NvAPI_GPU_GetFullName(NvPhysicalGpuHandle hPhysicalGpu, NvAPI_ShortString szName) {
  std::string adapter_str = "NVIDIA GeForce RTX 4090";

  if (!szName)
    return NVAPI_INVALID_ARGUMENT;

  CopyShortString(szName, adapter_str);

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_DISP_GetGDIPrimaryDisplayId(NvU32 *displayId) {
  if (!displayId)
    return NVAPI_INVALID_ARGUMENT;
  *displayId = WMTGetPrimaryDisplayId();
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_D3D_GetSleepStatus(IUnknown *pDev, NV_GET_SLEEP_STATUS_PARAMS *pGetSleepStatusParams) {
  if (!pDev || !pGetSleepStatusParams)
    return NVAPI_INVALID_ARGUMENT;

  switch (pGetSleepStatusParams->version) {
  case NV_GET_SLEEP_STATUS_PARAMS_VER1:
    pGetSleepStatusParams->bLowLatencyMode = false;
    pGetSleepStatusParams->bFsVrr = false;
    pGetSleepStatusParams->bCplVsyncOn = false;
    pGetSleepStatusParams->sleepIntervalUs = 0;
    pGetSleepStatusParams->bUseGameSleep = false;
    break;
  default:
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_D3D_SetSleepMode(IUnknown *pDev, NV_SET_SLEEP_MODE_PARAMS *pSetSleepModeParams) {
  if (!pDev || !pSetSleepModeParams)
    return NVAPI_INVALID_ARGUMENT;

  switch (pSetSleepModeParams->version) {
  case NV_SET_SLEEP_MODE_PARAMS_VER1:
    break;
  default:
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_D3D_SetLatencyMarker(IUnknown *pDev, NV_LATENCY_MARKER_PARAMS *pSetLatencyMarkerParams) {
  if (!pDev || !pSetLatencyMarkerParams)
    return NVAPI_INVALID_ARGUMENT;

  switch (pSetLatencyMarkerParams->version) {
  case NV_LATENCY_MARKER_PARAMS_VER1:
    break;
  default:
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_D3D_Sleep(IUnknown *pDev) {
  if (!pDev)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_D3D_GetLatency(IUnknown *pDev, NV_LATENCY_RESULT_PARAMS *pGetLatencyParams) {
  if (!pDev || !pGetLatencyParams)
    return NVAPI_INVALID_ARGUMENT;

  switch (pGetLatencyParams->version) {
  case NV_LATENCY_RESULT_PARAMS_VER1:
    memset(pGetLatencyParams->frameReport, 0, sizeof(pGetLatencyParams->frameReport));
    break;
  default:
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_D3D_SetVerticalSyncMode(IUnknown *pDev, NVAPI_VSYNC_MODE vsyncMode) {
  if (!pDev)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_NO_IMPLEMENTATION;
}

NVAPI_INTERFACE
NvAPI_GPU_GetPstates20(NvPhysicalGpuHandle hPhysicalGpu, NV_GPU_PERF_PSTATES20_INFO *pPstatesInfo) {
  if (!hPhysicalGpu || !pPstatesInfo)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_NO_IMPLEMENTATION;
}

NVAPI_INTERFACE
NvAPI_Mosaic_GetDisplayViewportsByResolution(NvU32 displayId, NvU32 srcWidth, NvU32 srcHeight, NV_RECT viewports[NV_MOSAIC_MAX_DISPLAYS], NvU8 *bezelCorrected) {
  return NVAPI_MOSAIC_NOT_ACTIVE;
}

NVAPI_INTERFACE
NvAPI_Stereo_IsEnabled(NvU8 *pIsStereoEnabled) {
  if (!pIsStereoEnabled)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_STEREO_NOT_INITIALIZED;
}

NVAPI_INTERFACE
NvAPI_Stereo_SetDriverMode(NV_STEREO_DRIVER_MODE mode) {
  return NVAPI_STEREO_NOT_INITIALIZED;
}

NVAPI_INTERFACE
NvAPI_DRS_CreateSession(NvDRSSessionHandle *phSession) {
  if (!phSession)
    return NVAPI_INVALID_ARGUMENT;

  return NVAPI_NOT_SUPPORTED;
}

NVAPI_INTERFACE
NvAPI_DRS_LoadSettings(NvDRSSessionHandle hSession) {
  return NVAPI_NOT_SUPPORTED;
}

LUID
GetAdapterLuid(WMT::Device device) {
  /**
  TODO: duplicated impl in `dxgi_adapter.cpp`
  */
  return std::bit_cast<LUID>(__builtin_bswap64(device.registryID()));
}

NVAPI_INTERFACE
NvAPI_GPU_GetAdapterIdFromPhysicalGpu(NvPhysicalGpuHandle hPhysicalGpu, void *pOSAdapterId) {
  if (!pOSAdapterId)
    return NVAPI_INVALID_ARGUMENT;

  auto registry_id = uint64_t(hPhysicalGpu);
  auto devices = WMT::CopyAllDevices();
  auto adapter_count = devices.count();
  if (adapter_count == 0)
    return NVAPI_INVALID_ARGUMENT;

  WMT::Device target_device{};
  for (unsigned i = 0; i < adapter_count; i++) {
    if (registry_id == devices.object(i).registryID()) {
      target_device = devices.object(i);
      break;
    }
  }
  if (!target_device)
    return NVAPI_INVALID_ARGUMENT;

  *reinterpret_cast<LUID *>(pOSAdapterId) = GetAdapterLuid(target_device);
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GPU_GetLogicalGpuInfo(NvLogicalGpuHandle hLogicalGpu, NV_LOGICAL_GPU_DATA *pLogicalGpuData) {
  if (!pLogicalGpuData)
    return NVAPI_INVALID_ARGUMENT;

  auto registry_id = uint64_t(hLogicalGpu);
  auto devices = WMT::CopyAllDevices();
  auto adapter_count = devices.count();
  if (adapter_count == 0)
    return NVAPI_NVIDIA_DEVICE_NOT_FOUND;

  WMT::Device target_device{};
  for (unsigned i = 0; i < adapter_count; i++) {
    if (registry_id == devices.object(i).registryID()) {
      target_device = devices.object(i);
      break;
    }
  }
  if (!target_device)
    return NVAPI_NVIDIA_DEVICE_NOT_FOUND;

  switch (pLogicalGpuData->version) {
  case NV_LOGICAL_GPU_DATA_VER1:
    pLogicalGpuData->physicalGpuCount = 1;
    memset(pLogicalGpuData->physicalGpuHandles, 0, sizeof(pLogicalGpuData->physicalGpuHandles));
    pLogicalGpuData->physicalGpuHandles[0] = (NvPhysicalGpuHandle)registry_id;
    *reinterpret_cast<LUID *>(pLogicalGpuData->pOSAdapterId) = GetAdapterLuid(target_device);
    break;
  default:
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  }

  return NVAPI_OK;
}

/*
 * Physical and logical GPU handles are both the Metal device's registry ID
 */
static WMT::Device
FindDevice(uint64_t registry_id) {
  auto devices = WMT::CopyAllDevices();
  for (unsigned i = 0; i < devices.count(); i++) {
    if (registry_id == devices.object(i).registryID())
      return devices.object(i);
  }
  return {};
}

NVAPI_INTERFACE
NvAPI_GetLogicalGPUFromPhysicalGPU(NvPhysicalGpuHandle hPhysicalGPU, NvLogicalGpuHandle *pLogicalGPU) {
  if (!pLogicalGPU)
    return NVAPI_INVALID_ARGUMENT;
  if (!FindDevice(uint64_t(hPhysicalGPU)))
    return NVAPI_EXPECTED_PHYSICAL_GPU_HANDLE;

  *pLogicalGPU = (NvLogicalGpuHandle)hPhysicalGPU;
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GetPhysicalGPUsFromLogicalGPU(
    NvLogicalGpuHandle hLogicalGPU, NvPhysicalGpuHandle hPhysicalGPU[NVAPI_MAX_PHYSICAL_GPUS], NvU32 *pGpuCount
) {
  if (!hPhysicalGPU || !pGpuCount)
    return NVAPI_INVALID_ARGUMENT;
  if (!FindDevice(uint64_t(hLogicalGPU)))
    return NVAPI_EXPECTED_LOGICAL_GPU_HANDLE;

  hPhysicalGPU[0] = (NvPhysicalGpuHandle)hLogicalGPU;
  *pGpuCount = 1;
  return NVAPI_OK;
}

/*
 * Display handles are HMONITORs, as NvAPI_EnumNvidiaDisplayHandle returns them
 */
NVAPI_INTERFACE
NvAPI_GetAssociatedNvidiaDisplayHandle(const char *szDisplayName, NvDisplayHandle *pNvDispHandle) {
  if (!szDisplayName || !pNvDispHandle)
    return NVAPI_INVALID_ARGUMENT;

  for (unsigned i = 0;; i++) {
    HMONITOR monitor = wsi::enumMonitors(i);
    if (!monitor)
      break;
    MONITORINFOEXA info = {};
    info.cbSize = sizeof(info);
    if (GetMonitorInfoA(monitor, &info) && !_stricmp(info.szDevice, szDisplayName)) {
      *pNvDispHandle = (NvDisplayHandle)monitor;
      return NVAPI_OK;
    }
  }

  /*
   * A name the monitor list does not know (e.g. the adapter's GDI name from
   * DXGI) is the primary display
   */
  HMONITOR primary = wsi::enumMonitors(0);
  if (!primary)
    return NVAPI_NVIDIA_DEVICE_NOT_FOUND;
  *pNvDispHandle = (NvDisplayHandle)primary;
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GetAssociatedDisplayOutputId(NvDisplayHandle hNvDisplay, NvU32 *pOutputId) {
  if (!hNvDisplay || !pOutputId)
    return NVAPI_INVALID_ARGUMENT;

  for (unsigned i = 0; i < 32; i++) {
    HMONITOR monitor = wsi::enumMonitors(i);
    if (!monitor)
      break;
    if ((NvDisplayHandle)monitor == hNvDisplay) {
      *pOutputId = 1u << i;
      return NVAPI_OK;
    }
  }
  return NVAPI_EXPECTED_DISPLAY_HANDLE;
}

NVAPI_INTERFACE
NvAPI_GPU_GetPCIIdentifiers(
    NvPhysicalGpuHandle hPhysicalGpu, NvU32 *pDeviceId, NvU32 *pSubSystemId, NvU32 *pRevisionId, NvU32 *pExtDeviceId
) {
  if (!pDeviceId || !pSubSystemId || !pRevisionId || !pExtDeviceId)
    return NVAPI_INVALID_ARGUMENT;
  if (!FindDevice(uint64_t(hPhysicalGpu)))
    return NVAPI_EXPECTED_PHYSICAL_GPU_HANDLE;

  // vendor 0x10DE in the low word, device id 0
  *pDeviceId = 0x10DE;
  *pSubSystemId = 0;
  *pRevisionId = 0;
  *pExtDeviceId = 0;
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GPU_GetThermalSettings(
    NvPhysicalGpuHandle hPhysicalGpu, NvU32 sensorIndex, NV_GPU_THERMAL_SETTINGS *pThermalSettings
) {
  if (!pThermalSettings)
    return NVAPI_INVALID_ARGUMENT;
  if (!FindDevice(uint64_t(hPhysicalGpu)))
    return NVAPI_EXPECTED_PHYSICAL_GPU_HANDLE;
  if (pThermalSettings->version != NV_GPU_THERMAL_SETTINGS_VER_1 &&
      pThermalSettings->version != NV_GPU_THERMAL_SETTINGS_VER_2)
    return NVAPI_INCOMPATIBLE_STRUCT_VERSION;
  if (sensorIndex != NVAPI_THERMAL_TARGET_ALL && sensorIndex != 0)
    return NVAPI_INVALID_ARGUMENT;

  /*
   * Metal reports no temperature; one GPU sensor at a steady reading
   */
  NvU32 version = pThermalSettings->version;
  memset(pThermalSettings, 0, sizeof(*pThermalSettings));
  pThermalSettings->version = version;
  pThermalSettings->count = 1;
  pThermalSettings->sensor[0].controller = NVAPI_THERMAL_CONTROLLER_GPU_INTERNAL;
  pThermalSettings->sensor[0].defaultMinTemp = 0;
  pThermalSettings->sensor[0].defaultMaxTemp = 95;
  pThermalSettings->sensor[0].currentTemp = 50;
  pThermalSettings->sensor[0].target = NVAPI_THERMAL_TARGET_GPU;
  return NVAPI_OK;
}

/*
 * Unified memory: both sizes are the Metal device's recommended working set
 * (in KB), the number DXGI reports as DedicatedVideoMemory
 */
NVAPI_INTERFACE
NvAPI_GPU_GetPhysicalFrameBufferSize(NvPhysicalGpuHandle hPhysicalGpu, NvU32 *pSize) {
  if (!hPhysicalGpu || !pSize)
    return NVAPI_INVALID_ARGUMENT;

  auto device = FindDevice(uint64_t(hPhysicalGpu));
  if (!device)
    return NVAPI_EXPECTED_PHYSICAL_GPU_HANDLE;

  *pSize = NvU32(device.recommendedMaxWorkingSetSize() / 1024);
  return NVAPI_OK;
}

NVAPI_INTERFACE
NvAPI_GPU_GetVirtualFrameBufferSize(NvPhysicalGpuHandle hPhysicalGpu, NvU32 *pSize) {
  return dxmt::NvAPI_GPU_GetPhysicalFrameBufferSize(hPhysicalGpu, pSize);
}


/* madeira-bcd: NVAPI trace (tools/patch-nvapi-trace.py). */
static const char *madeira_nv_name(NvU32 id) {
  for (auto &iface : nvapi_interface_table)
    if (iface.id == id)
      return iface.func;
  return "?";
}

/* The first calls of an entry point, and its later failures, are logged. */
static bool madeira_nv_should_log(std::atomic<unsigned> &calls, NvAPI_Status s) {
  unsigned k = calls.fetch_add(1, std::memory_order_relaxed);
  return k < 6 || (s != NVAPI_OK && k < 40);
}

template <auto Fn, NvU32 Id> struct madeira_nv_trace;
template <typename... A, NvAPI_Status (*Fn)(A...), NvU32 Id>
struct madeira_nv_trace<Fn, Id> {
  static NvAPI_Status __cdecl call(A... a) {
    static std::atomic<unsigned> calls{0};
    NvAPI_Status s = Fn(a...);
    if (madeira_nv_should_log(calls, s))
      Logger::info(str::format("[nvapi] ", madeira_nv_name(Id), " -> ", int(s)));
    return s;
  }
};

static std::string madeira_nv_str(const char *s, size_t cap) {
  if (!s)
    return "(null)";
  size_t n = 0;
  while (n < cap && s[n])
    n++;
  return std::string(s, n) + (n == cap ? "[no NUL]" : "");
}

/* The adapter name EnumDisplayDevices gives the primary display. */
static bool madeira_nv_is_primary_adapter_name(const char *name) {
  DISPLAY_DEVICEA dd = {};
  dd.cb = sizeof(dd);
  for (DWORD i = 0; name && EnumDisplayDevicesA(nullptr, i, &dd, 0); i++) {
    if ((dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) && !_stricmp(dd.DeviceName, name))
      return true;
    dd = {};
    dd.cb = sizeof(dd);
  }
  return false;
}

static NvAPI_Status __cdecl madeira_nv_DISP_GetDisplayIdByDisplayName(const char *displayName, NvU32 *displayId) {
  static std::atomic<unsigned> calls{0};
  NvAPI_Status s = dxmt::NvAPI_DISP_GetDisplayIdByDisplayName(displayName, displayId);
  bool fallback = false;
  /* One display on this port: its adapter's name is that display, whatever
   * GetMonitorInfo calls the monitor. */
  if (s == NVAPI_NVIDIA_DEVICE_NOT_FOUND && displayId && madeira_nv_is_primary_adapter_name(displayName)) {
    *displayId = WMTGetPrimaryDisplayId();
    s = NVAPI_OK;
    fallback = true;
  }
  if (madeira_nv_should_log(calls, s))
    Logger::info(str::format("[nvapi] NvAPI_DISP_GetDisplayIdByDisplayName(\"", madeira_nv_str(displayName, 64),
                             "\") -> ", int(s), s == NVAPI_OK && displayId ? str::format(" id=0x", std::hex, *displayId) : "",
                             fallback ? " (primary adapter name; GetMonitorInfo did not match)" : ""));
  return s;
}

static NvAPI_Status __cdecl madeira_nv_GetAssociatedNvidiaDisplayHandle(const char *szDisplayName, NvDisplayHandle *pNvDispHandle) {
  static std::atomic<unsigned> calls{0};
  NvAPI_Status s = dxmt::NvAPI_GetAssociatedNvidiaDisplayHandle(szDisplayName, pNvDispHandle);
  if (madeira_nv_should_log(calls, s))
    Logger::info(str::format("[nvapi] NvAPI_GetAssociatedNvidiaDisplayHandle(\"", madeira_nv_str(szDisplayName, 64),
                             "\") -> ", int(s), s == NVAPI_OK && pNvDispHandle ? str::format(" handle=", (void *)*pNvDispHandle) : ""));
  return s;
}

static NvAPI_Status __cdecl madeira_nv_SYS_GetDriverAndBranchVersion(NvU32 *pDriverVersion, NvAPI_ShortString szBuildBranchString) {
  static std::atomic<unsigned> calls{0};
  NvAPI_Status s = dxmt::NvAPI_SYS_GetDriverAndBranchVersion(pDriverVersion, szBuildBranchString);
  if (madeira_nv_should_log(calls, s))
    Logger::info(str::format("[nvapi] NvAPI_SYS_GetDriverAndBranchVersion -> ", int(s),
                             s == NVAPI_OK ? str::format(" version=", *pDriverVersion, " branch=\"",
                                                         madeira_nv_str(szBuildBranchString, NVAPI_SHORT_STRING_MAX), "\"") : ""));
  return s;
}

static NvAPI_Status __cdecl madeira_nv_GetDisplayDriverVersion(NvDisplayHandle hNvDisplay, NV_DISPLAY_DRIVER_VERSION *pVersion) {
  static std::atomic<unsigned> calls{0};
  NvAPI_Status s = dxmt::NvAPI_GetDisplayDriverVersion(hNvDisplay, pVersion);
  if (madeira_nv_should_log(calls, s))
    Logger::info(str::format("[nvapi] NvAPI_GetDisplayDriverVersion(", (void *)hNvDisplay, ") -> ", int(s),
                             s == NVAPI_OK ? str::format(" version=", pVersion->drvVersion, " branch=\"",
                                                         madeira_nv_str(pVersion->szBuildBranchString, NVAPI_SHORT_STRING_MAX),
                                                         "\" adapter=\"", madeira_nv_str(pVersion->szAdapterString, NVAPI_SHORT_STRING_MAX), "\"")
                                           : pVersion ? str::format(" (struct version 0x", std::hex, pVersion->version, ")") : ""));
  return s;
}

static NvAPI_Status __cdecl madeira_nv_EnumPhysicalGPUs(NvPhysicalGpuHandle nvGPUHandle[NVAPI_MAX_PHYSICAL_GPUS], NvU32 *pGpuCount) {
  static std::atomic<unsigned> calls{0};
  NvAPI_Status s = dxmt::NvAPI_EnumPhysicalGPUs(nvGPUHandle, pGpuCount);
  if (madeira_nv_should_log(calls, s))
    Logger::info(str::format("[nvapi] NvAPI_EnumPhysicalGPUs -> ", int(s),
                             s == NVAPI_OK ? str::format(" count=", *pGpuCount, " first=", (void *)nvGPUHandle[0]) : ""));
  return s;
}

static NvAPI_Status __cdecl madeira_nv_GPU_GetConnectedDisplayIds(NvPhysicalGpuHandle hPhysicalGpu, NV_GPU_DISPLAYIDS *pDisplayIds,
                                                                  NvU32 *pDisplayIdCount, NvU32 flags) {
  static std::atomic<unsigned> calls{0};
  NvAPI_Status s = dxmt::NvAPI_GPU_GetConnectedDisplayIds(hPhysicalGpu, pDisplayIds, pDisplayIdCount, flags);
  if (madeira_nv_should_log(calls, s))
    Logger::info(str::format("[nvapi] NvAPI_GPU_GetConnectedDisplayIds(", (void *)hPhysicalGpu, ", flags=0x", std::hex, flags,
                             ") -> ", std::dec, int(s), pDisplayIdCount ? str::format(" count=", *pDisplayIdCount) : "",
                             s == NVAPI_OK && pDisplayIds && pDisplayIdCount && *pDisplayIdCount
                                 ? str::format(" first=0x", std::hex, pDisplayIds[0].displayId) : ""));
  return s;
}

static NvAPI_Status __cdecl madeira_nv_DISP_GetGDIPrimaryDisplayId(NvU32 *displayId) {
  static std::atomic<unsigned> calls{0};
  NvAPI_Status s = dxmt::NvAPI_DISP_GetGDIPrimaryDisplayId(displayId);
  if (madeira_nv_should_log(calls, s))
    Logger::info(str::format("[nvapi] NvAPI_DISP_GetGDIPrimaryDisplayId -> ", int(s),
                             s == NVAPI_OK ? str::format(" id=0x", std::hex, *displayId) : ""));
  return s;
}

static NvAPI_Status __cdecl madeira_nv_GPU_GetAdapterIdFromPhysicalGpu(NvPhysicalGpuHandle hPhysicalGpu, void *pOSAdapterId) {
  static std::atomic<unsigned> calls{0};
  NvAPI_Status s = dxmt::NvAPI_GPU_GetAdapterIdFromPhysicalGpu(hPhysicalGpu, pOSAdapterId);
  if (madeira_nv_should_log(calls, s)) {
    LUID l = s == NVAPI_OK ? *reinterpret_cast<LUID *>(pOSAdapterId) : LUID{};
    Logger::info(str::format("[nvapi] NvAPI_GPU_GetAdapterIdFromPhysicalGpu(", (void *)hPhysicalGpu, ") -> ", int(s),
                             " luid=", std::hex, l.HighPart, ":", l.LowPart));
  }
  return s;
}

static NvAPI_Status __cdecl madeira_nv_GPU_GetFullName(NvPhysicalGpuHandle hPhysicalGpu, NvAPI_ShortString szName) {
  static std::atomic<unsigned> calls{0};
  NvAPI_Status s = dxmt::NvAPI_GPU_GetFullName(hPhysicalGpu, szName);
  if (madeira_nv_should_log(calls, s))
    Logger::info(str::format("[nvapi] NvAPI_GPU_GetFullName -> ", int(s),
                             s == NVAPI_OK ? str::format(" \"", madeira_nv_str(szName, NVAPI_SHORT_STRING_MAX), "\"") : ""));
  return s;
}

extern "C" __cdecl void *nvapi_QueryInterface(NvU32 id) {
  {
    static NvU32 seen[256];
    static unsigned nseen;
    bool known = false;
    for (unsigned i = 0; i < nseen; i++)
      if (seen[i] == id) { known = true; break; }
    if (!known && nseen < 256) {
      seen[nseen++] = id;
      const char *name = "?";
      for (auto &iface : nvapi_interface_table)
        if (iface.id == id) { name = iface.func; break; }
      char line[160];  /* madeira-bcd: NVAPI trace: the Logger reaches the session log */
      snprintf(line, sizeof(line), "[nvapi] query 0x%08x %s", (unsigned)id, name);
      Logger::info(line);
    }
  }
  switch (id) {
  case 0x0150e828:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_Initialize, 0x0150e828u>::call;
  case 0x33c7358c:
  case 0x593e8644:
  case 0xad298d3f:
  case 0xd7c61344:
  case 0xd44d3c4e:
  case 0x6d67533c:
  case 0xb7fbdbfa:
  case 0xc99f4a67:
    // unknown functions
    return nullptr;
  case 0x2926aaad:
    return (void *)&madeira_nv_SYS_GetDriverAndBranchVersion;
  case 0xf951a4d1:
    return (void *)&madeira_nv_GetDisplayDriverVersion;
  case 0x01053fa5:
    return (void *)&NvAPI_GetInterfaceVersionString;
  case 0x4b708b54:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_D3D_GetCurrentSLIState, 0x4b708b54u>::call;
  case 0xd22bdd7e:
    return (void *)&NvAPI_Unload;
  case 0x6c2d048c:
    return (void *)&NvAPI_GetErrorMessage;
  case 0x65b93ca8:
    return (void *)&NvAPI_D3D11_BeginUAVOverlap;
  case 0x2216a357:
    return (void *)&NvAPI_D3D11_EndUAVOverlap;
  case 0x7aaf7a04:
    return (void *)&NvAPI_D3D11_SetDepthBoundsTest;
  case 0x5f68da40:
    return (void *)&NvAPI_D3D11_IsNvShaderExtnOpCodeSupported;
  case 0x8e90bb9f:
    return (void *)&NvAPI_D3D11_SetNvShaderExtnSlot;
  case 0xae457190:
    return (void *)&madeira_nv_DISP_GetDisplayIdByDisplayName;
  case 0xfceac864:
    return (void *)&NvAPI_D3D_GetObjectHandleForResource;
  case 0x6c0ed98c:
    return (void *)&NvAPI_D3D_SetResourceHint;
  case 0xe5ac921f:
    return (void *)&madeira_nv_EnumPhysicalGPUs;
  case 0x48b3ea59:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_EnumLogicalGPUs, 0x48b3ea59u>::call;
  case 0x34ef9506:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GetPhysicalGPUsFromDisplay, 0x34ef9506u>::call;
  case 0x351da224:
    return (void *)&NvAPI_Disp_HdrColorControl;
  case 0x84f2a8df:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_Disp_GetHdrCapabilities, 0x84f2a8dfu>::call;
  case 0x3b05c7e1:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_DISP_GetMonitorCapabilities, 0x3b05c7e1u>::call;
  case 0x9abdd40d:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_EnumNvidiaDisplayHandle, 0x9abdd40du>::call;
  case 0x0078dba2:
    return (void *)&madeira_nv_GPU_GetConnectedDisplayIds;
  case 0x1e9d8a31:
    return (void *)&madeira_nv_DISP_GetGDIPrimaryDisplayId;
  case 0xd8265d24:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetArchInfo, 0xd8265d24u>::call;
  case 0xdcb616c3:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetAllClockFrequencies, 0xdcb616c3u>::call;
  case 0xc7026a87:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetGpuCoreCount, 0xc7026a87u>::call;
  case 0x1be0b8e5:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetBusId, 0x1be0b8e5u>::call;
  case 0x1bb18724:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetBusType, 0x1bb18724u>::call;
  case 0x07f9b368:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetMemoryInfo, 0x07f9b368u>::call;
  case 0xc0599498:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetMemoryInfoEx, 0xc0599498u>::call;
  case 0xceee8e9f:
    return (void *)&madeira_nv_GPU_GetFullName;
  case 0x6ff81213:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetPstates20, 0x6ff81213u>::call;
  case 0xaef96ca1:
    return (void *)&NvAPI_D3D_GetSleepStatus;
  case 0xac1ca9e0:
    return (void *)&NvAPI_D3D_SetSleepMode;
  case 0xd9984c05:
    return (void *)&NvAPI_D3D_SetLatencyMarker;
  case 0x852cd1d2:
    return (void *)&NvAPI_D3D_Sleep;
  case 0x1a587f9c:
    return (void *)&NvAPI_D3D_GetLatency;
  case 0x5526cfd1:
    return (void *)&NvAPI_D3D_SetVerticalSyncMode;
  case 0xdc6dc8d3:
    return (void *)&NvAPI_Mosaic_GetDisplayViewportsByResolution;
  case 0x348ff8e1:
    return (void *)&NvAPI_Stereo_IsEnabled;
  case 0x5e8f0bec:
    return (void *)&NvAPI_Stereo_SetDriverMode;
  case 0x0694d52e:
    return (void *)&NvAPI_DRS_CreateSession;
  case 0x375dbd6b:
    return (void *)&NvAPI_DRS_LoadSettings;
  case 0x0ff07fde:
    return (void *)&madeira_nv_GPU_GetAdapterIdFromPhysicalGpu;
  case 0x842b066e:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetLogicalGpuInfo, 0x842b066eu>::call;
  case 0xadd604d1:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GetLogicalGPUFromPhysicalGPU, 0xadd604d1u>::call;
  case 0xaea3fa32:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GetPhysicalGPUsFromLogicalGPU, 0xaea3fa32u>::call;
  case 0x35c29134:
    return (void *)&madeira_nv_GetAssociatedNvidiaDisplayHandle;
  case 0xd995937e:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GetAssociatedDisplayOutputId, 0xd995937eu>::call;
  case 0x2ddfb66e:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetPCIIdentifiers, 0x2ddfb66eu>::call;
  case 0xe3640a56:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetThermalSettings, 0xe3640a56u>::call;
  case 0x46fbeb03:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetPhysicalFrameBufferSize, 0x46fbeb03u>::call;
  case 0x5a04b644:
    return (void *)&madeira_nv_trace<&dxmt::NvAPI_GPU_GetVirtualFrameBufferSize, 0x5a04b644u>::call;
  default:
    break;
  }

  for (auto &iface : nvapi_interface_table) {
    if (iface.id == id) {
      ERR("nvapi: function ", iface.func, " not implemented");
      return nullptr;
    }
  }
  ERR("nvapi: function id ", id, " not implemented");
  return nullptr;
}

}; // namespace dxmt