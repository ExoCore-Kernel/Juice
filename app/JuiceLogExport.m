#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

/*
 * Keep log exporting isolated from the main controller implementation.  Juice's
 * main UI already owns a persistent log file containing both controller events
 * and the child Wine/FEX stdout+stderr stream.  This category installs one
 * button after the controller has built its form and shares a timestamped
 * snapshot through the normal iOS activity sheet.
 */
@interface JuiceController : UIViewController
@end

@interface JuiceController (JuiceLogExport)
- (void)juice_logExport_viewDidLoad;
- (void)juice_exportLogTapped:(UIButton *)sender;
@end

@implementation JuiceController (JuiceLogExport)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class controller = NSClassFromString(@"JuiceController");
        Method original = class_getInstanceMethod(controller, @selector(viewDidLoad));
        Method replacement = class_getInstanceMethod(controller, @selector(juice_logExport_viewDidLoad));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)juice_logExport_viewDidLoad
{
    /* Swizzled: this invokes JuiceController's original -viewDidLoad. */
    [self juice_logExport_viewDidLoad];

    id value = [self valueForKey:@"form"];
    if (![value isKindOfClass:UIStackView.class]) return;

    UIStackView *form = value;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Export Full Log" forState:UIControlStateNormal];
    button.accessibilityIdentifier = @"juice.export-log";
    [button addTarget:self action:@selector(juice_exportLogTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    [form addArrangedSubview:button];
}

- (void)juice_exportLogTapped:(UIButton *)sender
{
    NSString *source = nil;
    @try { source = [self valueForKey:@"persistentLogPath"]; }
    @catch (__unused NSException *exception) {}

    NSData *contents = source.length ? [NSData dataWithContentsOfFile:source] : nil;
    if (!contents.length)
    {
        id logView = nil;
        @try { logView = [self valueForKey:@"log"]; }
        @catch (__unused NSException *exception) {}
        if ([logView isKindOfClass:UITextView.class])
            contents = [[(UITextView *)logView text] dataUsingEncoding:NSUTF8StringEncoding];
    }

    if (!contents.length)
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No log to export"
         message:@"Juice has not recorded any log output yet."
         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
         style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [formatter stringFromDate:NSDate.date];
    NSString *directory = @"/var/mobile/Documents/Juice-Logs";
    NSString *destination = [directory stringByAppendingPathComponent:
     [NSString stringWithFormat:@"Juice-%@.txt", stamp]];

    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:directory
     withIntermediateDirectories:YES attributes:nil error:&error];
    if (!error && ![contents writeToFile:destination options:NSDataWritingAtomic error:&error]) {}

    if (error)
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Log export failed"
         message:error.localizedDescription ?: @"Juice could not create the log file."
         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
         style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:destination];
    UIActivityViewController *share = [[UIActivityViewController alloc]
     initWithActivityItems:@[url] applicationActivities:nil];
    UIPopoverPresentationController *popover = share.popoverPresentationController;
    if (popover)
    {
        popover.sourceView = sender ?: self.view;
        popover.sourceRect = sender ? sender.bounds : self.view.bounds;
    }
    [self presentViewController:share animated:YES completion:nil];

    SEL appendSelector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:appendSelector])
    {
        NSString *message = [NSString stringWithFormat:@"LOG_EXPORTED path=%@ bytes=%lu\n",
                             destination, (unsigned long)contents.length];
        ((void (*)(id, SEL, id))objc_msgSend)(self, appendSelector, message);
    }
}

@end
