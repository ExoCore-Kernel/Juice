/* UIKit/software framebuffer driver for Wine on iOS. LGPL-2.1-or-later. */
#if 0
#pragma makedep unix
#endif
#include "config.h"
#include <pthread.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include "iosdrv.h"
#include <unistd.h>
#include "ipc.h"
#include "wine/unixlib.h"
#include "ntstatus.h"
WINE_DEFAULT_DEBUG_CHANNEL(iosdrv);

static unsigned int screen_width=1024,screen_height=768,screen_dpi=96;
static RECT virtual_screen={0,0,1024,768},work_area={0,0,1024,768};
static pthread_once_t metrics_once=PTHREAD_ONCE_INIT;
static void (*host_desktop_changed)(unsigned int,unsigned int,unsigned int);
static void (*host_window_changed)(UINT_PTR,const RECT *,BOOL);
static void (*host_window_destroyed)(UINT_PTR);
static void (*host_present_bgra)(UINT_PTR,const void *,unsigned int,unsigned int,unsigned int,const RECT *);
typedef struct { struct gdi_physdev dev; } IOSDRV_PDEVICE;
struct iosdrv_surface { struct window_surface header; void *bits; unsigned int width,height,stride; };
static pthread_mutex_t surface_lock=PTHREAD_MUTEX_INITIALIZER;
static struct iosdrv_surface *active_surface;
static struct user_driver_funcs iosdrv_funcs;

static void init_metrics_once(void)
{
    if (host_desktop_changed) host_desktop_changed(screen_width,screen_height,screen_dpi); ios_ipc_init(screen_width,screen_height,screen_dpi);
    TRACE("desktop %ux%u at %u dpi\n",screen_width,screen_height,screen_dpi);
}
static void init_metrics(void){pthread_once(&metrics_once,init_metrics_once);}
static IOSDRV_PDEVICE *create_physdev(void){init_metrics();return calloc(1,sizeof(IOSDRV_PDEVICE));}
static BOOL ios_CreateDC(PHYSDEV *pdev,LPCWSTR device,LPCWSTR output,const DEVMODEW *mode)
{ IOSDRV_PDEVICE *dev=create_physdev(); if(!dev)return FALSE; push_dc_driver(pdev,&dev->dev,&iosdrv_funcs.dc_funcs); return TRUE; }
static BOOL ios_CreateCompatibleDC(PHYSDEV orig,PHYSDEV *pdev)
{ IOSDRV_PDEVICE *dev=create_physdev(); if(!dev)return FALSE; push_dc_driver(pdev,&dev->dev,&iosdrv_funcs.dc_funcs); return TRUE; }
static BOOL ios_DeleteDC(PHYSDEV dev){free(dev);return TRUE;}
static INT ios_GetDeviceCaps(PHYSDEV dev,INT cap)
{
    init_metrics();
    switch(cap){
    case HORZRES: case DESKTOPHORZRES:return screen_width;
    case VERTRES: case DESKTOPVERTRES:return screen_height;
    case LOGPIXELSX: case LOGPIXELSY:return screen_dpi;
    case BITSPIXEL:return 32; case PLANES:return 1;
    case HORZSIZE:return (screen_width*254)/(screen_dpi*10);
    case VERTSIZE:return (screen_height*254)/(screen_dpi*10);
    default:dev=GET_NEXT_PHYSDEV(dev,pGetDeviceCaps);return dev->funcs->pGetDeviceCaps(dev,cap);}
}
static LONG ios_ChangeDisplaySettings(LPDEVMODEW modes,LPCWSTR primary,HWND hwnd,DWORD flags,void *param)
{ FIXME("display modes are controlled by iOS\n"); return DISP_CHANGE_SUCCESSFUL; }
static UINT ios_UpdateDisplayDevices(const struct gdi_device_manager *manager,void *param)
{
    const DWORD flags=DISPLAY_DEVICE_ATTACHED_TO_DESKTOP|DISPLAY_DEVICE_PRIMARY_DEVICE|DISPLAY_DEVICE_VGA_COMPATIBLE;
    struct pci_id pci={0}; struct gdi_monitor monitor={0}; DEVMODEW mode={0}; init_metrics();
    monitor.rc_monitor=virtual_screen;monitor.rc_work=work_area;mode.dmSize=sizeof(mode);
    mode.dmFields=DM_POSITION|DM_PELSWIDTH|DM_PELSHEIGHT|DM_BITSPERPEL|DM_DISPLAYFREQUENCY|DM_DISPLAYORIENTATION;
    mode.dmPelsWidth=screen_width;mode.dmPelsHeight=screen_height;mode.dmBitsPerPel=32;mode.dmDisplayFrequency=60;
    manager->add_gpu("Apple GPU",&pci,NULL,param);manager->add_source("iOS Display",flags,screen_dpi,param);
    manager->add_monitor(&monitor,param);manager->add_modes(&mode,1,&mode,param);return STATUS_SUCCESS;
}
static BOOL ios_CreateDesktop(const WCHAR *name,UINT width,UINT height){init_metrics();return TRUE;}
static void ios_SetDesktopWindow(HWND hwnd){}
static BOOL ios_CreateWindow(HWND hwnd){init_metrics();ios_ipc_register_queue();TRACE("create %p\n",hwnd);return TRUE;}
static void ios_DestroyWindow(HWND hwnd){if(host_window_destroyed)host_window_destroyed(HandleToUlong(hwnd));ios_ipc_destroy(hwnd);}
static UINT ios_ShowWindow(HWND hwnd,INT cmd,RECT *rect,UINT swp)
{
    fprintf(stderr,"[JuiceGeom] show hwnd=%p cmd=%d rect=%p %d,%d,%d,%d swp=%x\n",hwnd,cmd,rect,rect?rect->left:0,rect?rect->top:0,rect?rect->right:0,rect?rect->bottom:0,swp);
    if(host_window_changed)host_window_changed(HandleToUlong(hwnd),rect,cmd!=SW_HIDE);
    ios_ipc_window(hwnd,rect,cmd!=SW_HIDE); return swp;
}
static BOOL ios_WindowPosChanging(HWND hwnd,UINT flags,BOOL shaped,const struct window_rects *rects){return TRUE;}
static void ios_WindowPosChanged(HWND hwnd,HWND after,HWND owner,UINT flags,const struct window_rects *rects,struct window_surface *surface)
{
    fprintf(stderr,"[JuiceGeom] changed hwnd=%p flags=%x ptr=%p window=%d,%d,%d,%d client=%d,%d,%d,%d visible=%d,%d,%d,%d surface=%p\n",hwnd,flags,rects,rects->window.left,rects->window.top,rects->window.right,rects->window.bottom,rects->client.left,rects->client.top,rects->client.right,rects->client.bottom,rects->visible.left,rects->visible.top,rects->visible.right,rects->visible.bottom,surface);
    if(host_window_changed)host_window_changed(HandleToUlong(hwnd),&rects->window,!(flags&SWP_HIDEWINDOW));
    ios_ipc_window(hwnd,&rects->window,!(flags&SWP_HIDEWINDOW));
}
static void ios_SetParent(HWND hwnd,HWND parent,HWND old_parent){}
static void ios_SetCapture(HWND hwnd,UINT flags,HWND previous){}
static BOOL ios_ProcessEvents(DWORD mask){return ios_ipc_process_input();}
static LRESULT ios_DesktopWindowProc(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp)
{return NtUserMessageCall(hwnd,msg,wp,lp,NULL,NtUserDefWindowProc,FALSE);}
static LRESULT ios_WindowMessage(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp){return 0;}

BOOL iosdrv_present_now(HWND hwnd)
{
    struct iosdrv_surface *surface;
    RECT dirty;
    BOOL presented=FALSE;
    pthread_mutex_lock(&surface_lock);
    surface=active_surface;
    if(surface&&surface->header.hwnd==hwnd)
    {
        SetRect(&dirty,0,0,surface->width,surface->height);
        if(host_present_bgra)host_present_bgra(HandleToUlong(hwnd),surface->bits,surface->width,surface->height,surface->stride,&dirty);
        ios_ipc_present(hwnd,surface->bits,surface->width,surface->height,surface->stride,&dirty);
        presented=TRUE;
    }
    pthread_mutex_unlock(&surface_lock);
    return presented;
}
static void surface_set_clip(struct window_surface *surface,const RECT *rects,UINT count){}
static BOOL surface_flush(struct window_surface *header,const RECT *rect,const RECT *dirty,const BITMAPINFO *color_info,const void *color_bits,BOOL shape_changed,const BITMAPINFO *shape_info,const void *shape_bits)
{
    struct iosdrv_surface *surface=(struct iosdrv_surface *)header;
    if(host_present_bgra)host_present_bgra(HandleToUlong(header->hwnd),surface->bits,surface->width,surface->height,surface->stride,dirty);
    ios_ipc_present(header->hwnd,surface->bits,surface->width,surface->height,surface->stride,dirty);
    return TRUE;
}
static void surface_destroy(struct window_surface *header)
{
    struct iosdrv_surface *surface=(struct iosdrv_surface *)header;
    pthread_mutex_lock(&surface_lock);
    if(active_surface==surface)active_surface=NULL;
    pthread_mutex_unlock(&surface_lock);
    free(surface->bits);
}
static const struct window_surface_funcs surface_funcs={surface_set_clip,surface_flush,surface_destroy};
static BOOL ios_CreateWindowSurface(HWND hwnd,BOOL layered,const RECT *rect,struct window_surface **out)
{
    struct iosdrv_surface *surface; struct window_surface *header,*previous=*out;
    D3DKMT_CREATEDCFROMMEMORY desc={.Format=D3DDDIFMT_A8R8G8B8}; BITMAPINFO info; HBITMAP bitmap=0;
    unsigned int width=max(1,rect->right-rect->left),height=max(1,rect->bottom-rect->top),stride=width*4; void *bits;
    ios_ipc_register_queue();
    fprintf(stderr,"[JuiceGeom] surface hwnd=%p rect=%d,%d,%d,%d size=%ux%u previous=%p\n",hwnd,rect->left,rect->top,rect->right,rect->bottom,width,height,previous);
    if(previous&&previous->funcs==&surface_funcs)return TRUE; if(!(bits=calloc(height,stride)))return FALSE;
    memset(&info,0,sizeof(info));info.bmiHeader.biSize=sizeof(info.bmiHeader);info.bmiHeader.biWidth=width;
    info.bmiHeader.biHeight=-(LONG)height;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;
    info.bmiHeader.biCompression=BI_RGB;info.bmiHeader.biSizeImage=stride*height;
    desc.Width=width;desc.Height=height;desc.Pitch=stride;desc.pMemory=bits;desc.hDeviceDc=NtUserGetDCEx(hwnd,0,DCX_CACHE|DCX_WINDOW);
    if(!NtGdiDdDDICreateDCFromMemory(&desc)){bitmap=desc.hBitmap;NtGdiDeleteObjectApp(desc.hDc);}
    else ERR("failed to wrap iOS framebuffer in GDI bitmap\n");
    if(desc.hDeviceDc)NtUserReleaseDC(hwnd,desc.hDeviceDc);
    header=window_surface_create(sizeof(*surface),&surface_funcs,hwnd,rect,&info,bitmap);
    if(!header){if(bitmap)NtGdiDeleteObjectApp(bitmap);free(bits);return FALSE;}
    surface=(struct iosdrv_surface *)header;surface->bits=bits;surface->width=width;surface->height=height;surface->stride=stride;
    pthread_mutex_lock(&surface_lock);active_surface=surface;pthread_mutex_unlock(&surface_lock);
    if(previous)window_surface_release(previous);*out=header;return TRUE;
}
static UINT ios_OpenGLInit(UINT version,const struct opengl_funcs *funcs,const struct opengl_driver_funcs **driver)
{FIXME("OpenGL unavailable; Metal translation backend required\n");return STATUS_NOT_SUPPORTED;}
static UINT ios_VulkanInit(UINT version,void *handle,const struct vulkan_driver_funcs **driver)
{FIXME("Vulkan unavailable until a MoltenVK bridge is provided\n");return STATUS_NOT_SUPPORTED;}
static struct user_driver_funcs iosdrv_funcs={
    .dc_funcs.pCreateCompatibleDC=ios_CreateCompatibleDC,.dc_funcs.pCreateDC=ios_CreateDC,
    .dc_funcs.pDeleteDC=ios_DeleteDC,.dc_funcs.pGetDeviceCaps=ios_GetDeviceCaps,.dc_funcs.priority=GDI_PRIORITY_GRAPHICS_DRV,
    .pChangeDisplaySettings=ios_ChangeDisplaySettings,.pUpdateDisplayDevices=ios_UpdateDisplayDevices,
    .pCreateDesktop=ios_CreateDesktop,.pCreateWindow=ios_CreateWindow,.pSetDesktopWindow=ios_SetDesktopWindow,
    .pDesktopWindowProc=ios_DesktopWindowProc,.pDestroyWindow=ios_DestroyWindow,.pProcessEvents=ios_ProcessEvents,
    .pSetCapture=ios_SetCapture,.pSetParent=ios_SetParent,.pShowWindow=ios_ShowWindow,.pWindowMessage=ios_WindowMessage,
    .pWindowPosChanging=ios_WindowPosChanging,.pCreateWindowSurface=ios_CreateWindowSurface,
    .pWindowPosChanged=ios_WindowPosChanged,.pOpenGLInit=ios_OpenGLInit,.pVulkanInit=ios_VulkanInit};
NTSTATUS __wine_unix_lib_init(void)
{host_desktop_changed=dlsym(RTLD_DEFAULT,"wineios_host_desktop_changed");host_window_changed=dlsym(RTLD_DEFAULT,"wineios_host_window_changed");host_window_destroyed=dlsym(RTLD_DEFAULT,"wineios_host_window_destroyed");host_present_bgra=dlsym(RTLD_DEFAULT,"wineios_host_present_bgra");
init_metrics();iosdrv_funcs.pCreateWindow=ios_CreateWindow;iosdrv_funcs.pCreateDesktop=ios_CreateDesktop;iosdrv_funcs.pCreateWindowSurface=ios_CreateWindowSurface;fprintf(stderr,"[JuiceDriver] ios init set driver create=%p size=%zu\n",iosdrv_funcs.pCreateWindow,sizeof(iosdrv_funcs));__wine_set_user_driver(&iosdrv_funcs,WINE_GDI_DRIVER_VERSION);TRACE("Wine iOS driver initialized\n");return STATUS_SUCCESS;
}
