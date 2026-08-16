#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface JuiceController : UIViewController
@end

@implementation JuiceController (JuiceSmokePath)

+ (void)load
{
    Class cls = NSClassFromString(@"JuiceController");
    Method original = class_getInstanceMethod(cls, NSSelectorFromString(@"candidateExePath"));
    Method replacement = class_getInstanceMethod(cls, @selector(juice_candidateExePath));
    if (original && replacement) method_exchangeImplementations(original, replacement);
}

- (NSString *)juice_candidateExePath
{
    NSString *resolved = [self juice_candidateExePath];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (resolved.length && [fm fileExistsAtPath:resolved]) return resolved;

    UITextField *field = nil;
    @try { field = [self valueForKey:@"exeField"]; }
    @catch (__unused NSException *exception) { return resolved; }

    NSString *name = [field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || [name containsString:@"/"]) return resolved;

    BOOL x64 = NO;
    @try { x64 = [[self valueForKey:@"experimentalX64"] boolValue]; }
    @catch (__unused NSException *exception) {}

    NSArray<NSString *> *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *sandboxDocuments = documents.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *sandboxSmoke = [sandboxDocuments stringByAppendingPathComponent:@"JuiceData/SmokeTests"];
    NSString *sharedSmoke = @"/var/mobile/Documents/JuiceData/SmokeTests";
    NSArray<NSString *> *architectures = x64 ? @[@"graphics-x86_64", @"graphics-arm64"]
                                              : @[@"graphics-arm64", @"graphics-x86_64"];

    for (NSString *root in @[sandboxSmoke, sharedSmoke])
    {
        for (NSString *architecture in architectures)
        {
            NSString *candidate = [[root stringByAppendingPathComponent:architecture] stringByAppendingPathComponent:name];
            if ([fm isExecutableFileAtPath:candidate] || [fm fileExistsAtPath:candidate]) return candidate;
        }

        NSString *candidate = [root stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:candidate] || [fm fileExistsAtPath:candidate]) return candidate;
    }

    return resolved;
}

@end
