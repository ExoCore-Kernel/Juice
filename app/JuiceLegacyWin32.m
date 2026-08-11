#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../wine/dlls/wineios.drv/control_protocol.h"

/*
 * Experimental Legacy Win32 support.
 *
 * Keep this isolated from the verified ARM64/x86-64 controller until the
 * WoW64/FEX path has had the same on-device proof pass.  The hooks below add
 * a third Experimental menu item and route PE32/i386 applications through the
 * existing translated Grape-X64 runtime with Wine's modern WoW64 layer and
 * FEX's libwow64fex.dll CPU backend.
 */

#define JUICE_PE_I386  0x014cu
#define JUICE_PE_AMD64 0x8664u

static NSString *const JuiceLegacyWin32DefaultsKey = @"JuiceExperimentalLegacyWin32";
static const void *JuiceLegacyDetectedKey = &JuiceLegacyDetectedKey;

static IMP OriginalRebuildExperimentalMenu;
static IMP OriginalMachineForExecutable;
static IMP OriginalNameForMachine;
static IMP OriginalEnvironment;
static IMP OriginalPreparePrefix;
static IMP OriginalLaunchRequested;
static IMP OriginalHandleControlAction;

static BOOL LegacyEnabled(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:JuiceLegacyWin32DefaultsKey];
}

static BOOL LegacyDetected(id self)
{
    return [objc_getAssociatedObject(self, JuiceLegacyDetectedKey) boolValue];
}

static void SetLegacyDetected(id self, BOOL detected)
{
    objc_setAssociatedObject(self, JuiceLegacyDetectedKey, @(detected), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id JuiceValue(id self, NSString *key)
{
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceSetValue(id self, NSString *key, id value)
{
    @try { [self setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceAppend(id self, NSString *text)
{
    SEL selector=NSSelectorFromString(@"append:");
    if([self respondsToSelector:selector])
        ((void (*)(id,SEL,id))objc_msgSend)(self,selector,text);
}

static void JuiceReject(id self, NSString *message)
{
    SEL selector=NSSelectorFromString(@"rejectLaunch:");
    if([self respondsToSelector:selector])
    {
        ((void (*)(id,SEL,id))objc_msgSend)(self,selector,message);
        return;
    }
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Cannot launch executable"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    if([self isKindOfClass:UIViewController.class])[(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

static NSString *JuiceCandidatePath(id self)
{
    SEL selector=NSSelectorFromString(@"candidateExePath");
    if(![self respondsToSelector:selector])return @"";
    id value=((id (*)(id,SEL))objc_msgSend)(self,selector);
    return [value isKindOfClass:NSString.class]?value:@"";
}

static NSString *JuiceUnixPath(id self, NSString *windowsPath)
{
    SEL selector=NSSelectorFromString(@"unixPathForWindowsPath:");
    if(![self respondsToSelector:selector])return windowsPath?:@"";
    id value=((id (*)(id,SEL,id))objc_msgSend)(self,selector,windowsPath?:@"");
    return [value isKindOfClass:NSString.class]?value:(windowsPath?:@"");
}

static uint16_t OriginalMachine(id self, NSString *path)
{
    if(!OriginalMachineForExecutable)return 0;
    return ((uint16_t (*)(id,SEL,id))OriginalMachineForExecutable)
        (self,NSSelectorFromString(@"machineForExecutableAtPath:"),path);
}

static BOOL LegacyRuntimeAvailable(id self)
{
    NSString *bundle=NSBundle.mainBundle.bundlePath;
    NSString *runtime=[bundle stringByAppendingPathComponent:@"Grape-X64/runtime/lib/wine"];
    NSString *cpu=[runtime stringByAppendingPathComponent:@"aarch64-windows/libwow64fex.dll"];
    NSString *ntdll=[runtime stringByAppendingPathComponent:@"i386-windows/ntdll.dll"];
    return [NSFileManager.defaultManager fileExistsAtPath:cpu]&&
           [NSFileManager.defaultManager fileExistsAtPath:ntdll];
}

static void LegacyRebuildExperimentalMenu(id self, SEL _cmd)
{
    ((void (*)(id,SEL))OriginalRebuildExperimentalMenu)(self,_cmd);
    UIButton *button=JuiceValue(self,@"experimentalButton");
    if(![button isKindOfClass:UIButton.class]||!button.menu)return;

    __weak id weakSelf=self;
    UIAction *legacy=[UIAction actionWithTitle:@"Legacy Win32 (x86 / 32-bit)" image:nil identifier:nil
        handler:^(__unused UIAction *action){
            id strongSelf=weakSelf;
            if(!strongSelf)return;
            BOOL enabled=!LegacyEnabled();
            [NSUserDefaults.standardUserDefaults setBool:enabled forKey:JuiceLegacyWin32DefaultsKey];
            JuiceAppend(strongSelf,[NSString stringWithFormat:@"EXPERIMENTAL_LEGACY_WIN32 enabled=%d\n",enabled]);
            SEL rebuild=NSSelectorFromString(@"rebuildExperimentalMenu");
            if([strongSelf respondsToSelector:rebuild])
                ((void (*)(id,SEL))objc_msgSend)(strongSelf,rebuild);
        }];
    legacy.discoverabilityTitle=@"Run 32-bit x86 Windows apps through Wine WoW64 + FEX";
    legacy.state=LegacyEnabled()?UIMenuElementStateOn:UIMenuElementStateOff;

    NSMutableArray<UIMenuElement *> *children=[button.menu.children mutableCopy]?:[NSMutableArray array];
    [children addObject:legacy];
    button.menu=[UIMenu menuWithTitle:button.menu.title children:children];
}

static uint16_t LegacyMachineForExecutable(id self, SEL _cmd, NSString *path)
{
    uint16_t machine=((uint16_t (*)(id,SEL,id))OriginalMachineForExecutable)(self,_cmd,path);
    if(machine==JUICE_PE_I386&&LegacyDetected(self)&&LegacyEnabled())
        return JUICE_PE_AMD64; /* Reuse the existing translated-runtime route. */
    return machine;
}

static NSString *LegacyNameForMachine(id self, SEL _cmd, uint16_t machine)
{
    if(LegacyDetected(self)&&machine==JUICE_PE_AMD64)
        return @"i386 (WoW64/FEX)";
    return ((id (*)(id,SEL,uint16_t))OriginalNameForMachine)(self,_cmd,machine);
}

static NSArray *LegacyEnvironment(id self, SEL _cmd)
{
    NSArray *base=((id (*)(id,SEL))OriginalEnvironment)(self,_cmd);
    if(!LegacyDetected(self)||!LegacyEnabled())return base;

    NSMutableArray<NSString *> *variables=[base mutableCopy]?:[NSMutableArray array];
    NSString *grape=JuiceValue(self,@"grape");
    NSString *i386=[grape stringByAppendingPathComponent:@"runtime/lib/wine/i386-windows"];

    BOOL hasHODLL=NO,hasMarker=NO;
    for(NSUInteger i=0;i<variables.count;i++)
    {
        NSString *entry=variables[i];
        if([entry hasPrefix:@"HODLL="]){variables[i]=@"HODLL=libwow64fex.dll";hasHODLL=YES;}
        else if([entry hasPrefix:@"JUICE_EXPERIMENTAL_WIN32="]){variables[i]=@"JUICE_EXPERIMENTAL_WIN32=1";hasMarker=YES;}
        else if(i386.length&&[entry hasPrefix:@"WINEDLLPATH="]&&[entry rangeOfString:i386].location==NSNotFound)
            variables[i]=[entry stringByAppendingFormat:@":%@",i386];
    }
    if(!hasHODLL)[variables addObject:@"HODLL=libwow64fex.dll"];
    if(!hasMarker)[variables addObject:@"JUICE_EXPERIMENTAL_WIN32=1"];
    return variables;
}

static void LegacyPreparePrefix(id self, SEL _cmd)
{
    ((void (*)(id,SEL))OriginalPreparePrefix)(self,_cmd);
    if(!LegacyDetected(self)||!LegacyEnabled())return;

    NSString *grape=JuiceValue(self,@"grape");
    NSString *prefix=JuiceValue(self,@"prefix");
    if(!grape.length||!prefix.length)return;

    NSFileManager *files=NSFileManager.defaultManager;
    NSString *source=[grape stringByAppendingPathComponent:@"runtime/lib/wine/i386-windows"];
    NSString *syswow64=[prefix stringByAppendingPathComponent:@"drive_c/windows/syswow64"];
    [files createDirectoryAtPath:syswow64 withIntermediateDirectories:YES attributes:nil error:nil];

    NSUInteger linked=0;
    for(NSString *name in [files contentsOfDirectoryAtPath:source error:nil]?:@[])
    {
        NSString *ext=name.pathExtension.lowercaseString;
        if(!([ext isEqualToString:@"dll"]||[ext isEqualToString:@"exe"]||[ext isEqualToString:@"drv"]))continue;
        NSString *from=[source stringByAppendingPathComponent:name];
        NSString *to=[syswow64 stringByAppendingPathComponent:name];
        if([files destinationOfSymbolicLinkAtPath:to error:nil])[files removeItemAtPath:to error:nil];
        if(![files fileExistsAtPath:to]&&[files createSymbolicLinkAtPath:to withDestinationPath:from error:nil])linked++;
    }
    JuiceAppend(self,[NSString stringWithFormat:@"LEGACY_WIN32_SYSWOW64_LINKS count=%lu path=%@\n",
                      (unsigned long)linked,syswow64]);
}

static void LegacyLaunchRequested(id self, SEL _cmd)
{
    NSString *path=JuiceCandidatePath(self);
    uint16_t machine=OriginalMachine(self,path);
    if(machine!=JUICE_PE_I386)
    {
        SetLegacyDetected(self,NO);
        ((void (*)(id,SEL))OriginalLaunchRequested)(self,_cmd);
        return;
    }

    SetLegacyDetected(self,YES);
    if(!LegacyEnabled())
    {
        JuiceReject(self,@"This is a 32-bit x86 Windows application. Open Experimental and enable Legacy Win32 (x86 / 32-bit) to run it through WoW64 + FEX.");
        return;
    }
    if(!LegacyRuntimeAvailable(self))
    {
        JuiceReject(self,@"Legacy Win32 is enabled, but this Juice build does not contain the WoW64/FEX runtime. Build the win32-components target and reassemble Grape-X64.");
        return;
    }

    BOOL oldX64=[JuiceValue(self,@"experimentalX64") boolValue];
    JuiceSetValue(self,@"experimentalX64",@YES);
    JuiceAppend(self,[NSString stringWithFormat:@"LEGACY_WIN32_ROUTE arch=i386 runtime=Grape-X64 hodll=libwow64fex.dll path=%@\n",path]);
    ((void (*)(id,SEL))OriginalLaunchRequested)(self,_cmd);
    JuiceSetValue(self,@"experimentalX64",@(oldX64));
}

static void LegacyHandleControlAction(id self, SEL _cmd, uint32_t action, NSString *windowsPath)
{
    if(action!=JUICE_CONTROL_ACTION_LAUNCH_PATH)
    {
        ((void (*)(id,SEL,uint32_t,id))OriginalHandleControlAction)(self,_cmd,action,windowsPath);
        return;
    }

    NSString *path=JuiceUnixPath(self,windowsPath);
    uint16_t machine=OriginalMachine(self,path);
    if(machine!=JUICE_PE_I386)
    {
        ((void (*)(id,SEL,uint32_t,id))OriginalHandleControlAction)(self,_cmd,action,windowsPath);
        return;
    }

    if(!LegacyEnabled())
    {
        JuiceReject(self,@"This launcher targets a 32-bit x86 Windows application. Enable Experimental → Legacy Win32 (x86 / 32-bit) first.");
        return;
    }

    BOOL oldX64=[JuiceValue(self,@"experimentalX64") boolValue];
    UISwitch *switchControl=JuiceValue(self,@"x64Switch");
    BOOL oldSwitch=[switchControl isKindOfClass:UISwitch.class]?switchControl.on:NO;
    JuiceSetValue(self,@"experimentalX64",@YES);
    ((void (*)(id,SEL,uint32_t,id))OriginalHandleControlAction)(self,_cmd,action,windowsPath);
    JuiceSetValue(self,@"experimentalX64",@(oldX64));
    if([switchControl isKindOfClass:UISwitch.class])switchControl.on=oldSwitch;
}

static void InstallHook(Class cls, SEL selector, IMP replacement, IMP *original)
{
    Method method=class_getInstanceMethod(cls,selector);
    if(!method)return;
    *original=method_setImplementation(method,replacement);
}

__attribute__((constructor))
static void JuiceInstallLegacyWin32Hooks(void)
{
    Class cls=NSClassFromString(@"JuiceController");
    if(!cls)return;
    InstallHook(cls,NSSelectorFromString(@"rebuildExperimentalMenu"),(IMP)LegacyRebuildExperimentalMenu,&OriginalRebuildExperimentalMenu);
    InstallHook(cls,NSSelectorFromString(@"machineForExecutableAtPath:"),(IMP)LegacyMachineForExecutable,&OriginalMachineForExecutable);
    InstallHook(cls,NSSelectorFromString(@"nameForMachine:"),(IMP)LegacyNameForMachine,&OriginalNameForMachine);
    InstallHook(cls,NSSelectorFromString(@"environment"),(IMP)LegacyEnvironment,&OriginalEnvironment);
    InstallHook(cls,NSSelectorFromString(@"preparePrefix"),(IMP)LegacyPreparePrefix,&OriginalPreparePrefix);
    InstallHook(cls,NSSelectorFromString(@"launchRequested"),(IMP)LegacyLaunchRequested,&OriginalLaunchRequested);
    InstallHook(cls,NSSelectorFromString(@"handleControlAction:path:"),(IMP)LegacyHandleControlAction,&OriginalHandleControlAction);
}
