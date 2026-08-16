#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

/*
 * Prefix health check for the UIKit launcher.
 *
 * Juice deliberately keeps the bundled prefix template small and lets the
 * first controlled Wineboot populate generated Windows state such as WinSxS
 * manifests. A prefix from an older/failed build can still have the Juice
 * ready marker even when that generated state is incomplete. In that case the
 * normal launcher would keep setting JUICE_SKIP_WINEBOOT=1 forever.
 *
 * Validate only generated state that Wine itself owns. If it is missing,
 * invalidate the ready marker before the controller prepares the prefix. The
 * existing initialization path then runs Wineboot normally and writes a fresh
 * ready marker only after Wine reports readiness.
 */

static IMP OriginalPreparePrefix;

static id JuiceValue(id self, NSString *key)
{
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceAppend(id self, NSString *text)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, text);
}

static BOOL JuiceDirectoryContainsManifest(NSString *directory)
{
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL isDirectory = NO;

    if (![files fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory)
        return NO;

    for (NSString *name in [files contentsOfDirectoryAtPath:directory error:nil] ?: @[])
        if ([name.pathExtension.lowercaseString isEqualToString:@"manifest"])
            return YES;
    return NO;
}

static NSString *JuicePrefixDataRoot(void)
{
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = paths.firstObject ?:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [documents stringByAppendingPathComponent:@"JuiceData"];
}

static void JuiceRepairPrefixIfNeeded(id self)
{
    BOOL usingX64 = [JuiceValue(self, @"usingX64") boolValue];
    NSString *prefixName = usingX64 ? @"GrapePrefix-x86_64" : @"GrapePrefix";
    NSString *prefix = [JuicePrefixDataRoot() stringByAppendingPathComponent:prefixName];
    NSString *ready = [prefix stringByAppendingPathComponent:@".juice-prefix-ready"];
    NSString *manifests = [prefix stringByAppendingPathComponent:@"drive_c/windows/winsxs/manifests"];
    NSFileManager *files = NSFileManager.defaultManager;

    if (![files fileExistsAtPath:ready]) return;
    if (JuiceDirectoryContainsManifest(manifests)) return;

    NSError *error = nil;
    if ([files removeItemAtPath:ready error:&error])
    {
        JuiceAppend(self, [NSString stringWithFormat:
            @"PREFIX_REPAIR_REQUIRED reason=missing-winsxs-manifests prefix=%@\n", prefix]);
    }
    else
    {
        JuiceAppend(self, [NSString stringWithFormat:
            @"PREFIX_REPAIR_MARKER_REMOVE_FAILED prefix=%@ error=%@\n",
            prefix, error.localizedDescription ?: @"unknown"]);
    }
}

static void JuicePreparePrefixWithRepair(id self, SEL _cmd)
{
    JuiceRepairPrefixIfNeeded(self);
    ((void (*)(id, SEL))OriginalPreparePrefix)(self, _cmd);
}

__attribute__((constructor))
static void JuiceInstallPrefixRepairHook(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    SEL selector = NSSelectorFromString(@"preparePrefix");
    Method method;

    if (!cls) return;
    method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    OriginalPreparePrefix = method_setImplementation(method, (IMP)JuicePreparePrefixWithRepair);
}
