/* Juice cross-process display transport. LGPL-2.1-or-later. */
#if 0
#pragma makedep unix
#endif
#include "config.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "ipc.h"
#include "wine/server.h"
WINE_DEFAULT_DEBUG_CHANNEL(iosdrv);
static int ipc_fd=-1; static pthread_mutex_t ipc_lock=PTHREAD_MUTEX_INITIALIZER;
static __thread BOOL queue_registered;
static HWND input_target;
static BOOL pointer_down;
static BOOL write_all(int fd,const void *data,size_t size){const char *p=data;while(size){ssize_t n=write(fd,p,size);if(n<0&&errno==EINTR)continue;if(n<=0)return FALSE;p+=n;size-=n;}return TRUE;}
static BOOL read_all(int fd,void *data,size_t size){char *p=data;while(size){ssize_t n=read(fd,p,size);if(n<0&&errno==EINTR)continue;if(n<=0)return FALSE;p+=n;size-=n;}return TRUE;}
static void send_msg(UINT type,HWND hwnd,const RECT *rect,const void *payload,UINT size,UINT stride,UINT flags)
{
 struct juice_ios_msg msg={JUICE_IOS_MAGIC,type,size,(UINT64)(UINT_PTR)hwnd};
 if(rect){msg.x=rect->left;msg.y=rect->top;msg.width=rect->right-rect->left;msg.height=rect->bottom-rect->top;} msg.stride=stride;msg.flags=flags;
 pthread_mutex_lock(&ipc_lock);if(ipc_fd>=0&&(!write_all(ipc_fd,&msg,sizeof(msg))||(size&&!write_all(ipc_fd,payload,size)))){close(ipc_fd);ipc_fd=-1;}pthread_mutex_unlock(&ipc_lock);
}
BOOL ios_ipc_process_input(void)
{
 for(;;)
 {
  struct juice_ios_msg msg;
  INPUT input={0};
  void *payload=NULL;
  HWND hwnd,target;
  RECT window;
  UINT sent=0,units=0,i;
  LRESULT text_length=0;
  BOOL redrawn=FALSE,presented=FALSE;
  ssize_t available;

  if(ipc_fd<0) break;
  available=recv(ipc_fd,&msg,sizeof(msg),MSG_PEEK|MSG_DONTWAIT);
  if(available<(ssize_t)sizeof(msg)) break;
  if(!read_all(ipc_fd,&msg,sizeof(msg)))
  {
   close(ipc_fd);
   ipc_fd=-1;
   break;
  }
  if(msg.size>64u*1024u)
  {
   fprintf(stderr,"[JuiceInput] rejected oversized message type=%u size=%u\n",msg.type,msg.size);
   close(ipc_fd);
   ipc_fd=-1;
   break;
  }
  if(msg.size)
  {
   payload=malloc(msg.size);
   if(!payload||!read_all(ipc_fd,payload,msg.size))
   {
    free(payload);
    close(ipc_fd);
    ipc_fd=-1;
    break;
   }
  }
  if(msg.magic!=JUICE_IOS_MAGIC)
  {
   fprintf(stderr,"[JuiceInput] ignored invalid magic=%08x type=%u size=%u\n",msg.magic,msg.type,msg.size);
   free(payload);
   continue;
  }

  hwnd=(HWND)(UINT_PTR)msg.hwnd;
  if(msg.type==JUICE_IOS_INPUT&&!msg.size)
  {
   BOOL desktop_coords=(msg.flags&JUICE_IOS_COORDS_DESKTOP)!=0;
   BOOL down=(msg.flags&(JUICE_IOS_LEFT_DOWN|JUICE_IOS_RIGHT_DOWN))!=0;
   BOOL up=(msg.flags&(JUICE_IOS_LEFT_UP|JUICE_IOS_RIGHT_UP))!=0;
   INT local_x=msg.x,local_y=msg.y;

   input.type=INPUT_MOUSE;
   if(desktop_coords)
   {
    /*
     * Keep the hardware pointer in screen space for the whole drag. The host
     * used to subtract an old window origin and this side then added a newer
     * one, which made moving windows oscillate behind the finger.
     */
    input.mi.dx=msg.x;
    input.mi.dy=msg.y;

    if(pointer_down&&input_target&&!down) target=input_target;
    else
    {
     if(NtUserGetWindowRect(hwnd,&window,NtUserGetDpiForWindow(hwnd)))
     {
      local_x-=window.left;
      local_y-=window.top;
     }
     target=NtUserChildWindowFromPointEx(hwnd,local_x,local_y,
                                         CWP_SKIPINVISIBLE|CWP_SKIPDISABLED|CWP_SKIPTRANSPARENT);
     if(!target||target==hwnd) target=NtUserWindowFromPoint(msg.x,msg.y);
     if(!target) target=hwnd;
    }
   }
   else
   {
    input.mi.dx=msg.x;
    input.mi.dy=msg.y;
    target=NtUserChildWindowFromPointEx(hwnd,msg.x,msg.y,
                                        CWP_SKIPINVISIBLE|CWP_SKIPDISABLED|CWP_SKIPTRANSPARENT);
    if(NtUserGetWindowRect(hwnd,&window,NtUserGetDpiForWindow(hwnd)))
    {
     input.mi.dx+=window.left;
     input.mi.dy+=window.top;
    }
    if(!target||target==hwnd) target=NtUserWindowFromPoint(input.mi.dx,input.mi.dy);
    if(!target) target=hwnd;
   }

   if(down)
   {
    NtUserSetForegroundWindow(hwnd);
    NtUserSetActiveWindow(hwnd);
    NtUserSetFocus(target);
    input_target=target;
    pointer_down=TRUE;
   }
   input.mi.dwFlags=MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_MOVE|MOUSEEVENTF_MOVE_NOCOALESCE;
   if(msg.flags&JUICE_IOS_LEFT_DOWN) input.mi.dwFlags|=MOUSEEVENTF_LEFTDOWN;
   if(msg.flags&JUICE_IOS_LEFT_UP) input.mi.dwFlags|=MOUSEEVENTF_LEFTUP;
   if(msg.flags&JUICE_IOS_RIGHT_DOWN) input.mi.dwFlags|=MOUSEEVENTF_RIGHTDOWN;
   if(msg.flags&JUICE_IOS_RIGHT_UP) input.mi.dwFlags|=MOUSEEVENTF_RIGHTUP;
   sent=NtUserSendHardwareInput(target,0,&input,0);
   if(up) pointer_down=FALSE;
   fprintf(stderr,"[JuiceInput] dispatched surface=%p target=%p coords=%s wire=%d,%d desktop=%d,%d flags=%x sent=%u\n",
           hwnd,target,desktop_coords?"desktop":"local",msg.x,msg.y,input.mi.dx,input.mi.dy,input.mi.dwFlags,sent);
  }
  else if(msg.type==JUICE_IOS_TEXT&&msg.size&&!(msg.size%sizeof(WCHAR)))
  {
   target=input_target?input_target:hwnd;
   NtUserSetForegroundWindow(hwnd);
   NtUserSetActiveWindow(hwnd);
   NtUserSetFocus(target);
   units=msg.size/sizeof(WCHAR);
   for(i=0;i<units;i++)
   {
    NtUserMessageCall(target,WM_CHAR,((WCHAR *)payload)[i],1,NULL,NtUserSendMessage,FALSE);
    sent++;
   }
   text_length=NtUserMessageCall(target,WM_GETTEXTLENGTH,0,0,NULL,NtUserSendMessage,FALSE);
   redrawn=NtUserRedrawWindow(target,NULL,0,RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN);
   redrawn|=NtUserRedrawWindow(hwnd,NULL,0,RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN);
   presented=iosdrv_present_now(hwnd);
   fprintf(stderr,"[JuiceInput] text surface=%p target=%p utf16_units=%u delivered=%u length=%ld redraw=%u present=%u\n",hwnd,target,units,sent,(long)text_length,redrawn,presented);
  }
  else if(msg.type==JUICE_IOS_KEY&&!msg.size&&(msg.flags&0xffffu))
  {
   target=input_target?input_target:hwnd;
   NtUserSetForegroundWindow(hwnd);
   NtUserSetActiveWindow(hwnd);
   NtUserSetFocus(target);
   NtUserMessageCall(target,WM_CHAR,msg.flags&0xffffu,1,NULL,NtUserSendMessage,FALSE);
   sent=1;
   text_length=NtUserMessageCall(target,WM_GETTEXTLENGTH,0,0,NULL,NtUserSendMessage,FALSE);
   redrawn=NtUserRedrawWindow(target,NULL,0,RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN);
   redrawn|=NtUserRedrawWindow(hwnd,NULL,0,RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN);
   presented=iosdrv_present_now(hwnd);
   fprintf(stderr,"[JuiceInput] key surface=%p target=%p vk=%x delivered=%u length=%ld redraw=%u present=%u\n",hwnd,target,msg.flags&0xffffu,sent,(long)text_length,redrawn,presented);
  }
  else if(msg.type==JUICE_IOS_HARDWARE_KEY&&!msg.size&&msg.y>0&&msg.y<=0xff&&
          (msg.flags&(JUICE_IOS_KEY_DOWN|JUICE_IOS_KEY_UP)))
  {
   target=input_target?input_target:hwnd;
   if(msg.flags&JUICE_IOS_KEY_DOWN)
   {
    NtUserSetForegroundWindow(hwnd);
    NtUserSetActiveWindow(hwnd);
    NtUserSetFocus(target);
   }
   input.type=INPUT_KEYBOARD;
   input.ki.wVk=msg.x;
   input.ki.wScan=msg.y;
   input.ki.dwFlags=KEYEVENTF_SCANCODE;
   if(msg.flags&JUICE_IOS_KEY_EXTENDED) input.ki.dwFlags|=KEYEVENTF_EXTENDEDKEY;
   if(msg.flags&JUICE_IOS_KEY_UP) input.ki.dwFlags|=KEYEVENTF_KEYUP;
   sent=NtUserSendHardwareInput(target,0,&input,0);
   fprintf(stderr,"[JuiceInput] hardware-key surface=%p target=%p vk=%x scan=%x down=%u extended=%u repeat=%u sent=%u\n",
           hwnd,target,msg.x,msg.y,!!(msg.flags&JUICE_IOS_KEY_DOWN),
           !!(msg.flags&JUICE_IOS_KEY_EXTENDED),!!(msg.flags&JUICE_IOS_KEY_REPEAT),sent);
  }
  else
  {
   fprintf(stderr,"[JuiceInput] ignored invalid message type=%u size=%u flags=%x\n",
           msg.type,msg.size,msg.flags);
  }
  free(payload);
 }
 return TRUE;
}
void ios_ipc_register_queue(void)
{
 HANDLE handle;
 int ret;

 if(queue_registered||ipc_fd<0) return;
 if(wine_server_fd_to_handle(ipc_fd,GENERIC_READ|SYNCHRONIZE,0,&handle))
 {
  fprintf(stderr,"[JuiceInput] failed to allocate queue fd handle tid=%p\n",NtCurrentTeb()->ClientId.UniqueThread);
  return;
 }
 SERVER_START_REQ(set_queue_fd)
 {
  req->handle=wine_server_obj_handle(handle);
  ret=wine_server_call(req);
 }
 SERVER_END_REQ;
 NtClose(handle);
 if(ret) fprintf(stderr,"[JuiceInput] failed to register queue fd status=%x tid=%p\n",ret,NtCurrentTeb()->ClientId.UniqueThread);
 else
 {
  queue_registered=TRUE;
  fprintf(stderr,"[JuiceInput] queue fd registered fd=%d tid=%p\n",ipc_fd,NtCurrentTeb()->ClientId.UniqueThread);
 }
}
void ios_ipc_init(unsigned int width,unsigned int height,unsigned int dpi)
{
 const char *path=getenv("JUICE_IOS_SOCKET");
 struct sockaddr_un addr;
 struct juice_ios_msg hello={JUICE_IOS_MAGIC,JUICE_IOS_HELLO,0,0,0,0,(INT)width,(INT)height,dpi,(UINT)getpid()};

 if(!path||!*path)
 {
  fprintf(stderr,"[JuiceInput] display socket disabled: JUICE_IOS_SOCKET is unset\n");
  return;
 }
 memset(&addr,0,sizeof(addr));
 addr.sun_family=AF_UNIX;
 if(strlen(path)>=sizeof(addr.sun_path)) return;
 strcpy(addr.sun_path,path);
 ipc_fd=socket(AF_UNIX,SOCK_STREAM,0);
 if(ipc_fd<0||connect(ipc_fd,(struct sockaddr *)&addr,sizeof(addr))<0)
 {
  fprintf(stderr,"[JuiceInput] display socket connect failed path=%s errno=%d\n",path,errno);
  if(ipc_fd>=0) close(ipc_fd);
  ipc_fd=-1;
  return;
 }
 if(!write_all(ipc_fd,&hello,sizeof(hello)))
 {
  fprintf(stderr,"[JuiceInput] display hello failed path=%s errno=%d\n",path,errno);
  close(ipc_fd);
  ipc_fd=-1;
  return;
 }
 fprintf(stderr,"[JuiceInput] display connected path=%s desktop=%ux%u dpi=%u\n",path,width,height,dpi);
 ios_ipc_register_queue();
}
void ios_ipc_window(HWND hwnd,const RECT *rect,BOOL visible){send_msg(JUICE_IOS_WINDOW,hwnd,rect,NULL,0,0,visible);}
void ios_ipc_destroy(HWND hwnd){send_msg(JUICE_IOS_DESTROY,hwnd,NULL,NULL,0,0,0);}
void ios_ipc_present(HWND hwnd,const void *bits,unsigned int width,unsigned int height,unsigned int stride,const RECT *dirty)
{
 struct juice_ios_msg msg={JUICE_IOS_MAGIC,JUICE_IOS_FRAME,stride*height,(UINT64)(UINT_PTR)hwnd,
                           dirty->left,dirty->top,width,height,stride,0};
 pthread_mutex_lock(&ipc_lock);
 if(ipc_fd>=0&&(!write_all(ipc_fd,&msg,sizeof(msg))||!write_all(ipc_fd,bits,msg.size)))
 {close(ipc_fd);ipc_fd=-1;}
 pthread_mutex_unlock(&ipc_lock);
}
