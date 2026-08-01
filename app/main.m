#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "JuiceZip.h"
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

static BOOL ReadAll(int fd,void *p,size_t n){char *b=p;while(n){ssize_t r=read(fd,b,n);if(r<=0)return NO;b+=r;n-=r;}return YES;}
static BOOL WriteAll(int fd,const void *p,size_t n){const char *b=p;while(n){ssize_t r=write(fd,b,n);if(r<=0)return NO;b+=r;n-=r;}return YES;}
static char **CopyStrings(NSArray<NSString *> *a){char **v=calloc(a.count+1,sizeof(char *));for(NSUInteger i=0;i<a.count;i++)v[i]=strdup(a[i].UTF8String);return v;}
static void FreeStrings(char **v){if(!v)return;for(size_t i=0;v[i];i++)free(v[i]);free(v);}

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
@property(nonatomic,strong) UIStackView *form;
@property(nonatomic,strong) UIButton *fullscreenButton;
@property(nonatomic,strong) NSLayoutConstraint *canvasHeightConstraint,*canvasBottomConstraint;
@property(nonatomic,copy) NSArray<NSLayoutConstraint *> *windowedConstraints;
@property(nonatomic) int listenFD,activeClient;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *clients;
@property(nonatomic,copy) NSString *socketPath,*grape,*prefix;
@property(nonatomic) pid_t child,server;
@property(nonatomic) int childInput;
@property(nonatomic) BOOL didAutoLaunch,reportedFrame,fullscreen;
@property(nonatomic,copy) NSString *persistentLogPath;
@end
@implementation JuiceController
-(void)viewDidLoad{[super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;self.clients=[NSMutableArray array];self.activeClient=-1;self.child=-1;self.server=-1;self.childInput=-1;self.persistentLogPath=@"/var/mobile/Documents/Juice-GUI-Headless.log";[@"JUICE_HEADLESS_TEST_BEGIN\n" writeToFile:self.persistentLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];[self buildUI];[self startDisplayServer];[self preparePrefix];[self append:@"GUI_READY\n"];}
-(void)viewDidAppear:(BOOL)animated{[super viewDidAppear:animated];if(!self.didAutoLaunch){self.didAutoLaunch=YES;[self append:@"AUTO_LAUNCH_WINEMINE\n"];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self launchTapped];});}}
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

 UIStackView *selectors=[[UIStackView alloc]initWithArrangedSubviews:@[self.mode,self.clickMode]];
 selectors.axis=UILayoutConstraintAxisHorizontal;
 selectors.distribution=UIStackViewDistributionFillEqually;
 selectors.spacing=5;
 UIStackView *launchers=[[UIStackView alloc]initWithArrangedSubviews:@[[self button:@"Launch" action:@selector(launchTapped)],[self button:@"Stop" action:@selector(stopTapped)]]];
 launchers.axis=UILayoutConstraintAxisHorizontal;
 launchers.distribution=UIStackViewDistributionFillEqually;
 UIStackView *textRow=[[UIStackView alloc]initWithArrangedSubviews:@[self.guiTextField,[self button:@"Send Text" action:@selector(sendGuiTextTapped)]]];
 textRow.axis=UILayoutConstraintAxisHorizontal;
 textRow.spacing=5;
 UIStackView *keyRow=[[UIStackView alloc]initWithArrangedSubviews:@[[self button:@"Backspace" action:@selector(sendBackspace)],[self button:@"Tab" action:@selector(sendTab)],[self button:@"Enter" action:@selector(sendEnter)]]];
 keyRow.axis=UILayoutConstraintAxisHorizontal;
 keyRow.distribution=UIStackViewDistributionFillEqually;

 self.form=[[UIStackView alloc]initWithArrangedSubviews:@[self.exeField,[self button:@"Choose EXE or Portable ZIP" action:@selector(chooseExeTapped)],self.argsField,self.debugField,selectors,launchers,textRow,keyRow,self.stdinField]];
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
-(void)readClient:(int)fd{JuiceMsg m;pid_t peerPID=0;NSUInteger frameCount=0;while(ReadAll(fd,&m,sizeof(m))&&m.magic==JUICE_MAGIC){NSMutableData *d=nil;if(m.size){d=[NSMutableData dataWithLength:m.size];if(!ReadAll(fd,d.mutableBytes,m.size))break;}if(m.type==MSG_HELLO){peerPID=(pid_t)m.flags;[self append:[NSString stringWithFormat:@"DISPLAY_EVENT HELLO fd=%d pid=%d desktop=%dx%d dpi=%u\n",fd,peerPID,m.width,m.height,m.stride]];}else if(m.type==MSG_WINDOW){[self append:[NSString stringWithFormat:@"DISPLAY_EVENT WINDOW pid=%d hwnd=0x%llx rect=%d,%d %dx%d visible=%u\n",peerPID,(unsigned long long)m.hwnd,m.x,m.y,m.width,m.height,m.flags]];}else if(m.type==MSG_FRAME&&d){size_t expected=(size_t)m.stride*(size_t)m.height;if(expected<=d.length&&m.width>0&&m.height>0){NSData *copy=[d copy];BOOL first=(frameCount++==0);if(frameCount<=3)[self append:[NSString stringWithFormat:@"DISPLAY_EVENT FRAME pid=%d hwnd=0x%llx size=%dx%d stride=%u bytes=%u count=%lu\n",peerPID,(unsigned long long)m.hwnd,m.width,m.height,m.stride,m.size,(unsigned long)frameCount]];dispatch_async(dispatch_get_main_queue(),^{CGDataProviderRef p=CGDataProviderCreateWithCFData((__bridge CFDataRef)copy);CGColorSpaceRef c=CGColorSpaceCreateDeviceRGB();CGImageRef im=CGImageCreate(m.width,m.height,8,32,m.stride,c,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,p,NULL,false,kCGRenderingIntentDefault);UIImage *image=[UIImage imageWithCGImage:im scale:1 orientation:UIImageOrientationUp];self.canvas.image=image;self.canvas.hwnd=m.hwnd;self.activeClient=fd;if(first){NSString *path=[NSString stringWithFormat:@"/var/mobile/Documents/Juice-frame-%d.png",peerPID];[UIImagePNGRepresentation(image) writeToFile:path atomically:YES];[self append:[NSString stringWithFormat:@"JUICE_GUI_FRAME_RECEIVED pid=%d hwnd=0x%llx frame=%dx%d path=%@\n",peerPID,(unsigned long long)m.hwnd,m.width,m.height,path]];}CGImageRelease(im);CGColorSpaceRelease(c);CGDataProviderRelease(p);});}}}[self append:[NSString stringWithFormat:@"DISPLAY_CLIENT_CLOSED fd=%d pid=%d\n",fd,peerPID]];close(fd);@synchronized(self.clients){[self.clients removeObject:@(fd)];if(self.activeClient==fd)self.activeClient=-1;}}
-(void)broadcast:(const void *)p size:(size_t)n{int fd=self.activeClient;if(fd<0)return;@synchronized(self.clients){if([self.clients containsObject:@(fd)])WriteAll(fd,p,n);}}
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
 dispatch_async(dispatch_get_main_queue(),^{[self launchTapped];});
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
-(void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller{[self append:@"CUSTOM_EXE_PICKER_CANCELLED\n"];}
-(void)preparePrefix{self.grape=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Grape"];NSString *base=@"/var/mobile/Documents/JuiceData";self.prefix=[base stringByAppendingPathComponent:@"GrapePrefix"];NSFileManager *f=NSFileManager.defaultManager;[f createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];if(![f fileExistsAtPath:[self.prefix stringByAppendingPathComponent:@"system.reg"]]){[f copyItemAtPath:[self.grape stringByAppendingPathComponent:@"prefix-template"] toPath:self.prefix error:nil];}NSString *dos=[self.prefix stringByAppendingPathComponent:@"dosdevices"];[f createDirectoryAtPath:dos withIntermediateDirectories:YES attributes:nil error:nil];NSString *z=[dos stringByAppendingPathComponent:@"z:"];[f removeItemAtPath:z error:nil];[f createSymbolicLinkAtPath:z withDestinationPath:@"/" error:nil];NSString *user=[self.prefix stringByAppendingPathComponent:@"user.reg"];NSMutableString *reg=[NSMutableString stringWithContentsOfFile:user encoding:NSUTF8StringEncoding error:nil];if(reg&&[reg rangeOfString:@"\"Graphics\"=\"ios\""].location==NSNotFound){[reg appendString:@"\n[Software\\\\Wine\\\\Drivers] 1770000000\n#time=1dc790000000000\n\"Graphics\"=\"ios\"\n"];[reg writeToFile:user atomically:YES encoding:NSUTF8StringEncoding error:nil];}}
-(NSArray *)environment{NSString *b=[self.grape stringByAppendingPathComponent:@"build/wine-ios"],*pe=[self.grape stringByAppendingPathComponent:@"runtime/lib/wine/aarch64-windows"];return @[[@"HOME=" stringByAppendingString:NSHomeDirectory()],[ @"TMPDIR=" stringByAppendingString:NSTemporaryDirectory()],[@"WINEPREFIX=" stringByAppendingString:self.prefix],[@"WINELOADER=" stringByAppendingString:[self.grape stringByAppendingPathComponent:@"tools/grape-nested-wrapper"]],[@"WINESERVER=" stringByAppendingString:[b stringByAppendingPathComponent:@"server/wineserver"]],[@"WINEDLLPATH=" stringByAppendingString:[NSString stringWithFormat:@"%@:/var/mobile/Documents/JuiceData/native:%@:%@:%@",pe,[b stringByAppendingPathComponent:@"dlls/wineios.drv"],[b stringByAppendingPathComponent:@"dlls/win32u"],[b stringByAppendingPathComponent:@"dlls/ws2_32"]]],[@"DYLD_LIBRARY_PATH=" stringByAppendingString:@"/var/jb/usr/lib"],[@"JUICE_IOS_SOCKET=" stringByAppendingString:self.socketPath],[@"WINEDEBUG=" stringByAppendingString:(self.debugField.text.length?self.debugField.text:@"-all")],@"WINEARCH=win64",@"PATH=/usr/bin:/bin",@"LANG=C"];
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
-(void)dealloc{[self stopTapped];if(self.listenFD>=0)close(self.listenFD);unlink(self.socketPath.fileSystemRepresentation);}
@end
@interface AppDelegate:UIResponder<UIApplicationDelegate>@property(nonatomic,strong)UIWindow *window;@end
@implementation AppDelegate
-(BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o{self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[JuiceController new];[self.window makeKeyAndVisible];return YES;}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class));}}
