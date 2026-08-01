#import <UIKit/UIKit.h>

#include <errno.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

static NSString *JuiceArchitecture(void)
{
#if defined(__aarch64__)
    return @"arm64";
#elif defined(__arm__)
    return @"arm";
#else
    return @"unknown";
#endif
}

static NSString *RunJuiceRuntimeTest(void)
{
    NSMutableString *output = [NSMutableString string];

    long pageSize = sysconf(_SC_PAGESIZE);
    size_t allocationSize = pageSize > 0 ? (size_t)pageSize : 16384;

    [output appendString:@"=== Juice Runtime 0.1 ===\n"];
    [output appendFormat:@"Architecture: %@\n", JuiceArchitecture()];
    [output appendFormat:@"Pointer size: %zu-bit\n", sizeof(void *) * 8];
    [output appendFormat:@"Page size: %ld bytes\n", pageSize];
    [output appendFormat:@"PID: %d\n", getpid()];
    [output appendFormat:@"UID: %d\n\n", getuid()];

    void *memory = mmap(
        NULL,
        allocationSize,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON,
        -1,
        0
    );

    if (memory == MAP_FAILED) {
        [output appendFormat:@"mmap: FAILED\n%s\n", strerror(errno)];
        return output;
    }

    [output appendFormat:@"RW allocation: %p\n", memory];

    memset(memory, 0x41, allocationSize);

    if (mprotect(memory, allocationSize, PROT_READ | PROT_EXEC) == 0) {
        [output appendString:@"RW → RX: SUCCESS\n"];
    } else {
        [output appendFormat:@"RW → RX: FAILED\n%s\n", strerror(errno)];
        munmap(memory, allocationSize);
        return output;
    }

    munmap(memory, allocationSize);

    [output appendString:@"Memory released: SUCCESS\n\n"];
    [output appendString:@"Juice native runtime is operational.\n"];

    return output;
}

@interface JuiceViewController : UIViewController
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) UITextView *consoleView;
@end

@implementation JuiceViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"Juice";
    self.titleLabel.font =
        [UIFont systemFontOfSize:38 weight:UIFontWeightBold];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Windows compatibility layer for iOS";
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.font = [UIFont systemFontOfSize:16];

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.runButton setTitle:@"Run Native Runtime Test"
                    forState:UIControlStateNormal];
    self.runButton.titleLabel.font =
        [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.runButton addTarget:self
                       action:@selector(runRuntimeTest)
             forControlEvents:UIControlEventTouchUpInside];

    self.consoleView = [[UITextView alloc] init];
    self.consoleView.translatesAutoresizingMaskIntoConstraints = NO;
    self.consoleView.editable = NO;
    self.consoleView.selectable = YES;
    self.consoleView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.consoleView.textColor = UIColor.labelColor;
    self.consoleView.font =
        [UIFont monospacedSystemFontOfSize:13
                                   weight:UIFontWeightRegular];
    self.consoleView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    self.consoleView.layer.cornerRadius = 14;
    self.consoleView.text =
        @"Juice is ready.\n\nPress the button to test the native runtime.";

    [self.view addSubview:self.titleLabel];
    [self.view addSubview:self.statusLabel];
    [self.view addSubview:self.runButton];
    [self.view addSubview:self.consoleView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:safe.topAnchor
                                                  constant:24],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                      constant:24],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                        constant:-24],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor
                                                   constant:4],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

        [self.runButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor
                                                  constant:20],
        [self.runButton.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],

        [self.consoleView.topAnchor constraintEqualToAnchor:self.runButton.bottomAnchor
                                                   constant:20],
        [self.consoleView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                       constant:24],
        [self.consoleView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                        constant:-24],
        [self.consoleView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                      constant:-24]
    ]];
}

- (void)runRuntimeTest
{
    self.runButton.enabled = NO;
    self.consoleView.text = @"Running Juice native runtime test…";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = RunJuiceRuntimeTest();

        dispatch_async(dispatch_get_main_queue(), ^{
            self.consoleView.text = result;
            self.runButton.enabled = YES;
        });
    });
}

@end

@interface JuiceAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation JuiceAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    (void)application;
    (void)launchOptions;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    JuiceViewController *controller =
        [[JuiceViewController alloc] init];

    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];

    return YES;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(
            argc,
            argv,
            nil,
            NSStringFromClass(JuiceAppDelegate.class)
        );
    }
}
