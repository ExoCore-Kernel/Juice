#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface JuiceController : NSObject
@end

static void (*OriginalPreparePrefixForApiSet)(id, SEL);

static NSString *JuiceStringValue(id object, NSString *key)
{
    @try
    {
        id value = [object valueForKey:key];
        return [value isKindOfClass:NSString.class] ? value : nil;
    }
    @catch (__unused NSException *exception)
    {
        return nil;
    }
}

static void JuiceAppendApiSetLog(id self, NSString *line)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, line);
}

static void JuiceEnsureApiSetSchema(id self)
{
    NSString *grape = JuiceStringValue(self, @"grape");
    NSString *prefix = JuiceStringValue(self, @"prefix");
    if (!grape.length || !prefix.length) return;

    NSFileManager *files = NSFileManager.defaultManager;
    NSString *source = [grape stringByAppendingPathComponent:
                        @"runtime/lib/wine/aarch64-windows/apisetschema.dll"];
    if (![files fileExistsAtPath:source])
    {
        JuiceAppendApiSetLog(self,
            [NSString stringWithFormat:@"PREFIX_APISET_MISSING source=%@\n", source]);
        return;
    }

    NSString *system32 = [prefix stringByAppendingPathComponent:@"drive_c/windows/system32"];
    NSString *destination = [system32 stringByAppendingPathComponent:@"apisetschema.dll"];
    [files createDirectoryAtPath:system32 withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *currentTarget = [files destinationOfSymbolicLinkAtPath:destination error:nil];
    if ([currentTarget isEqualToString:source])
    {
        JuiceAppendApiSetLog(self,
            [NSString stringWithFormat:@"PREFIX_APISET_READY path=%@ existing=1\n", destination]);
        return;
    }

    if (currentTarget || [files fileExistsAtPath:destination])
        [files removeItemAtPath:destination error:nil];

    NSError *error = nil;
    BOOL linked = [files createSymbolicLinkAtPath:destination withDestinationPath:source error:&error];
    if (linked)
        JuiceAppendApiSetLog(self,
            [NSString stringWithFormat:@"PREFIX_APISET_READY path=%@ existing=0\n", destination]);
    else
        JuiceAppendApiSetLog(self,
            [NSString stringWithFormat:@"PREFIX_APISET_ERROR path=%@ error=%@\n",
             destination, error.localizedDescription ?: @"unknown"]);
}

static void JuicePreparePrefixWithApiSet(id self, SEL _cmd)
{
    if (OriginalPreparePrefixForApiSet)
        OriginalPreparePrefixForApiSet(self, _cmd);

    /* preparePrefix normally skips runtime symlinks while the prefix still
       needs wineboot. apisetschema.dll is special: ntdll loads this data-only
       module before wineboot can finish, so it must exist in system32 on the
       very first process launch, not only on the second launch. */
    JuiceEnsureApiSetSchema(self);
}

__attribute__((constructor))
static void JuiceInstallApiSetBootstrap(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method method = class_getInstanceMethod(cls, NSSelectorFromString(@"preparePrefix"));
    if (!method) return;

    OriginalPreparePrefixForApiSet = (void (*)(id, SEL))
        method_setImplementation(method, (IMP)JuicePreparePrefixWithApiSet);
}
