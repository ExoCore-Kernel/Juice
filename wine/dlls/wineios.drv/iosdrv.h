#ifndef __WINE_IOSDRV_H
#define __WINE_IOSDRV_H
#include "windef.h"
#include "winbase.h"
#include "ntgdi.h"
#include "ntuser.h"
#include "wine/gdi_driver.h"
#include "wine/debug.h"
#include "wine/vulkan_driver.h"
/* Optional Juice host ABI. Pixels are temporary, top-down BGRA8. */
extern void wineios_host_desktop_changed(unsigned int,unsigned int,unsigned int) __attribute__((weak_import));
extern void wineios_host_window_changed(UINT_PTR,const RECT *,BOOL) __attribute__((weak_import));
extern void wineios_host_window_destroyed(UINT_PTR) __attribute__((weak_import));
extern void wineios_host_present_bgra(UINT_PTR,const void *,unsigned int,unsigned int,unsigned int,const RECT *) __attribute__((weak_import));
BOOL iosdrv_present_now(HWND hwnd);
struct client_surface *iosdrv_CreateClientSurface(HWND hwnd,int pixel_format);
UINT iosdrv_VulkanInit(UINT version,void *vulkan_handle,const struct vulkan_driver_funcs **driver);
#endif
