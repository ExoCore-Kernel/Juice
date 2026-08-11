#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "JuiceZip.h"
#import "../wine/dlls/wineios.drv/control_protocol.h"
#import <spawn.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <unistd.h>

#define JUICE_MAGIC 0x4a554943u
#define MSG_HELLO 1u
#define MSG_DESKTOP 2u
#define MSG_WINDOW 3u
#define MSG_DESTROY 4u
#define MSG_FRAME 5u
#define MSG_INPUT 100u
#define MSG_TEXT 101u
#define MSG_KEY 102u
#define INPUT_LEFT_DOWN 1u
#define INPUT_LEFT_UP 2u
#define INPUT_RIGHT_DOWN 4u
#define INPUT_RIGHT_UP 8u
typedef struct { uint32_t magic,type,size; uint64_t hwnd; int32_t x,y,width,height; uint32_t stride,flags; } JuiceMsg;

typedef NS_ENUM(uint16_t, JuicePEMachine) {
 JuicePEMachineUnknown=0,
 JuicePEMachineI386=0x014c,
 JuicePEMachineAMD64=0x8664,
 JuicePEMachineARM64=0xaa64,
 JuicePEMachineARM64EC=0xa641,
};

static BOOL ReadAll(int fd,void *p,size_t n){char *b=p;while(n){ssize_t r=read(fd,b,n);if(r<=0)return NO;b+=r;n-=r;}return YES;}
static BOOL WriteAll(int fd,const void *p,size_t n){const char *b=p;while(n){ssize_t r=write(fd,b,n);if(r<=0)return NO;b+=r;n-=r;}return YES;}
static char **CopyStrings(NSArray<NSString *> *a){char **v=calloc(a.count+1,sizeof(char *));for(NSUInteger i=0;i<a.count;i++)v[i]=strdup(a[i].UTF8String);return v;}
static void FreeStrings(char **v){if(!v)return;for(size_t i=0;v[i];i++)free(v[i]);free(v);}
static void CopyControlString(char *destination,size_t capacity,NSString *value){if(!capacity)return;destination[0]=0;if(value.length) [value getCString:destination maxLength:capacity encoding:NSUTF8StringEncoding];}

@interface WineCanvas : UIImageView
@property(nonatomic) uint64_t hwnd;
@property(nonatomic) BOOL rightClick;
@property(nonatomic,copy) void (^input)(JuiceMsg);
@end
@implementation WineCanvas
-(instancetype)init{if((self=[super init])){self.userInteractionEnabled=YES;self.contentMode=UIViewContentModeScaleAspectFit;self.backgroundColor=UIColor.blackColor;}return self;}
-(CGPoint)winePoint:(UITouch *)touch{CGPoint p=[touch locationInView:self];CGSize im=self.image.size;if(!im.width||!im.height)return p;CGFloat s=MIN(self.bounds.size.width/im.width,self.bounds.size.height/im.height);CGFloat ox=(self.bounds.size.width-im.width*s)/2,oy=(self.bounds.size.height-im.height*s)/2;return CGPointMake(MAX(0,MIN(im.width-1,(p.x-ox)/s)),MAX(0,MIN(im.height-1,(p.y-oy)/s)));}
-(void)send:(UITouch *)t flags:(uint32_t)flags{if(!self.input)return;if(flags&INPUT_LEFT_DOWN)flags=self.rightClick?INPUT_RIGHT_DOWN:INPUT_LEFT_DOWN;else if(flags&INPUT_LEFT_UP)flags=self.rightClick?INPUT_RIGHT_UP:INPUT_LEFT_UP;CGPoint p=[self winePoint:t];JuiceMsg m={JUICE_MAGIC,MSG_INPUT,0,self.hwnd,(int32_t)p.x,(int32_t)p.y,0,0,0,flags};self.input(m);}
-(void)touchesBegan:(NSSet *)t withEvent:(UIEvent *)e{[self send:t.anyObject flags:1];}
-(void)touchesMoved:(NSSet *)t withEvent:(UIEvent *)e{[self send:t.anyObject flags:0];}
-(void)touchesEnded:(NSSet *)t withEvent:(UIEvent *)e{[self send:t.anyObject flags:2];}
-(void)touchesCancelled:(NSSet *)t withEvent:(UIEvent *)e{[self send:t.anyObject flags:2];}
@end

@interface JuiceController : UIViewController <UITextFieldDelegate,UIDocumentPickerDelegate>
@property(nonatomic,strong) WineCanvas *canvas;
@property(nonatomic,strong) UITextView *log;
@property(nonatomic,strong) UITextField *exeField,*argsField,*debugField,*stdinField,*guiTextField;
@property(nonatomic,strong) UISegmentedControl *mode,*clickMode;
@property(nonatomic,strong) UISwitch *x64Switch,*winebootSwitch;
@property(nonatomic,strong) UIStackView *form;
@property(nonatomic,strong) UIButton *fullscreenButton;
@property(nonatomic,strong) NSLayoutConstraint *canvasHeightConstraint,*canvasBottomConstraint;
@property(nonatomic,copy) NSArray<NSLayoutConstraint *> *windowedConstraints;
@property(nonatomic) int listenFD,activeClient,controlListenFD,controlPickerFD;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *clients;
@property(nonatomic,copy) NSString *socketPath,*controlSocketPath,*grape,*prefix;
@property(nonatomic,strong) UIDocumentPickerViewController *controlPicker;
@property(nonatomic) uint32_t controlRequestID,controlFilters;
@property(nonatomic) pid_t child,server;
@property(nonatomic) int childInput;
@property(nonatomic) BOOL didAutoLaunch,reportedFrame,fullscreen,usingX64,serverUsingX64,desktopMode,prefixNeedsInitialization;
@property(nonatomic,copy) NSString *persistentLogPath;
@end
@implementation JuiceController
-(void)viewDidLoad
{
 [super viewDidLoad];
 self.view.backgroundColor=UIColor.systemBackgroundColor;
 self.clients=[NSMutableArray array];
 self.listenFD=self.activeClient=self.controlListenFD=self.controlPickerFD=-1;
 self.child=self.server=-1;
 self.childInput=-1;
 self.persistentLogPath=@"/var/mobile/Documents/Juice-GUI-Headless.log";
 [@"JUICE_HEADLESS_TEST_BEGIN\n" writeToFile:self.persistentLogPath atomically:YES
  encoding:NSUTF8StringEncoding error:nil];
 [NSFileManager.defaultManager createDirectoryAtPath:@"/var/mobile/Documents/JuiceData"
  withIntermediateDirectories:YES attributes:nil error:nil];
 [self buildUI];
 [self startDisplayServer];
 [self startControlServer];
 [self append:@"GUI_READY\n"];
}
-(void)viewDidAppear:(BOOL)animated
{
 [super viewDidAppear:animated];
 if(self.didAutoLaunch)return;
 self.didAutoLaunch=YES;
 NSString *base=@"/var/mobile/Documents/JuiceData";
 NSString *x64Flag=[base stringByAppendingPathComponent:@"RunX64Smoke"];
 NSString *arm64Flag=[base stringByAppendingPathComponent:@"RunARM64Smoke"];
 if([NSFileManager.defaultManager fileExistsAtPath:x64Flag])
 {
  [NSFileManager.defaultManager removeItemAtPath:x64Flag error:nil];
  self.x64Switch.on=YES;
  self.exeField.text=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Grape-X64/tests/x86_64-smoke.exe"];
  [self append:@"AUTO_LAUNCH_X86_64_SMOKE\n"];
 }
 else if([NSFileManager.defaultManager fileExistsAtPath:arm64Flag])
 {
  [NSFileManager.defaultManager removeItemAtPath:arm64Flag error:nil];
  self.exeField.text=@"winemine.exe";
  [self append:@"AUTO_LAUNCH_ARM64_SMOKE\n"];
 }
 else
 {
  self.desktopMode=YES;
  self.exeField.text=@"explorer.exe";
  self.argsField.text=@"/desktop=Juice,1024x768 JuiceGUI.exe";
  [self append:@"AUTO_LAUNCH_JUICE_DESKTOP\n"];
  if(!self.fullscreen)[self fullscreenTapped];
 }
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),
  dispatch_get_main_queue(),^{[self launchRequested];});
}
-(UITextField *)field:(NSString *)text{UITextField *f=[UITextField new];f.borderStyle=UITextBorderStyleRoundedRect;f.placeholder=text;f.autocorrectionType=UITextAutocorrectionTypeNo;f.autocapitalizationType=UITextAutocapitalizationTypeNone;return f;}
-(UIButton *)button:(NSString *)title action:(SEL)a{UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setTitle:title forState:0];[b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];return b;}
-(void)buildUI
{
 self.canvas=[WineCanvas new];
 self.canvas.translatesAutoresizingMaskIntoConstraints=NO;
 __weak typeof(self) weakSelf=self;
 self.canvas.input=^(JuiceMsg message){[weakSelf broadcast:&message size:sizeof(message)];};

 self.log=[UITextView new];
 self.log.editable=NO;
 self.log.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
 self.log.backgroundColor=UIColor.secondarySystemBackgroundColor;
 self.log.translatesAutoresizingMaskIntoConstraints=NO;

 self.exeField=[self field:@"EXE path (Windows or bundled name)"];
 self.exeField.text=@"winemine.exe";
 self.argsField=[self field:@"Arguments"];
 self.debugField=[self field:@"WINEDEBUG channels"];
 self.debugField.text=@"+loaddll,+iosdrv,+explorer,+seh";
 self.stdinField=[self field:@"CLI stdin"];
 self.stdinField.delegate=self;
 self.guiTextField=[self field:@"Text for focused Windows control"];
 self.guiTextField.delegate=self;

 self.mode=[[UISegmentedControl alloc]initWithItems:@[@"GUI",@"CLI"]];
 self.mode.selectedSegmentIndex=0;
 self.clickMode=[[UISegmentedControl alloc]initWithItems:@[@"Left click",@"Right click"]];
 self.clickMode.selectedSegmentIndex=0;
 [self.clickMode addTarget:self action:@selector(clickModeChanged) forControlEvents:UIControlEventValueChanged];

 self.x64Switch=[UISwitch new];
 self.x64Switch.on=NO;
 UILabel *x64Label=[UILabel new];
 x64Label.text=@"Experimental x86_64 (auto-detect)";
 x64Label.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
 UIStackView *x64Row=[[UIStackView alloc]initWithArrangedSubviews:@[x64Label,self.x64Switch]];
 x64Row.axis=UILayoutConstraintAxisHorizontal;
 x64Row.distribution=UIStackViewDistributionEqualSpacing;

 self.winebootSwitch=[UISwitch new];
 id savedWinebootOption=[NSUserDefaults.standardUserDefaults objectForKey:@"JuiceSkipWineboot"];
 self.winebootSwitch.on=savedWinebootOption?[savedWinebootOption boolValue]:YES;
 [self.winebootSwitch addTarget:self action:@selector(winebootModeChanged)
  forControlEvents:UIControlEventValueChanged];
 UILabel *winebootLabel=[UILabel new];
 winebootLabel.text=@"Skip Wineboot after prefix initialization";
 winebootLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
 UIStackView *winebootRow=[[UIStackView alloc]initWithArrangedSubviews:@[winebootLabel,self.winebootSwitch]];
 winebootRow.axis=UILayoutConstraintAxisHorizontal;
 winebootRow.distribution=UIStackViewDistributionEqualSpacing;

 UIStackView *selectors=[[UIStackView alloc]initWithArrangedSubviews:@[self.mode,self.clickMode]];
 selectors.axis=UILayoutConstraintAxisHorizontal;
 selectors.distribution=UIStackViewDistributionFillEqually;
 selectors.spacing=5;
 UIStackView *launchers=[[UIStackView alloc]initWithArrangedSubviews:@[[self button:@"Launch" action:@selector(launchRequested)],[self button:@"Stop" action:@selector(stopTapped)]]];
 launchers.axis=UILayoutConstraintAxisHorizontal;
 launchers.distribution=UIStackViewDistributionFillEqually;
 UIStackView *textRow=[[UIStackView alloc]initWithArrangedSubviews:@[self.guiTextField,[self button:@"Send Text" action:@selector(sendGuiTextTapped)]]];
 textRow.axis=UILayoutConstraintAxisHorizontal;
 textRow.spacing=5;
 UIStackView *keyRow=[[UIStackView alloc]initWithArrangedSubviews:@[[self button:@"Backspace" action:@selector(sendBackspace)],[self button:@"Tab" action:@selector(sendTab)],[self button:@"Enter" action:@selector(sendEnter)]]];
 keyRow.axis=UILayoutConstraintAxisHorizontal;
 keyRow.distribution=UIStackViewDistributionFillEqually;

 self.form=[[UIStackView alloc]initWithArrangedSubviews:@[self.exeField,[self button:@"Choose EXE or Portable ZIP" action:@selector(chooseExeTapped)],self.argsField,self.debugField,x64Row,winebootRow,selectors,launchers,textRow,keyRow,self.stdinField]];
 self.form.axis=UILayoutConstraintAxisVertical;
 self.form.spacing=4;
 self.form.translatesAutoresizingMaskIntoConstraints=NO;

 self.fullscreenButton=[self button:@"Fullscreen" action:@selector(fullscreenTapped)];
 self.fullscreenButton.translatesAutoresizingMaskIntoConstraints=NO;
 self.fullscreenButton.backgroundColor=[UIColor colorWithWhite:0 alpha:.55];
 self.fullscreenButton.tintColor=UIColor.whiteColor;
 self.fullscreenButton.layer.cornerRadius=7;
 self.fullscreenButton.contentEdgeInsets=UIEdgeInsetsMake(6,10,6,10);

 [self.view addSubview:self.canvas];
 [self.view addSubview:self.form];
 [self.view addSubview:self.log];
 [self.view addSubview:self.fullscreenButton];
 UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
 self.canvasHeightConstraint=[self.canvas.heightAnchor constraintEqualToAnchor:safe.heightAnchor multiplier:.48];
 self.canvasBottomConstraint=[self.canvas.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor];
 self.canvasBottomConstraint.active=NO;
 self.windowedConstraints=@[
  [self.form.topAnchor constraintEqualToAnchor:self.canvas.bottomAnchor constant:4],
  [self.form.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
  [self.form.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
  [self.log.topAnchor constraintEqualToAnchor:self.form.bottomAnchor constant:4],
  [self.log.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
  [self.log.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
  [self.log.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]
 ];
 [NSLayoutConstraint activateConstraints:@[
  [self.canvas.topAnchor constraintEqualToAnchor:safe.topAnchor],
  [self.canvas.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
  [self.canvas.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
  self.canvasHeightConstraint,
  [self.fullscreenButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
  [self.fullscreenButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8]
 ]];
 [NSLayoutConstraint activateConstraints:self.windowedConstraints];
}
-(BOOL)prefersStatusBarHidden{return self.fullscreen;}
-(BOOL)prefersHomeIndicatorAutoHidden{return self.fullscreen;}
-(void)fullscreenTapped
{
 [self.view endEditing:YES];
 self.fullscreen=!self.fullscreen;
 if(self.fullscreen)
 {
  [NSLayoutConstraint deactivateConstraints:self.windowedConstraints];
  self.canvasHeightConstraint.active=NO;
  self.form.hidden=YES;
  self.log.hidden=YES;
  self.canvasBottomConstraint.active=YES;
  [self.fullscreenButton setTitle:@"Exit Fullscreen" forState:UIControlStateNormal];
 }
 else
 {
  self.canvasBottomConstraint.active=NO;
  self.form.hidden=NO;
  self.log.hidden=NO;
  self.canvasHeightConstraint.active=YES;
  [NSLayoutConstraint activateConstraints:self.windowedConstraints];
  [self.fullscreenButton setTitle:@"Fullscreen" forState:UIControlStateNormal];
 }
 [self setNeedsStatusBarAppearanceUpdate];
 [self setNeedsUpdateOfHomeIndicatorAutoHidden];
 [UIView animateWithDuration:.2 animations:^{[self.view layoutIfNeeded];}];
 [self append:[NSString stringWithFormat:@"FULLSCREEN_CHANGED enabled=%d\n",self.fullscreen]];
}
-(void)clickModeChanged
{
 self.canvas.rightClick=self.clickMode.selectedSegmentIndex==1;
 [self append:[NSString stringWithFormat:@"MOUSE_BUTTON_MODE %@\n",self.canvas.rightClick?@"right":@"left"]];
}
-(void)winebootModeChanged
{
 [NSUserDefaults.standardUserDefaults setBool:self.winebootSwitch.on forKey:@"JuiceSkipWineboot"];
 [self append:[NSString stringWithFormat:@"WINEBOOT_OPTION skip_after_init=%d\n",self.winebootSwitch.on]];
}
-(BOOL)broadcastMessage:(JuiceMsg *)message payload:(NSData *)payload
{
 message->size=(uint32_t)payload.length;
 int fd=self.activeClient;
 if(fd<0)return NO;
 @synchronized(self.clients)
 {
  if(![self.clients containsObject:@(fd)]||!WriteAll(fd,message,sizeof(*message)))return NO;
  if(payload.length&&!WriteAll(fd,payload.bytes,payload.length))return NO;
 }
 return YES;
}
-(void)sendGuiTextTapped
{
 NSString *text=self.guiTextField.text?:@"";
 if(!text.length)return;
 if(!self.canvas.hwnd){[self append:@"GUI_TEXT_REJECTED reason=no-window\n"];return;}
 NSData *payload=[text dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
 if(!payload.length||payload.length>UINT32_MAX){[self append:@"GUI_TEXT_REJECTED reason=encoding\n"];return;}
 JuiceMsg message={JUICE_MAGIC,MSG_TEXT,0,self.canvas.hwnd,0,0,0,0,0,0};
 BOOL delivered=[self broadcastMessage:&message payload:payload];
 [self append:[NSString stringWithFormat:@"GUI_TEXT_SENT hwnd=0x%llx fd=%d utf16_units=%lu delivered=%d\n",(unsigned long long)self.canvas.hwnd,self.activeClient,(unsigned long)(payload.length/2),delivered]];
 self.guiTextField.text=@"";
}
-(void)sendVirtualKey:(uint32_t)key name:(NSString *)name
{
 if(!self.canvas.hwnd){[self append:@"GUI_KEY_REJECTED reason=no-window\n"];return;}
 JuiceMsg message={JUICE_MAGIC,MSG_KEY,0,self.canvas.hwnd,0,0,0,0,0,key};
 [self broadcastMessage:&message payload:nil];
 [self append:[NSString stringWithFormat:@"GUI_KEY_SENT hwnd=0x%llx key=%@ vk=0x%x\n",(unsigned long long)self.canvas.hwnd,name,key]];
}
-(void)sendBackspace{[self sendVirtualKey:0x08 name:@"backspace"];}
-(void)sendTab{[self sendVirtualKey:0x09 name:@"tab"];}
-(void)sendEnter{[self sendVirtualKey:0x0d name:@"enter"];}
-(void)append:(NSString *)s{if(!s)return;NSLog(@"JUICE_GUI %@",[s stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);@synchronized(self){NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:self.persistentLogPath];if(h){[h seekToEndOfFile];[h writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];[h closeFile];}}dispatch_async(dispatch_get_main_queue(),^{self.log.text=[(self.log.text?:@"") stringByAppendingString:s];[self.log scrollRangeToVisible:NSMakeRange(self.log.text.length,0)];});}
-(void)startDisplayServer{
 self.socketPath=@"/var/mobile/Documents/JuiceData/juice.sock";unlink(self.socketPath.fileSystemRepresentation);self.listenFD=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un a={0};a.sun_family=AF_UNIX;strncpy(a.sun_path,self.socketPath.fileSystemRepresentation,sizeof(a.sun_path)-1);int br=bind(self.listenFD,(void *)&a,sizeof(a));int lr=br?-1:listen(self.listenFD,8);[self append:[NSString stringWithFormat:@"DISPLAY_SOCKET path=%@ bind=%d listen=%d errno=%d\n",self.socketPath,br,lr,errno]];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{while(1){int fd=accept(self.listenFD,NULL,NULL);if(fd<0)break;@synchronized(self.clients){[self.clients addObject:@(fd)];}[self append:[NSString stringWithFormat:@"DISPLAY_CLIENT_CONNECTED fd=%d\n",fd]];dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[self readClient:fd];});}});
}
-(void)sendControlResponseToFD:(int)fd request:(uint32_t)request status:(int32_t)status
 path:(NSString *)path detail:(NSString *)detail
{
 struct juice_control_message message={0};
 message.magic=JUICE_CONTROL_MAGIC;
 message.version=JUICE_CONTROL_VERSION;
 message.type=JUICE_CONTROL_IMPORT_RESPONSE;
 message.size=sizeof(message);
 message.request_id=request;
 message.status=status;
 CopyControlString(message.path,sizeof(message.path),path);
 CopyControlString(message.detail,sizeof(message.detail),detail);
 NSData *wire=[NSData dataWithBytes:&message length:sizeof(message)];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
  WriteAll(fd,wire.bytes,wire.length);
  close(fd);
 });
}
-(void)finishControlImport:(int32_t)status path:(NSString *)path detail:(NSString *)detail
{
 int fd;
 uint32_t request;
 @synchronized(self)
 {
  fd=self.controlPickerFD;
  request=self.controlRequestID;
  self.controlPickerFD=-1;
  self.controlRequestID=0;
  self.controlFilters=0;
  self.controlPicker=nil;
 }
 if(fd>=0)[self sendControlResponseToFD:fd request:request status:status path:path detail:detail];
}
-(void)presentControlPicker
{
 if(self.controlPickerFD<0)return;
 UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
  initWithDocumentTypes:@[@"com.microsoft.windows-executable",@"com.pkware.zip-archive",
                          @"public.zip-archive",@"public.data"]
  inMode:UIDocumentPickerModeImport];
 picker.delegate=self;
 picker.allowsMultipleSelection=NO;
 self.controlPicker=picker;
 [self append:[NSString stringWithFormat:@"CONTROL_V1_FILE_PICKER_OPEN request=%u filters=%x\n",
  self.controlRequestID,self.controlFilters]];
 [self presentViewController:picker animated:YES completion:nil];
}
-(void)readControlClient:(int)fd
{
 struct juice_control_message message;
 if(!ReadAll(fd,&message,sizeof(message))||message.magic!=JUICE_CONTROL_MAGIC||
    message.version!=JUICE_CONTROL_VERSION||message.size!=sizeof(message))
 {
  close(fd);
  return;
 }
 if(message.type==JUICE_CONTROL_IMPORT_REQUEST)
 {
  BOOL busy=NO;
  @synchronized(self)
  {
   if(self.controlPickerFD>=0)busy=YES;
   else
   {
    self.controlPickerFD=fd;
    self.controlRequestID=message.request_id;
    self.controlFilters=message.flags;
   }
  }
  if(busy)
  {
   [self sendControlResponseToFD:fd request:message.request_id
    status:JUICE_CONTROL_STATUS_ERROR path:@""
    detail:@"Another Juice import request is already active."];
   return;
  }
  dispatch_async(dispatch_get_main_queue(),^{[self presentControlPicker];});
  return;
 }
 if(message.type==JUICE_CONTROL_HOST_ACTION)
 {
  NSString *path=[[NSString alloc]initWithBytes:message.path
   length:strnlen(message.path,sizeof(message.path)) encoding:NSUTF8StringEncoding]?:@"";
  uint32_t action=message.flags;
  dispatch_async(dispatch_get_main_queue(),^{[self handleControlAction:action path:path];});
 }
 close(fd);
}
-(void)startControlServer
{
 self.controlSocketPath=@"/var/mobile/Documents/JuiceData/juice-control-v1.sock";
 unlink(self.controlSocketPath.fileSystemRepresentation);
 self.controlListenFD=socket(AF_UNIX,SOCK_STREAM,0);
 struct sockaddr_un address={0};
 address.sun_family=AF_UNIX;
 strncpy(address.sun_path,self.controlSocketPath.fileSystemRepresentation,sizeof(address.sun_path)-1);
 int bindResult=bind(self.controlListenFD,(void *)&address,sizeof(address));
 int listenResult=bindResult?-1:listen(self.controlListenFD,4);
 [self append:[NSString stringWithFormat:@"CONTROL_V1_SOCKET path=%@ bind=%d listen=%d errno=%d\n",
  self.controlSocketPath,bindResult,listenResult,errno]];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
  while(1)
  {
   int fd=accept(self.controlListenFD,NULL,NULL);
   if(fd<0)break;
   dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[self readControlClient:fd];});
  }
 });
}
-(NSString *)unixPathForWindowsPath:(NSString *)path
{
 if(path.length>=3&&[[path substringToIndex:2] caseInsensitiveCompare:@"Z:"]==NSOrderedSame)
 {
  NSString *unix=[path substringFromIndex:2];
  unix=[unix stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
  return [unix hasPrefix:@"/"]?unix:[@"/" stringByAppendingString:unix];
 }
 if(path.length>=3&&[[path substringToIndex:2] caseInsensitiveCompare:@"C:"]==NSOrderedSame)
 {
  NSString *relative=[[path substringFromIndex:3] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
  return [[self.prefix stringByAppendingPathComponent:@"drive_c"] stringByAppendingPathComponent:relative];
 }
 return path;
}
-(void)importPortableZipFromLocalPath:(NSString *)source
{
 NSString *imports=@"/var/mobile/Documents/JuiceData/Imported";
 NSString *folder=[NSString stringWithFormat:@"%@-%@",source.lastPathComponent.stringByDeletingPathExtension,
                   NSUUID.UUID.UUIDString];
 NSString *destination=[imports stringByAppendingPathComponent:folder];
 [self append:[NSString stringWithFormat:@"CONTROL_V1_ZIP_IMPORT_BEGIN source=%@ destination=%@\n",
  source,destination]];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
  NSError *error=nil;
  BOOL extracted=[JuiceZip extractArchiveAtPath:source toDirectory:destination error:&error];
  NSArray<NSString *> *executables=extracted?[self executablesBelow:destination]:@[];
  if(!extracted)[NSFileManager.defaultManager removeItemAtPath:destination error:nil];
  dispatch_async(dispatch_get_main_queue(),^{
   if(!extracted)
   {
    [self append:[NSString stringWithFormat:@"CONTROL_V1_ZIP_IMPORT_FAILED error=%@\n",
     error.localizedDescription]];
    return;
   }
   [self append:[NSString stringWithFormat:@"CONTROL_V1_ZIP_READY root=%@ exe_count=%lu\n",
    destination,(unsigned long)executables.count]];
   if(executables.count)[self offerExecutables:executables root:destination source:source];
  });
 });
}
-(void)handleControlAction:(uint32_t)action path:(NSString *)windowsPath
{
 [self append:[NSString stringWithFormat:@"CONTROL_V1_HOST_ACTION action=%u path=%@\n",
  action,windowsPath]];
 if(action==JUICE_CONTROL_ACTION_SHOW_HOST_CONTROLS)
 {
  if(self.fullscreen)[self fullscreenTapped];
  return;
 }
 NSString *path=[self unixPathForWindowsPath:windowsPath];
 if(action==JUICE_CONTROL_ACTION_LAUNCH_PATH)
 {
  self.x64Switch.on=YES;
  self.exeField.text=path;
  self.argsField.text=@"";
  [self launchRequested];
 }
 else if(action==JUICE_CONTROL_ACTION_IMPORT_ZIP)
  [self importPortableZipFromLocalPath:path];
}
-(void)readClient:(int)fd{JuiceMsg m;pid_t peerPID=0;NSUInteger frameCount=0;while(ReadAll(fd,&m,sizeof(m))&&m.magic==JUICE_MAGIC){NSMutableData *d=nil;if(m.size){d=[NSMutableData dataWithLength:m.size];if(!ReadAll(fd,d.mutableBytes,m.size))break;}if(m.type==MSG_HELLO){peerPID=(pid_t)m.flags;[self append:[NSString stringWithFormat:@"DISPLAY_EVENT HELLO fd=%d pid=%d desktop=%dx%d dpi=%u\n",fd,peerPID,m.width,m.height,m.stride]];}else if(m.type==MSG_WINDOW){[self append:[NSString stringWithFormat:@"DISPLAY_EVENT WINDOW pid=%d hwnd=0x%llx rect=%d,%d %dx%d visible=%u\n",peerPID,(unsigned long long)m.hwnd,m.x,m.y,m.width,m.height,m.flags]];}else if(m.type==MSG_FRAME&&d){size_t expected=(size_t)m.stride*(size_t)m.height;if(expected<=d.length&&m.width>0&&m.height>0){NSData *copy=[d copy];BOOL first=(frameCount++==0);if(frameCount<=3)[self append:[NSString stringWithFormat:@"DISPLAY_EVENT FRAME pid=%d hwnd=0x%llx size=%dx%d stride=%u bytes=%u count=%lu\n",peerPID,(unsigned long long)m.hwnd,m.width,m.height,m.stride,m.size,(unsigned long)frameCount]];dispatch_async(dispatch_get_main_queue(),^{CGDataProviderRef p=CGDataProviderCreateWithCFData((__bridge CFDataRef)copy);CGColorSpaceRef c=CGColorSpaceCreateDeviceRGB();CGImageRef im=CGImageCreate(m.width,m.height,8,32,m.stride,c,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,p,NULL,false,kCGRenderingIntentDefault);UIImage *image=[UIImage imageWithCGImage:im scale:1 orientation:UIImageOrientationUp];self.canvas.image=image;self.canvas.hwnd=m.hwnd;self.activeClient=fd;if(first){NSString *path=[NSString stringWithFormat:@"/var/mobile/Documents/Juice-frame-%d.png",peerPID];[UIImagePNGRepresentation(image) writeToFile:path atomically:YES];[self append:[NSString stringWithFormat:@"JUICE_GUI_FRAME_RECEIVED pid=%d hwnd=0x%llx frame=%dx%d path=%@\n",peerPID,(unsigned long long)m.hwnd,m.width,m.height,path]];}CGImageRelease(im);CGColorSpaceRelease(c);CGDataProviderRelease(p);});}}}[self append:[NSString stringWithFormat:@"DISPLAY_CLIENT_CLOSED fd=%d pid=%d\n",fd,peerPID]];close(fd);@synchronized(self.clients){[self.clients removeObject:@(fd)];if(self.activeClient==fd)self.activeClient=-1;}}
-(void)broadcast:(const void *)p size:(size_t)n{int fd=self.activeClient;if(fd<0)return;@synchronized(self.clients){if([self.clients containsObject:@(fd)])WriteAll(fd,p,n);}}
-(NSString *)candidateExePath
{
 NSString *value=[self.exeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 if(!value.length)return @"";
 if([value containsString:@"/"])return value;
 NSString *native=[[[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Grape"]
  stringByAppendingPathComponent:@"runtime/lib/wine/aarch64-windows"] stringByAppendingPathComponent:value];
 if([NSFileManager.defaultManager fileExistsAtPath:native])return native;
 NSString *experimental=[[[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Grape-X64"]
  stringByAppendingPathComponent:@"runtime/lib/wine/aarch64-windows"] stringByAppendingPathComponent:value];
 if([NSFileManager.defaultManager fileExistsAtPath:experimental])return experimental;
 return native;
}
-(JuicePEMachine)machineForExecutableAtPath:(NSString *)path
{
 NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:path];
 if(!handle)return JuicePEMachineUnknown;
 NSData *dos=[handle readDataOfLength:64];
 if(dos.length<64){[handle closeFile];return JuicePEMachineUnknown;}
 const uint8_t *bytes=dos.bytes;
 if(bytes[0]!='M'||bytes[1]!='Z'){[handle closeFile];return JuicePEMachineUnknown;}
 uint32_t offset=(uint32_t)bytes[0x3c]|((uint32_t)bytes[0x3d]<<8)|
  ((uint32_t)bytes[0x3e]<<16)|((uint32_t)bytes[0x3f]<<24);
 if(offset>16*1024*1024){[handle closeFile];return JuicePEMachineUnknown;}
 @try{[handle seekToFileOffset:offset];}
 @catch(__unused NSException *exception){[handle closeFile];return JuicePEMachineUnknown;}
 NSData *header=[handle readDataOfLength:6];
 [handle closeFile];
 if(header.length<6)return JuicePEMachineUnknown;
 const uint8_t *pe=header.bytes;
 if(pe[0]!='P'||pe[1]!='E'||pe[2]||pe[3])return JuicePEMachineUnknown;
 return (JuicePEMachine)((uint16_t)pe[4]|((uint16_t)pe[5]<<8));
}
-(NSString *)nameForMachine:(JuicePEMachine)machine
{
 switch(machine)
 {
  case JuicePEMachineI386:return @"i386";
  case JuicePEMachineAMD64:return @"x86_64";
  case JuicePEMachineARM64:return @"ARM64";
  case JuicePEMachineARM64EC:return @"ARM64EC";
  default:return @"unknown";
 }
}
-(void)rejectLaunch:(NSString *)message
{
 [self append:[NSString stringWithFormat:@"ARCH_ROUTE_REJECTED %@\n",message]];
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Cannot launch executable"
  message:message preferredStyle:UIAlertControllerStyleAlert];
 [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
 [self presentViewController:alert animated:YES completion:nil];
}
-(void)launchRequested
{
 NSString *path=[self candidateExePath];
 JuicePEMachine machine=[self machineForExecutableAtPath:path];
 if(machine==JuicePEMachineUnknown)
 {
  [self rejectLaunch:[NSString stringWithFormat:@"Juice could not read a valid PE architecture from %@.",path.lastPathComponent]];
  return;
 }
 if(machine==JuicePEMachineI386)
 {
  [self rejectLaunch:@"32-bit x86 applications are not supported by this x86_64 experiment."];
  return;
 }
 BOOL experimental=(machine==JuicePEMachineAMD64||machine==JuicePEMachineARM64EC);
 if(machine!=JuicePEMachineARM64&&!experimental)
 {
  [self rejectLaunch:[NSString stringWithFormat:@"Unsupported PE machine 0x%04x.",machine]];
  return;
 }
 if(experimental&&!self.x64Switch.on)
 {
  [self rejectLaunch:@"This is an x86_64/ARM64EC app. Enable Experimental x86_64; Juice will then select its isolated runtime automatically."];
  return;
 }
 NSString *runtimeName=experimental?@"Grape-X64":@"Grape";
 NSString *runtime=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:runtimeName];
 if(![NSFileManager.defaultManager isExecutableFileAtPath:
      [runtime stringByAppendingPathComponent:@"build/wine-ios/loader/wine"]])
 {
  [self rejectLaunch:[NSString stringWithFormat:@"%@ is not installed in this build.",runtimeName]];
  return;
 }
 if(self.server>0&&self.serverUsingX64!=experimental)
 {
  kill(self.server,SIGTERM);
  waitpid(self.server,NULL,WNOHANG);
  self.server=-1;
 }
 self.usingX64=experimental;
 [self append:[NSString stringWithFormat:@"PE_ARCH_DETECTED machine=0x%04x arch=%@ runtime=%@ path=%@\n",
  machine,[self nameForMachine:machine],runtimeName,path]];
 [self launchTapped];
 self.serverUsingX64=self.usingX64;
}
-(void)chooseExeTapped
{
 UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
  initWithDocumentTypes:@[@"com.microsoft.windows-executable",@"com.pkware.zip-archive",
                          @"public.zip-archive",@"public.data"]
  inMode:UIDocumentPickerModeImport];
 picker.delegate=self;
 picker.allowsMultipleSelection=NO;
 [self append:@"CUSTOM_EXE_OR_ZIP_PICKER_OPENED\n"];
 [self presentViewController:picker animated:YES completion:nil];
}
-(void)runImportedExe:(NSString *)path source:(NSString *)source
{
 self.exeField.text=path;
 self.mode.selectedSegmentIndex=0;
 [self append:[NSString stringWithFormat:@"CUSTOM_EXE_SELECTED source=%@ local=%@\n",source,path]];
 dispatch_async(dispatch_get_main_queue(),^{[self launchRequested];});
}
-(NSArray<NSString *> *)executablesBelow:(NSString *)root
{
 NSMutableArray<NSString *> *result=[NSMutableArray array];
 NSDirectoryEnumerator<NSString *> *entries=[NSFileManager.defaultManager enumeratorAtPath:root];
 NSString *relative=nil;
 while((relative=entries.nextObject))
 {
  NSString *path=[root stringByAppendingPathComponent:relative];
  BOOL directory=NO;
  if(![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory]||directory)continue;
  if([path.pathExtension.lowercaseString isEqualToString:@"exe"])[result addObject:path];
 }
 [result sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
 return result;
}
-(void)offerExecutables:(NSArray<NSString *> *)paths root:(NSString *)root source:(NSString *)source
{
 if(paths.count==1){[self runImportedExe:paths.firstObject source:source];return;}
 UIAlertController *chooser=[UIAlertController alertControllerWithTitle:@"Choose an executable"
  message:@"This portable archive contains more than one .exe."
  preferredStyle:UIAlertControllerStyleAlert];
 for(NSString *path in paths)
 {
  NSString *label=[path substringFromIndex:MIN(path.length,root.length+1)];
  [chooser addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault
   handler:^(__unused UIAlertAction *action){[self runImportedExe:path source:source];}]];
 }
 [chooser addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
 [self presentViewController:chooser animated:YES completion:nil];
}
-(void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
 NSURL *url=urls.firstObject;
 if(!url)return;
 if(controller==self.controlPicker)
 {
  BOOL scoped=[url startAccessingSecurityScopedResource];
  NSString *name=url.lastPathComponent.length?url.lastPathComponent:@"installer";
  NSString *extension=name.pathExtension.lowercaseString;
  if(!([extension isEqualToString:@"msi"]||[extension isEqualToString:@"exe"]||
       [extension isEqualToString:@"zip"]))
  {
   if(scoped)[url stopAccessingSecurityScopedResource];
   [self finishControlImport:JUICE_CONTROL_STATUS_ERROR path:@""
    detail:@"Juice accepts .msi, .exe, and .zip files for installation."];
   return;
  }
  NSString *imports=@"/var/mobile/Documents/JuiceData/Imported";
  NSError *error=nil;
  [NSFileManager.defaultManager createDirectoryAtPath:imports withIntermediateDirectories:YES
   attributes:nil error:&error];
  NSString *destination=[imports stringByAppendingPathComponent:name];
  if(!error&&[NSFileManager.defaultManager fileExistsAtPath:destination])
  {
   NSString *unique=[NSString stringWithFormat:@"%@-%@.%@",name.stringByDeletingPathExtension,
                     NSUUID.UUID.UUIDString,name.pathExtension];
   destination=[imports stringByAppendingPathComponent:unique];
  }
  if(!error)[NSFileManager.defaultManager copyItemAtURL:url
   toURL:[NSURL fileURLWithPath:destination] error:&error];
  if(scoped)[url stopAccessingSecurityScopedResource];
  if(error)
  {
   [self append:[NSString stringWithFormat:@"CONTROL_V1_IMPORT_FAILED file=%@ error=%@\n",
    name,error.localizedDescription]];
   [self finishControlImport:JUICE_CONTROL_STATUS_ERROR path:@""
    detail:error.localizedDescription?:@"The selected file could not be copied."];
   return;
  }
  NSString *windows=[@"Z:" stringByAppendingString:
   [destination stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
  [self append:[NSString stringWithFormat:@"CONTROL_V1_IMPORT_COMPLETE local=%@ windows=%@\n",
   destination,windows]];
  [self finishControlImport:JUICE_CONTROL_STATUS_COMPLETE path:windows detail:@"Imported."];
  return;
 }
 BOOL scoped=[url startAccessingSecurityScopedResource];
 NSString *name=url.lastPathComponent.length?url.lastPathComponent:@"program.exe";
 NSString *extension=name.pathExtension.lowercaseString;
 NSFileManager *files=NSFileManager.defaultManager;
 NSString *imports=@"/var/mobile/Documents/JuiceData/Imported";
 NSError *directoryError=nil;
 [files createDirectoryAtPath:imports withIntermediateDirectories:YES attributes:nil error:&directoryError];
 if(directoryError)
 {
  if(scoped)[url stopAccessingSecurityScopedResource];
  [self append:[NSString stringWithFormat:@"CUSTOM_IMPORT_FAILED file=%@ error=%@\n",name,directoryError.localizedDescription]];
  return;
 }
 if([extension isEqualToString:@"exe"])
 {
  NSString *destination=[imports stringByAppendingPathComponent:name];
  if([files fileExistsAtPath:destination])
  {
   NSString *unique=[NSString stringWithFormat:@"%@-%@.%@",name.stringByDeletingPathExtension,
                     NSUUID.UUID.UUIDString,name.pathExtension];
   destination=[imports stringByAppendingPathComponent:unique];
  }
  NSError *copyError=nil;
  [files copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&copyError];
  if(scoped)[url stopAccessingSecurityScopedResource];
  if(copyError)
  {
   [self append:[NSString stringWithFormat:@"CUSTOM_EXE_IMPORT_FAILED file=%@ error=%@\n",name,copyError.localizedDescription]];
   return;
  }
  [self runImportedExe:destination source:url.path];
  return;
 }
 if([extension isEqualToString:@"zip"])
 {
  NSString *folder=[NSString stringWithFormat:@"%@-%@",name.stringByDeletingPathExtension,
                    NSUUID.UUID.UUIDString];
  NSString *destination=[imports stringByAppendingPathComponent:folder];
  NSString *source=url.path;
  [self append:[NSString stringWithFormat:@"PORTABLE_ZIP_IMPORT_BEGIN source=%@ destination=%@\n",source,destination]];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
   NSError *extractError=nil;
   BOOL extracted=[JuiceZip extractArchiveAtPath:url.path toDirectory:destination error:&extractError];
   if(scoped)[url stopAccessingSecurityScopedResource];
   NSArray<NSString *> *executables=extracted?[self executablesBelow:destination]:@[];
   if(!extracted)[files removeItemAtPath:destination error:nil];
   dispatch_async(dispatch_get_main_queue(),^{
    if(!extracted)
    {
     [self append:[NSString stringWithFormat:@"PORTABLE_ZIP_IMPORT_FAILED source=%@ error=%@\n",
                   source,extractError.localizedDescription]];
     return;
    }
    [self append:[NSString stringWithFormat:@"PORTABLE_ZIP_READY root=%@ exe_count=%lu\n",
                  destination,(unsigned long)executables.count]];
    if(!executables.count)
    {
     [self append:[NSString stringWithFormat:@"PORTABLE_ZIP_NO_EXE root=%@\n",destination]];
     return;
    }
    [self offerExecutables:executables root:destination source:source];
   });
  });
  return;
 }
 if(scoped)[url stopAccessingSecurityScopedResource];
 [self append:[NSString stringWithFormat:@"CUSTOM_EXE_REJECTED file=%@ reason=not-exe-or-zip\n",name]];
}
-(void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller{if(controller==self.controlPicker){[self append:@"CONTROL_V1_FILE_PICKER_CANCELLED\n"];[self finishControlImport:JUICE_CONTROL_STATUS_CANCELLED path:@"" detail:@"The file picker was cancelled."];return;}[self append:@"CUSTOM_EXE_PICKER_CANCELLED\n"];}
-(void)preparePrefix
{
 NSString *runtimeName=self.usingX64?@"Grape-X64":@"Grape";
 NSString *prefixName=self.usingX64?@"GrapePrefix-x86_64":@"GrapePrefix";
 self.grape=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:runtimeName];
 NSString *base=@"/var/mobile/Documents/JuiceData";
 self.prefix=[base stringByAppendingPathComponent:prefixName];
 NSFileManager *f=NSFileManager.defaultManager;
 [f createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
 NSString *ready=[self.prefix stringByAppendingPathComponent:@".juice-prefix-ready"];
 self.prefixNeedsInitialization=![f fileExistsAtPath:ready];
 if(![f fileExistsAtPath:[self.prefix stringByAppendingPathComponent:@"system.reg"]])
  [f copyItemAtPath:[self.grape stringByAppendingPathComponent:@"prefix-template"] toPath:self.prefix error:nil];
 NSString *dos=[self.prefix stringByAppendingPathComponent:@"dosdevices"];
 [f createDirectoryAtPath:dos withIntermediateDirectories:YES attributes:nil error:nil];
 NSString *z=[dos stringByAppendingPathComponent:@"z:"];
 [f removeItemAtPath:z error:nil];
 [f createSymbolicLinkAtPath:z withDestinationPath:@"/" error:nil];
 NSString *pe=[self.grape stringByAppendingPathComponent:@"runtime/lib/wine/aarch64-windows"];
 NSString *system32=[self.prefix stringByAppendingPathComponent:@"drive_c/windows/system32"];
 [f createDirectoryAtPath:system32 withIntermediateDirectories:YES attributes:nil error:nil];
 NSUInteger linkedModules=0;
 for(NSString *name in [f contentsOfDirectoryAtPath:pe error:nil]?:@[])
 {
  NSString *extension=name.pathExtension.lowercaseString;
  if(!([extension isEqualToString:@"dll"]||[extension isEqualToString:@"exe"]||
       [extension isEqualToString:@"drv"]))continue;
  NSString *source=[pe stringByAppendingPathComponent:name];
  NSString *destination=[system32 stringByAppendingPathComponent:name];
  BOOL juiceManaged=[name caseInsensitiveCompare:@"JuiceGUI.exe"]==NSOrderedSame||
                    [name caseInsensitiveCompare:@"JuiceTextSmoke.exe"]==NSOrderedSame||
                    [name caseInsensitiveCompare:@"winemine.exe"]==NSOrderedSame||
                    [name caseInsensitiveCompare:@"x86_64-smoke.exe"]==NSOrderedSame;
  if([f destinationOfSymbolicLinkAtPath:destination error:nil])
   [f removeItemAtPath:destination error:nil];
  if(self.prefixNeedsInitialization)continue;
  /* Prefixes persist across app upgrades. Refresh Juice-owned programs so an
   * old template copy cannot shadow the current, signed app-bundle version.
   * Never replace ordinary files belonging to installed applications. */
  if(juiceManaged&&[f fileExistsAtPath:destination])
   [f removeItemAtPath:destination error:nil];
  if(![f fileExistsAtPath:destination]&&
     [f createSymbolicLinkAtPath:destination withDestinationPath:source error:nil])
   linkedModules++;
 }
 NSString *user=[self.prefix stringByAppendingPathComponent:@"user.reg"];
 NSMutableString *reg=[NSMutableString stringWithContentsOfFile:user encoding:NSUTF8StringEncoding error:nil];
 if(reg&&[reg rangeOfString:@"\"Graphics\"=\"ios\""].location==NSNotFound)
 {
  [reg appendString:@"\n[Software\\\\Wine\\\\Drivers] 1770000000\n#time=1dc790000000000\n\"Graphics\"=\"ios\"\n"];
  [reg writeToFile:user atomically:YES encoding:NSUTF8StringEncoding error:nil];
 }
 [self append:[NSString stringWithFormat:@"RUNTIME_SELECTED runtime=%@ prefix=%@\n",runtimeName,self.prefix]];
 [self append:[NSString stringWithFormat:@"PREFIX_RUNTIME_LINKS count=%lu system32=%@\n",
  (unsigned long)linkedModules,system32]];
}
-(NSArray *)environment
{
 NSString *b=[self.grape stringByAppendingPathComponent:@"build/wine-ios"];
 NSString *pe=[self.grape stringByAppendingPathComponent:@"runtime/lib/wine/aarch64-windows"];
 NSMutableArray *variables=[NSMutableArray arrayWithArray:@[
  [@"HOME=" stringByAppendingString:NSHomeDirectory()],
  [@"TMPDIR=" stringByAppendingString:NSTemporaryDirectory()],
  [@"WINEPREFIX=" stringByAppendingString:self.prefix],
  [@"WINELOADER=" stringByAppendingString:[self.grape stringByAppendingPathComponent:@"tools/grape-nested-wrapper"]],
  [@"WINESERVER=" stringByAppendingString:[b stringByAppendingPathComponent:@"server/wineserver"]],
  [@"WINEDLLPATH=" stringByAppendingString:[NSString stringWithFormat:@"%@:/var/mobile/Documents/JuiceData/native:%@:%@:%@:%@",pe,[b stringByAppendingPathComponent:@"dlls/crypt32"],[b stringByAppendingPathComponent:@"dlls/wineios.drv"],[b stringByAppendingPathComponent:@"dlls/win32u"],[b stringByAppendingPathComponent:@"dlls/ws2_32"]]],
  @"DYLD_LIBRARY_PATH=/var/jb/usr/lib",
  [@"JUICE_IOS_SOCKET=" stringByAppendingString:self.socketPath],
  [@"JUICE_IOS_CONTROL_SOCKET=" stringByAppendingString:self.controlSocketPath],
  [NSString stringWithFormat:@"JUICE_SKIP_WINEBOOT=%d",self.winebootSwitch.on&&!self.prefixNeedsInitialization],
  [@"WINEDEBUG=" stringByAppendingString:(self.debugField.text.length?self.debugField.text:@"-all")],
  @"WINEARCH=win64",@"PATH=/usr/bin:/bin",@"LANG=C"
 ]];
 if(self.usingX64)[variables addObjectsFromArray:@[@"HODLL64=libarm64ecfex.dll",@"JUICE_EXPERIMENTAL_X64=1"]];
 return variables;
}
-(NSString *)resolveExe{NSString *e=self.exeField.text;if([e containsString:@"/"])return e;return [[self.grape stringByAppendingPathComponent:@"runtime/lib/wine/aarch64-windows"]stringByAppendingPathComponent:e];}
-(void)launchTapped{[self stopTapped];[self preparePrefix];NSArray *parts=self.argsField.text.length?[self.argsField.text componentsSeparatedByString:@" "]:@[];NSString *build=[self.grape stringByAppendingPathComponent:@"build/wine-ios"],*loader=[build stringByAppendingPathComponent:@"loader/wine"],*server=[build stringByAppendingPathComponent:@"server/wineserver"],*tracer=[self.grape stringByAppendingPathComponent:@"tools/grape-trace-parent"],*exe=[self resolveExe];NSArray *environment=[self environment];char **env=CopyStrings(environment);if(self.server<=0){char **serverArgv=CopyStrings(@[server,@"-f"]);posix_spawn_file_actions_t sf;posix_spawn_file_actions_init(&sf);int nullfd=open("/dev/null",O_WRONLY);if(nullfd>=0){posix_spawn_file_actions_adddup2(&sf,nullfd,1);posix_spawn_file_actions_adddup2(&sf,nullfd,2);}int sr=posix_spawn(&_server,server.UTF8String,&sf,NULL,serverArgv,env);posix_spawn_file_actions_destroy(&sf);if(nullfd>=0)close(nullfd);FreeStrings(serverArgv);[self append:[NSString stringWithFormat:@"Wine server: %d pid=%d\n",sr,self.server]];if(!sr)usleep(350000);}NSMutableArray *args=[NSMutableArray arrayWithObjects:tracer,loader,exe,nil];[args addObjectsFromArray:parts];char **argv=CopyStrings(args);int outputPipe[2],inputPipe[2];pipe(outputPipe);pipe(inputPipe);posix_spawn_file_actions_t fa;posix_spawn_file_actions_init(&fa);posix_spawn_file_actions_adddup2(&fa,inputPipe[0],0);posix_spawn_file_actions_adddup2(&fa,outputPipe[1],1);posix_spawn_file_actions_adddup2(&fa,outputPipe[1],2);posix_spawn_file_actions_addclose(&fa,inputPipe[1]);posix_spawn_file_actions_addclose(&fa,outputPipe[0]);int launchCwdFD=open(".",O_RDONLY);if(launchCwdFD>=0&&[exe containsString:@"/"])chdir(exe.stringByDeletingLastPathComponent.fileSystemRepresentation);int r=posix_spawn(&_child,tracer.UTF8String,&fa,NULL,argv,env);if(launchCwdFD>=0){fchdir(launchCwdFD);close(launchCwdFD);}posix_spawn_file_actions_destroy(&fa);close(inputPipe[0]);close(outputPipe[1]);self.childInput=r?-1:inputPipe[1];if(r)close(inputPipe[1]);int readFD=outputPipe[0];FreeStrings(argv);FreeStrings(env);self.canvas.hidden=self.mode.selectedSegmentIndex==1;[self append:[NSString stringWithFormat:@"\n%@ launch %@: %d pid=%d\n",self.mode.selectedSegmentIndex?@"CLI":@"GUI",exe,r,self.child]];if(!r)dispatch_async(dispatch_get_global_queue(0,0),^{char b[2048];ssize_t n;while((n=read(readFD,b,sizeof(b)))>0){NSString *text=[[NSString alloc]initWithBytes:b length:n encoding:NSUTF8StringEncoding];[self append:text?:@""];}close(readFD);waitpid(self.child,NULL,0);self.child=-1;if(self.childInput>=0){close(self.childInput);self.childInput=-1;}});}
-(void)stopTapped{if(self.childInput>=0){close(self.childInput);self.childInput=-1;}if(self.child>0){kill(self.child,SIGTERM);self.child=-1;}}
-(BOOL)textFieldShouldReturn:(UITextField *)field
{
 if(field==self.guiTextField)
 {
  [self sendGuiTextTapped];
  return NO;
 }
 if(field==self.stdinField&&self.childInput>=0)
 {
  NSString *line=[(field.text?:@"") stringByAppendingString:@"\r\n"];
  WriteAll(self.childInput,line.UTF8String,strlen(line.UTF8String));
  [self append:[@"> " stringByAppendingString:line]];
  field.text=@"";
 }
 [field resignFirstResponder];
 return YES;
}
-(void)dealloc{[self stopTapped];if(self.listenFD>=0)close(self.listenFD);if(self.controlListenFD>=0)close(self.controlListenFD);if(self.controlPickerFD>=0)close(self.controlPickerFD);unlink(self.socketPath.fileSystemRepresentation);unlink(self.controlSocketPath.fileSystemRepresentation);}
@end
@interface AppDelegate:UIResponder<UIApplicationDelegate>@property(nonatomic,strong)UIWindow *window;@end
@implementation AppDelegate
-(BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o{self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[JuiceController new];[self.window makeKeyAndVisible];return YES;}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class));}}
