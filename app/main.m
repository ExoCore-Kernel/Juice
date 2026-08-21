#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import "JuiceZip.h"
#import "../wine/dlls/wineios.drv/control_protocol.h"
#import "../wine/include/juiceinput.h"
#import <spawn.h>
#import <sys/socket.h>
#import <sys/mman.h>
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
#define MSG_HARDWARE_KEY 103u
#define INPUT_LEFT_DOWN 1u
#define INPUT_LEFT_UP 2u
#define INPUT_RIGHT_DOWN 4u
#define INPUT_RIGHT_UP 8u
#define HARDWARE_KEY_DOWN 1u
#define HARDWARE_KEY_UP 2u
#define HARDWARE_KEY_EXTENDED 4u
#define HARDWARE_KEY_REPEAT 8u
typedef struct { uint32_t magic,type,size; uint64_t hwnd; int32_t x,y,width,height; uint32_t stride,flags; } JuiceMsg;
typedef struct { uint16_t virtualKey,scanCode; BOOL extended; } JuiceKeyMap;

typedef NS_ENUM(uint16_t, JuicePEMachine) {
 JuicePEMachineUnknown=0,
 JuicePEMachineI386=0x014c,
 JuicePEMachineAMD64=0x8664,
 JuicePEMachineARM64=0xaa64,
 JuicePEMachineARM64EC=0xa641,
};

static BOOL ReadAll(int fd,void *p,size_t n){char *b=p;while(n){ssize_t r=read(fd,b,n);if(r<=0)return NO;b+=r;n-=r;}return YES;}
static BOOL WriteAll(int fd,const void *p,size_t n){const char *b=p;while(n){ssize_t r=write(fd,p,n);if(r<=0)return NO;p=(const char *)p+r;n-=r;}return YES;}
static char **CopyStrings(NSArray<NSString *> *a){char **v=calloc(a.count+1,sizeof(char *));for(NSUInteger i=0;i<a.count;i++)v[i]=strdup(a[i].UTF8String);return v;}
static void FreeStrings(char **v){if(!v)return;for(size_t i=0;v[i];i++)free(v[i]);free(v);}
static void CopyControlString(char *destination,size_t capacity,NSString *value){if(!capacity)return;destination[0]=0;if(value.length) [value getCString:destination maxLength:capacity encoding:NSUTF8StringEncoding];}
static NSString *JuiceDocumentsRoot(void)
{
 NSArray<NSString *> *paths=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES);
 return paths.firstObject?:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}
static NSString *JuiceDataRoot(void){return [JuiceDocumentsRoot() stringByAppendingPathComponent:@"JuiceData"];}
static NSString *JuiceWindowsPath(NSString *unixPath)
{
 return [@"Z:" stringByAppendingString:[unixPath stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
}
static int16_t JuiceControllerAxis(float value){if(value<=-1.f)return INT16_MIN;if(value>=1.f)return INT16_MAX;return (int16_t)(value*(value<0?32768.f:32767.f));}
static uint8_t JuiceControllerTrigger(float value){if(value<=0.f)return 0;if(value>=1.f)return UINT8_MAX;return (uint8_t)(value*255.f+.5f);}
static JuiceKeyMap JuiceMapHIDUsage(NSUInteger usage)
{
 static const uint8_t letterScans[26]={0x1e,0x30,0x2e,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19,0x10,0x13,0x1f,0x14,0x16,0x2f,0x11,0x2d,0x15,0x2c};
 static const uint8_t digitScans[10]={0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b};
 static const uint8_t functionScans[12]={0x3b,0x3c,0x3d,0x3e,0x3f,0x40,0x41,0x42,0x43,0x44,0x57,0x58};
 if(usage>=0x04&&usage<=0x1d)return (JuiceKeyMap){(uint16_t)(0x41+usage-0x04),letterScans[usage-0x04],NO};
 if(usage>=0x1e&&usage<=0x27)
 {
  NSUInteger index=usage-0x1e;
  return (JuiceKeyMap){(uint16_t)(index==9?0x30:0x31+index),digitScans[index],NO};
 }
 if(usage>=0x3a&&usage<=0x45)return (JuiceKeyMap){(uint16_t)(0x70+usage-0x3a),functionScans[usage-0x3a],NO};
 switch(usage)
 {
  case 0x28:return (JuiceKeyMap){0x0d,0x1c,NO};
  case 0x29:return (JuiceKeyMap){0x1b,0x01,NO};
  case 0x2a:return (JuiceKeyMap){0x08,0x0e,NO};
  case 0x2b:return (JuiceKeyMap){0x09,0x0f,NO};
  case 0x2c:return (JuiceKeyMap){0x20,0x39,NO};
  case 0x2d:return (JuiceKeyMap){0xbd,0x0c,NO};
  case 0x2e:return (JuiceKeyMap){0xbb,0x0d,NO};
  case 0x2f:return (JuiceKeyMap){0xdb,0x1a,NO};
  case 0x30:return (JuiceKeyMap){0xdd,0x1b,NO};
  case 0x31:case 0x32:return (JuiceKeyMap){0xdc,0x2b,NO};
  case 0x33:return (JuiceKeyMap){0xba,0x27,NO};
  case 0x34:return (JuiceKeyMap){0xde,0x28,NO};
  case 0x35:return (JuiceKeyMap){0xc0,0x29,NO};
  case 0x36:return (JuiceKeyMap){0xbc,0x33,NO};
  case 0x37:return (JuiceKeyMap){0xbe,0x34,NO};
  case 0x38:return (JuiceKeyMap){0xbf,0x35,NO};
  case 0x39:return (JuiceKeyMap){0x14,0x3a,NO};
  case 0x46:return (JuiceKeyMap){0x2c,0x37,YES};
  case 0x47:return (JuiceKeyMap){0x91,0x46,NO};
  case 0x48:return (JuiceKeyMap){0x13,0x45,NO};
  case 0x49:return (JuiceKeyMap){0x2d,0x52,YES};
  case 0x4a:return (JuiceKeyMap){0x24,0x47,YES};
  case 0x4b:return (JuiceKeyMap){0x21,0x49,YES};
  case 0x4c:return (JuiceKeyMap){0x2e,0x53,YES};
  case 0x4d:return (JuiceKeyMap){0x23,0x4f,YES};
  case 0x4e:return (JuiceKeyMap){0x22,0x51,YES};
  case 0x4f:return (JuiceKeyMap){0x27,0x4d,YES};
  case 0x50:return (JuiceKeyMap){0x25,0x4b,YES};
  case 0x51:return (JuiceKeyMap){0x28,0x50,YES};
  case 0x52:return (JuiceKeyMap){0x26,0x48,YES};
  case 0x53:return (JuiceKeyMap){0x90,0x45,YES};
  case 0x54:return (JuiceKeyMap){0x6f,0x35,YES};
  case 0x55:return (JuiceKeyMap){0x6a,0x37,NO};
  case 0x56:return (JuiceKeyMap){0x6d,0x4a,NO};
  case 0x57:return (JuiceKeyMap){0x6b,0x4e,NO};
  case 0x58:return (JuiceKeyMap){0x0d,0x1c,YES};
  case 0x59:return (JuiceKeyMap){0x61,0x4f,NO};
  case 0x5a:return (JuiceKeyMap){0x62,0x50,NO};
  case 0x5b:return (JuiceKeyMap){0x63,0x51,NO};
  case 0x5c:return (JuiceKeyMap){0x64,0x4b,NO};
  case 0x5d:return (JuiceKeyMap){0x65,0x4c,NO};
  case 0x5e:return (JuiceKeyMap){0x66,0x4d,NO};
  case 0x5f:return (JuiceKeyMap){0x67,0x47,NO};
  case 0x60:return (JuiceKeyMap){0x68,0x48,NO};
  case 0x61:return (JuiceKeyMap){0x69,0x49,NO};
  case 0x62:return (JuiceKeyMap){0x60,0x52,NO};
  case 0x63:return (JuiceKeyMap){0x6e,0x53,NO};
  case 0x65:return (JuiceKeyMap){0x5d,0x5d,YES};
  case 0xe0:return (JuiceKeyMap){0xa2,0x1d,NO};
  case 0xe1:return (JuiceKeyMap){0xa0,0x2a,NO};
  case 0xe2:return (JuiceKeyMap){0xa4,0x38,NO};
  case 0xe3:return (JuiceKeyMap){0x5b,0x5b,YES};
  case 0xe4:return (JuiceKeyMap){0xa3,0x1d,YES};
  case 0xe5:return (JuiceKeyMap){0xa1,0x36,NO};
  case 0xe6:return (JuiceKeyMap){0xa5,0x38,YES};
  case 0xe7:return (JuiceKeyMap){0x5c,0x5c,YES};
  default:return (JuiceKeyMap){0,0,NO};
 }
}

@interface WineWindowState : NSObject
@property(nonatomic) uint64_t hwnd;
@property(nonatomic) CGRect frame;
@property(nonatomic,strong) UIImage *image;
@property(nonatomic) BOOL visible;
@property(nonatomic) int clientFD;
@end
@implementation WineWindowState
@end

@interface WineCanvas : UIImageView
@property(nonatomic) uint64_t hwnd;
@property(nonatomic) BOOL rightClick;
@property(nonatomic,copy) void (^input)(JuiceMsg);
@property(nonatomic,copy) void (^keyInput)(JuiceKeyMap,BOOL,BOOL,NSString *);
@end
@implementation WineCanvas
-(instancetype)init{if((self=[super init])){self.userInteractionEnabled=YES;self.contentMode=UIViewContentModeScaleAspectFit;self.backgroundColor=UIColor.blackColor;}return self;}
-(BOOL)canBecomeFirstResponder{return YES;}
-(void)didMoveToWindow{[super didMoveToWindow];if(self.window)dispatch_async(dispatch_get_main_queue(),^{[self becomeFirstResponder];});}
-(CGPoint)winePoint:(UITouch *)touch{CGPoint p=[touch locationInView:self];CGSize im=self.image.size;if(!im.width||!im.height)return p;CGFloat s=MIN(self.bounds.size.width/im.width,self.bounds.size.height/im.height);CGFloat ox=(self.bounds.size.width-im.width*s)/2,oy=(self.bounds.size.height-im.height*s)/2;return CGPointMake(MAX(0,MIN(im.width-1,(p.x-ox)/s)),MAX(0,MIN(im.height-1,(p.y-oy)/s)));}
-(void)send:(UITouch *)t flags:(uint32_t)flags{if(!self.input)return;if(flags&INPUT_LEFT_DOWN)flags=self.rightClick?INPUT_RIGHT_DOWN:INPUT_LEFT_DOWN;else if(flags&INPUT_LEFT_UP)flags=self.rightClick?INPUT_RIGHT_UP:INPUT_LEFT_UP;CGPoint p=[self winePoint:t];JuiceMsg m={JUICE_MAGIC,MSG_INPUT,0,self.hwnd,(int32_t)p.x,(int32_t)p.y,0,0,0,flags};self.input(m);}
-(void)touchesBegan:(NSSet *)t withEvent:(UIEvent *)e{[self becomeFirstResponder];[self send:t.anyObject flags:1];}
-(void)touchesMoved:(NSSet *)t withEvent:(UIEvent *)e{[self send:t.anyObject flags:0];}
-(void)touchesEnded:(NSSet *)t withEvent:(UIEvent *)e{[self send:t.anyObject flags:2];}
-(void)touchesCancelled:(NSSet *)t withEvent:(UIEvent *)e{[self send:t.anyObject flags:2];}
-(BOOL)sendPresses:(NSSet<UIPress *> *)presses down:(BOOL)down cancelled:(BOOL)cancelled
{
 BOOL handled=NO;
 for(UIPress *press in presses)
 {
  UIKey *key=press.key;
  if(!key)continue;
  JuiceKeyMap mapped=JuiceMapHIDUsage((NSUInteger)key.keyCode);
  NSString *fallback=mapped.scanCode?nil:key.characters;
  if(mapped.scanCode||fallback.length)
  {
   handled=YES;
   if(self.keyInput)self.keyInput(mapped,down,NO,fallback);
   if(cancelled&&down&&self.keyInput)self.keyInput(mapped,NO,NO,nil);
  }
 }
 return handled;
}
-(void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{if(![self sendPresses:presses down:YES cancelled:NO])[super pressesBegan:presses withEvent:event];}
-(void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{if(![self sendPresses:presses down:NO cancelled:NO])[super pressesEnded:presses withEvent:event];}
-(void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{if(![self sendPresses:presses down:NO cancelled:YES])[super pressesCancelled:presses withEvent:event];}
@end

@interface JuiceController : UIViewController <UITextFieldDelegate,UIDocumentPickerDelegate>
@property(nonatomic,strong) WineCanvas *canvas;
@property(nonatomic,strong) UITextView *log;
@property(nonatomic,strong) UITextField *exeField,*argsField,*debugField,*stdinField,*guiTextField;
@property(nonatomic,strong) UISegmentedControl *mode,*clickMode;
@property(nonatomic,strong) UISwitch *x64Switch,*winebootSwitch;
@property(nonatomic,strong) UIStackView *form;
@property(nonatomic,strong) UIButton *fullscreenButton,*experimentalButton;
@property(nonatomic,strong) NSLayoutConstraint *canvasHeightConstraint,*canvasBottomConstraint;
@property(nonatomic,copy) NSArray<NSLayoutConstraint *> *windowedConstraints;
@property(nonatomic) int listenFD,activeClient,controlListenFD,controlPickerFD;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *clients;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,WineWindowState *> *wineWindows;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *wineWindowOrder;
@property(nonatomic,copy) NSString *socketPath,*controlSocketPath,*grape,*prefix;
@property(nonatomic,strong) UIDocumentPickerViewController *controlPicker;
@property(nonatomic,strong) GCController *activeGameController;
@property(nonatomic) uint32_t controlRequestID,controlFilters;
@property(nonatomic) pid_t child,server;
@property(nonatomic) int childInput,lastLegacyClient,inputClient,gamepadFD;
@property(nonatomic) uint64_t lastLegacyHwnd,inputHwnd;
@property(nonatomic) CGSize wineDesktopSize;
@property(nonatomic,strong) UIImage *lastLegacyImage;
@property(nonatomic) BOOL experimentalMultiWindow,experimentalX64;
@property(nonatomic) struct juice_gamepad_shared_state *gamepadState;
@property(nonatomic) uint32_t hardwareKeyEvents;
@property(nonatomic) BOOL didAutoLaunch,reportedFrame,fullscreen,usingX64,serverUsingX64,desktopMode,prefixNeedsInitialization;
@property(nonatomic,copy) NSString *persistentLogPath;
@end
@implementation JuiceController
-(void)viewDidLoad
{
 [super viewDidLoad];
 self.view.backgroundColor=UIColor.systemBackgroundColor;
 self.clients=[NSMutableArray array];
 self.wineWindows=[NSMutableDictionary dictionary];
 self.wineWindowOrder=[NSMutableArray array];
 self.wineDesktopSize=CGSizeMake(1024,768);
 self.lastLegacyClient=self.inputClient=-1;
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
 id multi=[defaults objectForKey:@"JuiceExperimentalMultiWindow"];
 id x64=[defaults objectForKey:@"JuiceExperimentalX64"];
 self.experimentalMultiWindow=multi?[multi boolValue]:NO;
 self.experimentalX64=x64?[x64 boolValue]:NO;
 self.listenFD=self.activeClient=self.controlListenFD=self.controlPickerFD=-1;
 self.child=self.server=-1;
 self.childInput=self.gamepadFD=-1;
 NSString *dataRoot=JuiceDataRoot();
 [NSFileManager.defaultManager createDirectoryAtPath:dataRoot
  withIntermediateDirectories:YES attributes:nil error:nil];
 self.persistentLogPath=[JuiceDocumentsRoot() stringByAppendingPathComponent:@"Juice-GUI-Headless.log"];
 [@"JUICE_HEADLESS_TEST_BEGIN\n" writeToFile:self.persistentLogPath atomically:YES
  encoding:NSUTF8StringEncoding error:nil];
 [self buildUI];
 [self setupExternalInput];
 [self startDisplayServer];
 [self startControlServer];
 [self append:[NSString stringWithFormat:@"EXPERIMENTAL_STATE multi_window=%d x86_64=%d\n",
  self.experimentalMultiWindow,self.experimentalX64]];
 id<MTLDevice> hostMetal=MTLCreateSystemDefaultDevice();
 [self append:[NSString stringWithFormat:@"HOST_METAL_DEVICE available=%d name=%@\n",
  hostMetal!=nil,hostMetal.name?:@"none"]];
 [self append:@"GUI_READY\n"];
}
-(void)viewDidAppear:(BOOL)animated
{
 [super viewDidAppear:animated];
 if(self.didAutoLaunch)return;
 self.didAutoLaunch=YES;
 NSString *base=JuiceDataRoot();
 NSString *autoPathFile=[base stringByAppendingPathComponent:@"AutoLaunchPath"];
 NSString *x64Flag=[base stringByAppendingPathComponent:@"RunX64Smoke"];
 NSString *arm64Flag=[base stringByAppendingPathComponent:@"RunARM64Smoke"];
 NSString *autoPath=[[NSString stringWithContentsOfFile:autoPathFile
  encoding:NSUTF8StringEncoding error:nil]
  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 if(autoPath.length)
 {
  [NSFileManager.defaultManager removeItemAtPath:autoPathFile error:nil];
  NSString *argsFile=[base stringByAppendingPathComponent:@"AutoLaunchArgs"];
  NSString *debugFile=[base stringByAppendingPathComponent:@"AutoLaunchDebug"];
  NSString *arguments=[NSString stringWithContentsOfFile:argsFile encoding:NSUTF8StringEncoding error:nil];
  NSString *debug=[NSString stringWithContentsOfFile:debugFile encoding:NSUTF8StringEncoding error:nil];
  [NSFileManager.defaultManager removeItemAtPath:argsFile error:nil];
  [NSFileManager.defaultManager removeItemAtPath:debugFile error:nil];
  self.exeField.text=autoPath;
  self.argsField.text=[arguments stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";
  if(debug.length)self.debugField.text=[debug stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  JuicePEMachine machine=[self machineForExecutableAtPath:autoPath];
  if(machine==JuicePEMachineAMD64||machine==JuicePEMachineARM64EC)
   [self applyExperimentalX64Enabled:YES];
  [self append:[NSString stringWithFormat:@"AUTO_LAUNCH_CUSTOM path=%@ machine=0x%04x\n",autoPath,machine]];
 }
 else if([NSFileManager.defaultManager fileExistsAtPath:x64Flag])
 {
  [NSFileManager.defaultManager removeItemAtPath:x64Flag error:nil];
  [self applyExperimentalX64Enabled:YES];
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
-(UIButton *)button:(NSString *)title action:(SEL)a{UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setTitle:title forState:0];if(a)[b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];return b;}
-(void)buildUI
{
 self.canvas=[WineCanvas new];
 self.canvas.translatesAutoresizingMaskIntoConstraints=NO;
 __weak typeof(self) weakSelf=self;
 self.canvas.input=^(JuiceMsg message){[weakSelf handleCanvasInput:message];};
 self.canvas.keyInput=^(JuiceKeyMap key,BOOL down,BOOL repeat,NSString *fallback){[weakSelf sendHardwareKey:key down:down repeat:repeat fallback:fallback];};

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
 self.x64Switch.on=self.experimentalX64;
 [self.x64Switch addTarget:self action:@selector(experimentalX64SwitchChanged)
  forControlEvents:UIControlEventValueChanged];
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

 self.experimentalButton=[self button:@"Experimental" action:nil];
 self.experimentalButton.translatesAutoresizingMaskIntoConstraints=NO;
 self.experimentalButton.backgroundColor=[UIColor colorWithWhite:0 alpha:.55];
 self.experimentalButton.tintColor=UIColor.whiteColor;
 self.experimentalButton.layer.cornerRadius=7;
 self.experimentalButton.contentEdgeInsets=UIEdgeInsetsMake(6,10,6,10);
 self.experimentalButton.showsMenuAsPrimaryAction=YES;
 [self rebuildExperimentalMenu];

 [self.view addSubview:self.canvas];
 [self.view addSubview:self.form];
 [self.view addSubview:self.log];
 [self.view addSubview:self.fullscreenButton];
 [self.view addSubview:self.experimentalButton];
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
  [self.fullscreenButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
  [self.experimentalButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
  [self.experimentalButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8]
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
-(void)experimentalX64SwitchChanged
{
 [self applyExperimentalX64Enabled:self.x64Switch.on];
}
-(void)applyExperimentalX64Enabled:(BOOL)enabled
{
 self.experimentalX64=enabled;
 self.x64Switch.on=enabled;
 [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"JuiceExperimentalX64"];
 [self rebuildExperimentalMenu];
 [self append:[NSString stringWithFormat:@"EXPERIMENTAL_X86_64 enabled=%d\n",enabled]];
}
-(void)applyExperimentalMultiWindowEnabled:(BOOL)enabled
{
 self.experimentalMultiWindow=enabled;
 self.inputClient=-1;
 self.inputHwnd=0;
 [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"JuiceExperimentalMultiWindow"];
 [self rebuildExperimentalMenu];
 if(enabled)[self compositeWineDesktop];
 else
 {
  self.canvas.image=self.lastLegacyImage;
  self.canvas.hwnd=self.lastLegacyHwnd;
  if(self.lastLegacyClient>=0)self.activeClient=self.lastLegacyClient;
 }
 [self append:[NSString stringWithFormat:@"EXPERIMENTAL_MULTI_WINDOW enabled=%d tracked=%lu\n",
  enabled,(unsigned long)self.wineWindows.count]];
}
-(void)rebuildExperimentalMenu
{
 if(!self.experimentalButton)return;
 __weak typeof(self) weakSelf=self;
 UIAction *multi=[UIAction actionWithTitle:@"Multi-window compositing" image:nil identifier:nil
  handler:^(__unused UIAction *action){[weakSelf applyExperimentalMultiWindowEnabled:!weakSelf.experimentalMultiWindow];}];
 multi.discoverabilityTitle=@"Render menus, dialogs and popups over their application";
 multi.state=self.experimentalMultiWindow?UIMenuElementStateOn:UIMenuElementStateOff;
 UIAction *x64=[UIAction actionWithTitle:@"x86-64 / FEX translation" image:nil identifier:nil
  handler:^(__unused UIAction *action){[weakSelf applyExperimentalX64Enabled:!weakSelf.experimentalX64];}];
 x64.discoverabilityTitle=@"Allow the experimental x86-64 runtime";
 x64.state=self.experimentalX64?UIMenuElementStateOn:UIMenuElementStateOff;
 self.experimentalButton.menu=[UIMenu menuWithTitle:@"Experimental features" children:@[multi,x64]];
}
-(WineWindowState *)windowStateForHwnd:(uint64_t)hwnd create:(BOOL)create client:(int)fd
{
 NSNumber *key=@(hwnd);
 WineWindowState *state=self.wineWindows[key];
 if(!state&&create)
 {
  state=[WineWindowState new];
  state.hwnd=hwnd;
  state.visible=YES;
  state.clientFD=fd;
  self.wineWindows[key]=state;
  [self.wineWindowOrder addObject:key];
 }
 if(state&&fd>=0)state.clientFD=fd;
 return state;
}
-(void)updateWindowMessage:(JuiceMsg)message client:(int)fd
{
 NSNumber *key=@(message.hwnd);
 WineWindowState *state=self.wineWindows[key];
 BOOL newlyCreated=!state;
 BOOL wasVisible=state.visible;
 state=[self windowStateForHwnd:message.hwnd create:YES client:fd];
 if(message.width>0&&message.height>0)
  state.frame=CGRectMake(message.x,message.y,message.width,message.height);
 state.visible=message.flags!=0;
 if((newlyCreated||(state.visible&&!wasVisible))&&state.visible)
 {
  [self.wineWindowOrder removeObject:key];
  [self.wineWindowOrder addObject:key];
 }
 if(!state.visible&&self.inputHwnd==state.hwnd)
 {
  self.inputHwnd=0;
  self.inputClient=-1;
 }
 if(self.experimentalMultiWindow)[self compositeWineDesktop];
}
-(void)destroyWindowHwnd:(uint64_t)hwnd
{
 NSNumber *key=@(hwnd);
 [self.wineWindows removeObjectForKey:key];
 [self.wineWindowOrder removeObject:key];
 if(self.inputHwnd==hwnd){self.inputHwnd=0;self.inputClient=-1;}
 if(self.canvas.hwnd==hwnd)self.canvas.hwnd=0;
 if(self.experimentalMultiWindow)[self compositeWineDesktop];
}
-(void)removeWindowsForClient:(int)fd
{
 NSMutableArray<NSNumber *> *remove=[NSMutableArray array];
 for(NSNumber *key in self.wineWindows)
  if(self.wineWindows[key].clientFD==fd)[remove addObject:key];
 for(NSNumber *key in remove)[self.wineWindows removeObjectForKey:key];
 [self.wineWindowOrder removeObjectsInArray:remove];
 if(self.inputClient==fd){self.inputClient=-1;self.inputHwnd=0;}
 if(self.experimentalMultiWindow&&remove.count)[self compositeWineDesktop];
}
-(void)compositeWineDesktop
{
 CGSize size=self.wineDesktopSize;
 if(size.width<1||size.height<1)size=CGSizeMake(1024,768);
 UIGraphicsBeginImageContextWithOptions(size,YES,1.0);
 [[UIColor blackColor] setFill];
 UIRectFill(CGRectMake(0,0,size.width,size.height));
 for(NSNumber *key in self.wineWindowOrder)
 {
  WineWindowState *state=self.wineWindows[key];
  if(!state.visible||!state.image)continue;
  CGRect rect=state.frame;
  if(rect.size.width<=0||rect.size.height<=0)
   rect=CGRectMake(0,0,state.image.size.width,state.image.size.height);
  [state.image drawInRect:rect];
 }
 UIImage *result=UIGraphicsGetImageFromCurrentImageContext();
 UIGraphicsEndImageContext();
 if(result)self.canvas.image=result;
}
-(WineWindowState *)topWindowAtPoint:(CGPoint)point
{
 for(NSNumber *key in self.wineWindowOrder.reverseObjectEnumerator)
 {
  WineWindowState *state=self.wineWindows[key];
  if(!state.visible||!state.image)continue;
  CGRect rect=state.frame;
  if(rect.size.width<=0||rect.size.height<=0)
   rect=CGRectMake(0,0,state.image.size.width,state.image.size.height);
  if(CGRectContainsPoint(rect,point))return state;
 }
 return nil;
}
-(void)sendHardwareKey:(JuiceKeyMap)key down:(BOOL)down repeat:(BOOL)repeat fallback:(NSString *)fallback
{
 if(!self.canvas.hwnd)
 {
  if(self.hardwareKeyEvents++<4)[self append:@"HARDWARE_KEY_REJECTED reason=no-window\n"];
  return;
 }
 if(!key.scanCode&&down&&fallback.length)
 {
  NSData *payload=[fallback dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
  JuiceMsg text={JUICE_MAGIC,MSG_TEXT,0,self.canvas.hwnd,0,0,0,0,0,0};
  BOOL delivered=[self broadcastMessage:&text payload:payload];
  if(self.hardwareKeyEvents++<12)[self append:[NSString stringWithFormat:@"HARDWARE_KEY_TEXT_FALLBACK utf16_units=%lu delivered=%d\n",(unsigned long)(payload.length/2),delivered]];
  return;
 }
 if(!key.scanCode)return;
 uint32_t flags=down?HARDWARE_KEY_DOWN:HARDWARE_KEY_UP;
 if(key.extended)flags|=HARDWARE_KEY_EXTENDED;
 if(repeat)flags|=HARDWARE_KEY_REPEAT;
 JuiceMsg message={JUICE_MAGIC,MSG_HARDWARE_KEY,0,self.canvas.hwnd,key.virtualKey,key.scanCode,0,0,0,flags};
 BOOL delivered=[self broadcastMessage:&message payload:nil];
 if(self.hardwareKeyEvents++<12)[self append:[NSString stringWithFormat:@"HARDWARE_KEY_SENT hwnd=0x%llx vk=0x%x scan=0x%x down=%d extended=%d delivered=%d\n",(unsigned long long)self.canvas.hwnd,key.virtualKey,key.scanCode,down,key.extended,delivered]];
}
-(void)writeGamepadConnected:(BOOL)connected gamepad:(GCExtendedGamepad *)gamepad
{
 struct juice_gamepad_shared_state *state=self.gamepadState;
 if(!state)return;
 uint32_t sequence=state->sequence;
 if(sequence&1)sequence++;
 state->sequence=sequence+1;
 __sync_synchronize();
 state->connected=connected;
 state->packet++;
 state->buttons=0;
 state->left_trigger=state->right_trigger=0;
 state->thumb_lx=state->thumb_ly=state->thumb_rx=state->thumb_ry=0;
 state->battery_level=UINT32_MAX;
 if(connected&&gamepad)
 {
  if(gamepad.dpad.up.isPressed)state->buttons|=0x0001;
  if(gamepad.dpad.down.isPressed)state->buttons|=0x0002;
  if(gamepad.dpad.left.isPressed)state->buttons|=0x0004;
  if(gamepad.dpad.right.isPressed)state->buttons|=0x0008;
  if(gamepad.buttonMenu.isPressed)state->buttons|=0x0010;
  if(gamepad.buttonOptions.isPressed)state->buttons|=0x0020;
  if(gamepad.leftThumbstickButton.isPressed)state->buttons|=0x0040;
  if(gamepad.rightThumbstickButton.isPressed)state->buttons|=0x0080;
  if(gamepad.leftShoulder.isPressed)state->buttons|=0x0100;
  if(gamepad.rightShoulder.isPressed)state->buttons|=0x0200;
  /* The Linux-hosted iOS linker does not provide clang's
   * __isPlatformVersionAtLeast helper. Probe the optional 14.5 controller
   * element dynamically, which also keeps the iOS 14.0 deployment target. */
  if([gamepad respondsToSelector:@selector(buttonHome)])
  {
   GCControllerButtonInput *homeButton=[gamepad valueForKey:@"buttonHome"];
   if(homeButton.isPressed)state->buttons|=0x0400;
  }
  if(gamepad.buttonA.isPressed)state->buttons|=0x1000;
  if(gamepad.buttonB.isPressed)state->buttons|=0x2000;
  if(gamepad.buttonX.isPressed)state->buttons|=0x4000;
  if(gamepad.buttonY.isPressed)state->buttons|=0x8000;
  state->left_trigger=JuiceControllerTrigger(gamepad.leftTrigger.value);
  state->right_trigger=JuiceControllerTrigger(gamepad.rightTrigger.value);
  state->thumb_lx=JuiceControllerAxis(gamepad.leftThumbstick.xAxis.value);
  state->thumb_ly=JuiceControllerAxis(gamepad.leftThumbstick.yAxis.value);
  state->thumb_rx=JuiceControllerAxis(gamepad.rightThumbstick.xAxis.value);
  state->thumb_ry=JuiceControllerAxis(gamepad.rightThumbstick.yAxis.value);
 }
 state->timestamp_ns=(uint64_t)(CACurrentMediaTime()*1000000000.0);
 __sync_synchronize();
 state->sequence=sequence+2;
}
-(void)attachGameController:(GCController *)controller
{
 if(self.activeGameController||!controller.extendedGamepad)return;
 self.activeGameController=controller;
 controller.handlerQueue=dispatch_get_main_queue();
 __weak typeof(self) weakSelf=self;
 controller.extendedGamepad.valueChangedHandler=^(GCExtendedGamepad *gamepad,__unused GCControllerElement *element){[weakSelf writeGamepadConnected:YES gamepad:gamepad];};
 [self writeGamepadConnected:YES gamepad:controller.extendedGamepad];
 [self append:[NSString stringWithFormat:@"GAME_CONTROLLER_CONNECTED profile=xinput-v1 vendor=%@\n",controller.vendorName?:@"unknown"]];
}
-(void)controllerConnected:(NSNotification *)notification
{dispatch_async(dispatch_get_main_queue(),^{[self attachGameController:notification.object];});}
-(void)controllerDisconnected:(NSNotification *)notification
{
 dispatch_async(dispatch_get_main_queue(),^{
  if(notification.object!=self.activeGameController)return;
  self.activeGameController.extendedGamepad.valueChangedHandler=nil;
  self.activeGameController=nil;
  [self writeGamepadConnected:NO gamepad:nil];
  [self append:@"GAME_CONTROLLER_DISCONNECTED profile=xinput-v1\n"];
 });
}
-(void)setupExternalInput
{
 NSString *path=[JuiceDataRoot() stringByAppendingPathComponent:@"controller-v1.bin"];
 self.gamepadFD=open(path.fileSystemRepresentation,O_RDWR|O_CREAT,0600);
 if(self.gamepadFD<0||ftruncate(self.gamepadFD,JUICE_GAMEPAD_SHARED_SIZE)<0)
 {
  if(self.gamepadFD>=0){close(self.gamepadFD);self.gamepadFD=-1;}
  [self append:[NSString stringWithFormat:@"EXTERNAL_INPUT_ERROR state=%@ errno=%d\n",path,errno]];
  return;
 }
 void *mapping=mmap(NULL,JUICE_GAMEPAD_SHARED_SIZE,PROT_READ|PROT_WRITE,MAP_SHARED,self.gamepadFD,0);
 if(mapping==MAP_FAILED)
 {
  close(self.gamepadFD);self.gamepadFD=-1;
  [self append:[NSString stringWithFormat:@"EXTERNAL_INPUT_ERROR mmap errno=%d\n",errno]];
  return;
 }
 self.gamepadState=mapping;
 memset(self.gamepadState,0,JUICE_GAMEPAD_SHARED_SIZE);
 self.gamepadState->magic=JUICE_GAMEPAD_MAGIC;
 self.gamepadState->version=JUICE_GAMEPAD_VERSION;
 self.gamepadState->size=JUICE_GAMEPAD_SHARED_SIZE;
 self.gamepadState->sequence=2;
 self.gamepadState->battery_level=UINT32_MAX;
 [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerConnected:) name:GCControllerDidConnectNotification object:nil];
 [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerDisconnected:) name:GCControllerDidDisconnectNotification object:nil];
 for(GCController *controller in GCController.controllers){if(controller.extendedGamepad){[self attachGameController:controller];break;}}
 [self append:[NSString stringWithFormat:@"EXTERNAL_INPUT_READY keyboard=hardware gamecontroller=xinput-v1 state=%@\n",path]];
}
-(BOOL)sendMessage:(JuiceMsg *)message payload:(NSData *)payload toFD:(int)fd
{
 message->size=(uint32_t)payload.length;
 if(fd<0)return NO;
 @synchronized(self.clients)
 {
  if(![self.clients containsObject:@(fd)]||!WriteAll(fd,message,sizeof(*message)))return NO;
  if(payload.length&&!WriteAll(fd,payload.bytes,payload.length))return NO;
 }
 return YES;
}
-(void)handleCanvasInput:(JuiceMsg)message
{
 if(!self.experimentalMultiWindow)
 {
  [self broadcast:&message size:sizeof(message)];
  return;
 }
 BOOL down=(message.flags&(INPUT_LEFT_DOWN|INPUT_RIGHT_DOWN))!=0;
 BOOL up=(message.flags&(INPUT_LEFT_UP|INPUT_RIGHT_UP))!=0;
 WineWindowState *target=nil;
 if(!down&&self.inputClient>=0&&self.inputHwnd)
  target=[self windowStateForHwnd:self.inputHwnd create:NO client:-1];
 if(!target)target=[self topWindowAtPoint:CGPointMake(message.x,message.y)];
 if(!target)return;
 if(down){self.inputHwnd=target.hwnd;self.inputClient=target.clientFD;}
 CGRect rect=target.frame;
 message.hwnd=target.hwnd;
 message.x=(int32_t)MAX(0,message.x-(int32_t)rect.origin.x);
 message.y=(int32_t)MAX(0,message.y-(int32_t)rect.origin.y);
 if(rect.size.width>0)message.x=MIN(message.x,(int32_t)rect.size.width-1);
 if(rect.size.height>0)message.y=MIN(message.y,(int32_t)rect.size.height-1);
 self.canvas.hwnd=target.hwnd;
 self.activeClient=target.clientFD;
 [self sendMessage:&message payload:nil toFD:target.clientFD];
 if(up){self.inputHwnd=0;self.inputClient=-1;}
}
-(BOOL)broadcastMessage:(JuiceMsg *)message payload:(NSData *)payload
{
 return [self sendMessage:message payload:payload toFD:self.activeClient];
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
 self.socketPath=[JuiceDocumentsRoot() stringByAppendingPathComponent:@"j.sock"];unlink(self.socketPath.fileSystemRepresentation);self.listenFD=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un a={0};a.sun_family=AF_UNIX;strncpy(a.sun_path,self.socketPath.fileSystemRepresentation,sizeof(a.sun_path)-1);int br=bind(self.listenFD,(void *)&a,sizeof(a));int lr=br?-1:listen(self.listenFD,8);[self append:[NSString stringWithFormat:@"DISPLAY_SOCKET path=%@ bind=%d listen=%d errno=%d\n",self.socketPath,br,lr,errno]];
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
 self.controlSocketPath=[JuiceDocumentsRoot() stringByAppendingPathComponent:@"jc1.sock"];
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
 NSString *imports=[JuiceDataRoot() stringByAppendingPathComponent:@"Imported"];
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
  if(!self.experimentalX64)
  {
   [self append:@"EXPERIMENTAL_X86_64_LAUNCH_REJECTED reason=disabled\n"];
   UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Experimental x86-64 is disabled"
    message:@"Open Experimental and enable x86-64 / FEX translation to launch this application."
    preferredStyle:UIAlertControllerStyleAlert];
   [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
   [self presentViewController:alert animated:YES completion:nil];
   return;
  }
  self.x64Switch.on=YES;
  self.exeField.text=path;
  self.argsField.text=@"";
  [self launchRequested];
 }
 else if(action==JUICE_CONTROL_ACTION_IMPORT_ZIP)
  [self importPortableZipFromLocalPath:path];
}
-(UIImage *)imageFromBGRA:(NSData *)data width:(int)width height:(int)height stride:(uint32_t)stride
{
 CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
 CGColorSpaceRef colorSpace=CGColorSpaceCreateDeviceRGB();
 CGImageRef cgImage=CGImageCreate(width,height,8,32,stride,colorSpace,
  kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,false,
  kCGRenderingIntentDefault);
 UIImage *image=cgImage?[UIImage imageWithCGImage:cgImage scale:1 orientation:UIImageOrientationUp]:nil;
 if(cgImage)CGImageRelease(cgImage);
 CGColorSpaceRelease(colorSpace);
 CGDataProviderRelease(provider);
 return image;
}
-(void)presentFrameMessage:(JuiceMsg)message data:(NSData *)data client:(int)fd peerPID:(pid_t)peerPID first:(BOOL)first
{
 UIImage *image=[self imageFromBGRA:data width:message.width height:message.height stride:message.stride];
 if(!image)return;
 WineWindowState *state=[self windowStateForHwnd:message.hwnd create:YES client:fd];
 if(state.frame.size.width<=0||state.frame.size.height<=0)
  state.frame=CGRectMake(0,0,message.width,message.height);
 state.image=image;
 self.lastLegacyImage=image;
 self.lastLegacyHwnd=message.hwnd;
 self.lastLegacyClient=fd;
 if(self.experimentalMultiWindow)[self compositeWineDesktop];
 else
 {
  self.canvas.image=image;
  self.canvas.hwnd=message.hwnd;
  self.activeClient=fd;
 }
 if(first)
 {
  NSString *path=[JuiceDocumentsRoot() stringByAppendingPathComponent:
   [NSString stringWithFormat:@"Juice-frame-%d.png",peerPID]];
  [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
  [self append:[NSString stringWithFormat:@"JUICE_GUI_FRAME_RECEIVED pid=%d hwnd=0x%llx frame=%dx%d path=%@\n",
   peerPID,(unsigned long long)message.hwnd,message.width,message.height,path]];
 }
}
-(void)readClient:(int)fd
{
 JuiceMsg message;
 pid_t peerPID=0;
 NSUInteger frameCount=0;
 while(ReadAll(fd,&message,sizeof(message))&&message.magic==JUICE_MAGIC)
 {
  NSMutableData *data=nil;
  if(message.size)
  {
   data=[NSMutableData dataWithLength:message.size];
   if(!ReadAll(fd,data.mutableBytes,message.size))break;
  }
  if(message.type==MSG_HELLO)
  {
   peerPID=(pid_t)message.flags;
   [self append:[NSString stringWithFormat:@"DISPLAY_EVENT HELLO fd=%d pid=%d desktop=%dx%d dpi=%u\n",
    fd,peerPID,message.width,message.height,message.stride]];
   if(message.width>0&&message.height>0)
    dispatch_async(dispatch_get_main_queue(),^{self.wineDesktopSize=CGSizeMake(message.width,message.height);});
  }
  else if(message.type==MSG_WINDOW)
  {
   [self append:[NSString stringWithFormat:@"DISPLAY_EVENT WINDOW pid=%d hwnd=0x%llx rect=%d,%d %dx%d visible=%u\n",
    peerPID,(unsigned long long)message.hwnd,message.x,message.y,message.width,message.height,message.flags]];
   dispatch_async(dispatch_get_main_queue(),^{[self updateWindowMessage:message client:fd];});
  }
  else if(message.type==MSG_DESTROY)
  {
   [self append:[NSString stringWithFormat:@"DISPLAY_EVENT DESTROY pid=%d hwnd=0x%llx\n",
    peerPID,(unsigned long long)message.hwnd]];
   dispatch_async(dispatch_get_main_queue(),^{[self destroyWindowHwnd:message.hwnd];});
  }
  else if(message.type==MSG_FRAME&&data)
  {
   size_t expected=(size_t)message.stride*(size_t)message.height;
   if(expected<=data.length&&message.width>0&&message.height>0)
   {
    NSData *copy=[data copy];
    BOOL first=(frameCount++==0);
    if(frameCount<=3)
     [self append:[NSString stringWithFormat:@"DISPLAY_EVENT FRAME pid=%d hwnd=0x%llx size=%dx%d stride=%u bytes=%u count=%lu\n",
      peerPID,(unsigned long long)message.hwnd,message.width,message.height,message.stride,message.size,(unsigned long)frameCount]];
    dispatch_async(dispatch_get_main_queue(),^{[self presentFrameMessage:message data:copy client:fd peerPID:peerPID first:first];});
   }
  }
 }
 [self append:[NSString stringWithFormat:@"DISPLAY_CLIENT_CLOSED fd=%d pid=%d\n",fd,peerPID]];
 close(fd);
 @synchronized(self.clients)
 {
  [self.clients removeObject:@(fd)];
  if(self.activeClient==fd)self.activeClient=-1;
 }
 dispatch_async(dispatch_get_main_queue(),^{[self removeWindowsForClient:fd];});
}
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
 if(experimental&&!self.experimentalX64)
 {
  [self rejectLaunch:@"This is an x86_64/ARM64EC app. Open Experimental and enable x86-64 / FEX translation."];
  return;
 }
 NSString *runtimeName=experimental?@"Grape-X64":@"Grape";
 NSString *runtime=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:runtimeName];
 NSString *loaderPath=[runtime stringByAppendingPathComponent:@"build/wine-ios/loader/wine"];
 if(![NSFileManager.defaultManager fileExistsAtPath:loaderPath])
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
  NSString *imports=[JuiceDataRoot() stringByAppendingPathComponent:@"Imported"];
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
 NSString *imports=[JuiceDataRoot() stringByAppendingPathComponent:@"Imported"];
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
 NSString *base=JuiceDataRoot();
 self.prefix=[base stringByAppendingPathComponent:prefixName];
 NSFileManager *f=NSFileManager.defaultManager;
 [f createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
 NSString *ready=[self.prefix stringByAppendingPathComponent:@".juice-prefix-ready"];
 self.prefixNeedsInitialization=![f fileExistsAtPath:ready];
 if(![f fileExistsAtPath:[self.prefix stringByAppendingPathComponent:@"system.reg"]])
  [f copyItemAtPath:[self.grape stringByAppendingPathComponent:@"prefix-template"] toPath:self.prefix error:nil];
 NSString *dos=[self.prefix stringByAppendingPathComponent:@"dosdevices"];
 [f createDirectoryAtPath:dos withIntermediateDirectories:YES attributes:nil error:nil];
 NSString *c=[dos stringByAppendingPathComponent:@"c:"];
 NSString *z=[dos stringByAppendingPathComponent:@"z:"];
 NSString *cTarget=[f destinationOfSymbolicLinkAtPath:c error:nil];
 NSString *zTarget=[f destinationOfSymbolicLinkAtPath:z error:nil];
 NSError *cError=nil,*zError=nil;
 if(![cTarget isEqualToString:@"../drive_c"])
 {
  [f removeItemAtPath:c error:nil];
  [f createSymbolicLinkAtPath:c withDestinationPath:@"../drive_c" error:&cError];
 }
 if(![zTarget isEqualToString:@"/"])
 {
  [f removeItemAtPath:z error:nil];
  [f createSymbolicLinkAtPath:z withDestinationPath:@"/" error:&zError];
 }
 [self append:[NSString stringWithFormat:@"PREFIX_DRIVE_LINKS c=%d z=%d c_error=%@ z_error=%@\n",
  [[f destinationOfSymbolicLinkAtPath:c error:nil] isEqualToString:@"../drive_c"],
  [[f destinationOfSymbolicLinkAtPath:z error:nil] isEqualToString:@"/"],
  cError.localizedDescription?:@"none",zError.localizedDescription?:@"none"]];
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
                    [name caseInsensitiveCompare:@"JuiceInputSmoke.exe"]==NSOrderedSame||
                    [name caseInsensitiveCompare:@"JuiceTextSmoke.exe"]==NSOrderedSame||
                    [name caseInsensitiveCompare:@"winemine.exe"]==NSOrderedSame||
                    [name caseInsensitiveCompare:@"x86_64-smoke.exe"]==NSOrderedSame;
  if([f destinationOfSymbolicLinkAtPath:destination error:nil])
   [f removeItemAtPath:destination error:nil];
  if(self.prefixNeedsInitialization)continue;
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
  @"WINELOADERNOEXEC=1",
  [@"WINESERVER=" stringByAppendingString:[b stringByAppendingPathComponent:@"server/wineserver"]],
  [@"WINEDLLPATH=" stringByAppendingString:[NSString stringWithFormat:@"%@:%@:%@:%@:%@:%@:%@:%@",pe,[JuiceDataRoot() stringByAppendingPathComponent:@"native"],[b stringByAppendingPathComponent:@"dlls/crypt32"],[b stringByAppendingPathComponent:@"dlls/secur32"],[b stringByAppendingPathComponent:@"dlls/wineios.drv"],[b stringByAppendingPathComponent:@"dlls/winevulkan"],[b stringByAppendingPathComponent:@"dlls/win32u"],[b stringByAppendingPathComponent:@"dlls/ws2_32"]]],
  @"DYLD_LIBRARY_PATH=/var/jb/usr/lib",
  [@"JUICE_IOS_SOCKET=" stringByAppendingString:self.socketPath],
  [@"JUICE_IOS_CONTROL_SOCKET=" stringByAppendingString:self.controlSocketPath],
  [@"JUICE_GAMEPAD_STATE=" stringByAppendingString:JuiceWindowsPath([JuiceDataRoot() stringByAppendingPathComponent:@"controller-v1.bin"])],
  [@"JUICE_DATA_ROOT=" stringByAppendingString:JuiceDataRoot()],
  [@"JUICE_WINESERVER_ROOT=" stringByAppendingString:[JuiceDataRoot() stringByAppendingPathComponent:@"wineserver"]],
  [NSString stringWithFormat:@"JUICE_SKIP_WINEBOOT=%d",self.winebootSwitch.on&&!self.prefixNeedsInitialization],
  [@"WINEDEBUG=" stringByAppendingString:(self.debugField.text.length?self.debugField.text:@"-all")],
  @"WINE_D3D_CONFIG=renderer=vulkan",
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
-(void)dealloc{[NSNotificationCenter.defaultCenter removeObserver:self];[self stopTapped];if(self.gamepadState){[self writeGamepadConnected:NO gamepad:nil];munmap(self.gamepadState,JUICE_GAMEPAD_SHARED_SIZE);self.gamepadState=NULL;}if(self.gamepadFD>=0)close(self.gamepadFD);if(self.listenFD>=0)close(self.listenFD);if(self.controlListenFD>=0)close(self.controlListenFD);if(self.controlPickerFD>=0)close(self.controlPickerFD);unlink(self.socketPath.fileSystemRepresentation);unlink(self.controlSocketPath.fileSystemRepresentation);}
@end
@interface AppDelegate:UIResponder<UIApplicationDelegate>@property(nonatomic,strong)UIWindow *window;@end
@implementation AppDelegate
-(BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o{self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[JuiceController new];[self.window makeKeyAndVisible];return YES;}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class));}}
