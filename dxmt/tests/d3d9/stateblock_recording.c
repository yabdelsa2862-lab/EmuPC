/* Build with i686-w64-mingw32-gcc -std=c11 -Wall -Wextra -Werror
 * -mwindows stateblock_recording.c -ld3d9 -o stateblock_recording.exe.
 * Run with the target D3D9 implementation; results are written locally.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>

static FILE *report;
static unsigned checks, failures;

static void check(const char *name, DWORD actual, DWORD expected) {
  ++checks;
  if (actual != expected) {
    ++failures;
    fprintf(report, "FAIL %s: expected %lu, actual %lu\n", name,
            (unsigned long)expected, (unsigned long)actual);
  }
}

static DWORD tss(IDirect3DDevice9 *device, DWORD stage, D3DTEXTURESTAGESTATETYPE type) {
  DWORD value = 0;
  check("GetTextureStageState", IDirect3DDevice9_GetTextureStageState(device, stage, type, &value), D3D_OK);
  return value;
}

static DWORD sampler(IDirect3DDevice9 *device, DWORD stage, D3DSAMPLERSTATETYPE type) {
  DWORD value = 0;
  check("GetSamplerState", IDirect3DDevice9_GetSamplerState(device, stage, type, &value), D3D_OK);
  return value;
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR command, int show) {
  (void)previous; (void)command; (void)show;
  report = fopen("stateblock-conformance.txt", "w");
  if (!report) return 1;
  HWND window = CreateWindowA("STATIC", "State block recording conformance", WS_POPUP,
                              0, 0, 1280, 800, NULL, NULL, instance, NULL);
  IDirect3D9 *api = Direct3DCreate9(D3D_SDK_VERSION);
  if (!api) { fclose(report); return 2; }
  D3DPRESENT_PARAMETERS parameters = {0};
  parameters.Windowed = TRUE;
  parameters.SwapEffect = D3DSWAPEFFECT_DISCARD;
  parameters.hDeviceWindow = window;
  parameters.BackBufferWidth = 1280;
  parameters.BackBufferHeight = 800;
  parameters.BackBufferFormat = D3DFMT_X8R8G8B8;
  IDirect3DDevice9 *device = NULL;
  HRESULT result = IDirect3D9_CreateDevice(api, 0, D3DDEVTYPE_HAL, window,
      D3DCREATE_SOFTWARE_VERTEXPROCESSING, &parameters, &device);
  check("CreateDevice", result, D3D_OK);
  if (FAILED(result)) { fclose(report); IDirect3D9_Release(api); return 3; }

  IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_ALPHAOP, D3DTOP_SELECTARG1);
  IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLORARG2, D3DTA_TFACTOR);
  IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MAGFILTER, D3DTEXF_LINEAR);
  IDirect3DDevice9_SetSamplerState(device, 1, D3DSAMP_MINFILTER, D3DTEXF_LINEAR);
  IDirect3DStateBlock9 *block = NULL;
  check("BeginStateBlock", IDirect3DDevice9_BeginStateBlock(device), D3D_OK);
  IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
  IDirect3DDevice9_SetTextureStageState(device, 7, D3DTSS_CONSTANT, 0xff123456);
  IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MINFILTER, D3DTEXF_ANISOTROPIC);
  check("recording preserves live state", tss(device, 0, D3DTSS_ALPHAOP), D3DTOP_SELECTARG1);
  check("EndStateBlock", IDirect3DDevice9_EndStateBlock(device, &block), D3D_OK);
  if (!block) { fclose(report); IDirect3DDevice9_Release(device); IDirect3D9_Release(api); return 4; }

  IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLORARG2, D3DTA_DIFFUSE);
  IDirect3DDevice9_SetTextureStageState(device, 1, D3DTSS_ALPHAOP, D3DTOP_SELECTARG2);
  IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_CONSTANT, 0xffabcdef);
  IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
  IDirect3DDevice9_SetSamplerState(device, 1, D3DSAMP_MINFILTER, D3DTEXF_POINT);
  check("Apply", IDirect3DStateBlock9_Apply(block), D3D_OK);
  check("unrecorded TSS element", tss(device, 0, D3DTSS_COLORARG2), D3DTA_DIFFUSE);
  check("unrecorded texture stage", tss(device, 1, D3DTSS_ALPHAOP), D3DTOP_SELECTARG2);
  check("unrecorded CONSTANT stage", tss(device, 0, D3DTSS_CONSTANT), 0xffabcdef);
  check("unrecorded sampler element", sampler(device, 0, D3DSAMP_MAGFILTER), D3DTEXF_POINT);
  check("unrecorded sampler stage", sampler(device, 1, D3DSAMP_MINFILTER), D3DTEXF_POINT);
  check("recorded ALPHAOP", tss(device, 0, D3DTSS_ALPHAOP), D3DTOP_MODULATE);
  check("recorded bit 32", tss(device, 7, D3DTSS_CONSTANT), 0xff123456);
  check("recorded MINFILTER", sampler(device, 0, D3DSAMP_MINFILTER), D3DTEXF_ANISOTROPIC);

  IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_ALPHAOP, D3DTOP_SELECTARG2);
  IDirect3DDevice9_SetTextureStageState(device, 7, D3DTSS_CONSTANT, 0xff654321);
  IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MINFILTER, D3DTEXF_LINEAR);
  check("Capture", IDirect3DStateBlock9_Capture(block), D3D_OK);
  IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
  IDirect3DDevice9_SetTextureStageState(device, 7, D3DTSS_CONSTANT, 0);
  IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_COLORARG2, D3DTA_CURRENT);
  IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MAGFILTER, D3DTEXF_LINEAR);
  IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
  check("Apply captured", IDirect3DStateBlock9_Apply(block), D3D_OK);
  check("captured ALPHAOP", tss(device, 0, D3DTSS_ALPHAOP), D3DTOP_SELECTARG2);
  check("captured bit 32", tss(device, 7, D3DTSS_CONSTANT), 0xff654321);
  check("captured MINFILTER", sampler(device, 0, D3DSAMP_MINFILTER), D3DTEXF_LINEAR);
  check("Capture excludes other TSS", tss(device, 0, D3DTSS_COLORARG2), D3DTA_CURRENT);
  check("Capture excludes other sampler", sampler(device, 0, D3DSAMP_MAGFILTER), D3DTEXF_LINEAR);
  IDirect3DStateBlock9_Release(block);

  check("create PIXELSTATE", IDirect3DDevice9_CreateStateBlock(device, D3DSBT_PIXELSTATE, &block), D3D_OK);
  if (block) {
    IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
    IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_DMAPOFFSET, 19);
    check("apply PIXELSTATE", IDirect3DStateBlock9_Apply(block), D3D_OK);
    check("PIXELSTATE restores ALPHAOP", tss(device, 0, D3DTSS_ALPHAOP), D3DTOP_SELECTARG2);
    check("PIXELSTATE excludes DMAPOFFSET", sampler(device, 0, D3DSAMP_DMAPOFFSET), 19);
    IDirect3DStateBlock9_Release(block);
  }
  check("create VERTEXSTATE", IDirect3DDevice9_CreateStateBlock(device, D3DSBT_VERTEXSTATE, &block), D3D_OK);
  if (block) {
    IDirect3DDevice9_SetTextureStageState(device, 0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
    IDirect3DDevice9_SetSamplerState(device, 0, D3DSAMP_DMAPOFFSET, 23);
    check("apply VERTEXSTATE", IDirect3DStateBlock9_Apply(block), D3D_OK);
    check("VERTEXSTATE excludes ALPHAOP", tss(device, 0, D3DTSS_ALPHAOP), D3DTOP_MODULATE);
    check("VERTEXSTATE restores DMAPOFFSET", sampler(device, 0, D3DSAMP_DMAPOFFSET), 19);
    IDirect3DStateBlock9_Release(block);
  }
  fprintf(report, "checks=%u failures=%u\n", checks, failures);
  fclose(report);
  IDirect3DDevice9_Release(device);
  IDirect3D9_Release(api);
  DestroyWindow(window);
  return failures ? 5 : 0;
}
