#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define JUICE_MAGIC 0x4a554943u

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceMsg;

@interface JuiceController : UIViewController
@end

@interface JuiceBootOverlayView : UIView
@property(nonatomic,strong) UIImageView *iconView;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *detailLabel;
@property(nonatomic,strong) UIProgressView *progressView;
@end

@implementation JuiceBootOverlayView

- (instancetype)init
{
    if ((self = [super init]))
    {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor colorWithRed:0.07 green:0.025 blue:0.11 alpha:1.0];

        _iconView = [UIImageView new];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.image = [UIImage imageNamed:@"AppIcon1024x1024"];
        _iconView.layer.cornerRadius = 22.0;
        _iconView.clipsToBounds = YES;

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.text = @"Starting Wine";
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightSemibold];

        _detailLabel = [UILabel new];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.textAlignment = NSTextAlignmentCenter;
        _detailLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
        _detailLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
        _detailLabel.numberOfLines = 2;

        _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progressView.translatesAutoresizingMaskIntoConstraints = NO;
        _progressView.progressTintColor = UIColor.whiteColor;
        _progressView.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.22];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
            _iconView, _titleLabel, _detailLabel, _progressView
        ]];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentFill;
        stack.spacing = 14.0;
        [self addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [_iconView.widthAnchor constraintEqualToConstant:112.0],
            [_iconView.heightAnchor constraintEqualToConstant:112.0],
            [_iconView.centerXAnchor constraintEqualToAnchor:stack.centerXAnchor],
            [_progressView.widthAnchor constraintEqualToConstant:300.0],
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:28.0],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-28.0]
        ]];
    }
    return self;
}
@end

static void (*OriginalLaunchRequested)(id, SEL);
static void (*OriginalAppend)(id, SEL, NSString *);
static void (*OriginalPresentFrame)(id, SEL, JuiceMsg, NSData *, int, pid_t, BOOL);

static char JuiceBootOverlayKey;
static char JuiceBootActiveKey;
static char JuiceBootProgressKey;
static char JuiceBootTargetFDKey;
static char JuiceBootGenerationKey;

static id JuiceValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL JuiceBootIsActive(id self)
{
    return [objc_getAssociatedObject(self, &JuiceBootActiveKey) boolValue];
}

static NSUInteger JuiceBootGeneration(id self)
{
    return [objc_getAssociatedObject(self, &JuiceBootGenerationKey) unsignedIntegerValue];
}

static JuiceBootOverlayView *JuiceBootOverlay(id self)
{
    JuiceBootOverlayView *overlay = objc_getAssociatedObject(self, &JuiceBootOverlayKey);
    if (overlay) return overlay;

    UIViewController *controller = self;
    overlay = [JuiceBootOverlayView new];
    objc_setAssociatedObject(self, &JuiceBootOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *fullscreenButton = JuiceValue(self, @"fullscreenButton");
    if ([fullscreenButton isKindOfClass:UIView.class] && fullscreenButton.superview == controller.view)
        [controller.view insertSubview:overlay belowSubview:fullscreenButton];
    else
        [controller.view addSubview:overlay];

    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:controller.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:controller.view.bottomAnchor]
    ]];
    overlay.hidden = YES;
    return overlay;
}

static void JuiceShowBoot(id self, NSString *detail)
{
    void (^show)(void) = ^{
        NSUInteger generation = JuiceBootGeneration(self) + 1;
        objc_setAssociatedObject(self, &JuiceBootGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &JuiceBootActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &JuiceBootProgressKey, @(0.06f), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &JuiceBootTargetFDKey, @(-1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        JuiceBootOverlayView *overlay = JuiceBootOverlay(self);
        overlay.alpha = 1.0;
        overlay.hidden = NO;
        overlay.titleLabel.text = @"Starting Wine";
        overlay.detailLabel.text = detail.length ? detail : @"Preparing the Windows runtime…";
        overlay.progressView.progressTintColor = UIColor.whiteColor;
        [overlay.progressView setProgress:0.06f animated:NO];
    };
    if (NSThread.isMainThread) show();
    else dispatch_async(dispatch_get_main_queue(), show);
}

static void JuiceAdvanceBoot(id self, float progress, NSString *detail)
{
    if (!JuiceBootIsActive(self)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!JuiceBootIsActive(self)) return;
        float current = [objc_getAssociatedObject(self, &JuiceBootProgressKey) floatValue];
        if (progress < current) return;
        objc_setAssociatedObject(self, &JuiceBootProgressKey, @(progress), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        JuiceBootOverlayView *overlay = JuiceBootOverlay(self);
        if (detail.length) overlay.detailLabel.text = detail;
        [overlay.progressView setProgress:progress animated:YES];
    });
}

static void JuiceHideBootAfter(id self, NSTimeInterval delay, NSUInteger generation)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (JuiceBootGeneration(self) != generation || JuiceBootIsActive(self)) return;
        JuiceBootOverlayView *overlay = JuiceBootOverlay(self);
        [UIView animateWithDuration:0.22 animations:^{ overlay.alpha = 0.0; }
                         completion:^(__unused BOOL finished) {
            if (JuiceBootGeneration(self) == generation && !JuiceBootIsActive(self))
                overlay.hidden = YES;
        }];
    });
}

static void JuiceFinishBoot(id self)
{
    if (!JuiceBootIsActive(self)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!JuiceBootIsActive(self)) return;
        NSUInteger generation = JuiceBootGeneration(self);
        objc_setAssociatedObject(self, &JuiceBootActiveKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &JuiceBootProgressKey, @(1.0f), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        JuiceBootOverlayView *overlay = JuiceBootOverlay(self);
        overlay.titleLabel.text = @"Wine is ready";
        overlay.detailLabel.text = @"Opening the Windows display…";
        [overlay.progressView setProgress:1.0f animated:YES];
        JuiceHideBootAfter(self, 0.28, generation);
    });
}

static void JuiceFailBoot(id self, NSString *detail)
{
    if (!JuiceBootIsActive(self)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!JuiceBootIsActive(self)) return;
        NSUInteger generation = JuiceBootGeneration(self);
        objc_setAssociatedObject(self, &JuiceBootActiveKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        JuiceBootOverlayView *overlay = JuiceBootOverlay(self);
        overlay.titleLabel.text = @"Wine could not start";
        overlay.detailLabel.text = detail.length ? detail : @"Open the full log for details.";
        overlay.progressView.progressTintColor = UIColor.systemRedColor;
        [overlay.progressView setProgress:1.0f animated:YES];
        JuiceHideBootAfter(self, 1.8, generation);
    });
}

static NSInteger JuiceIntegerAfterPrefix(NSString *text, NSString *prefix)
{
    NSRange range = [text rangeOfString:prefix];
    if (range.location == NSNotFound) return -1;
    NSScanner *scanner = [NSScanner scannerWithString:[text substringFromIndex:NSMaxRange(range)]];
    NSInteger value = -1;
    return [scanner scanInteger:&value] ? value : -1;
}

static void JuiceInspectBootLog(id self, NSString *text)
{
    if (!JuiceBootIsActive(self) || !text.length) return;

    if ([text containsString:@"JUICE_LOWVA_FATAL"])
    {
        JuiceFailBoot(self, @"x86 compatibility setup failed. Open Export Full Log for the exact helper error.");
        return;
    }

    if ([text containsString:@"PREFIX_REPAIR_REQUIRED"] ||
        [text containsString:@"RUNTIME_SELECTED runtime="])
        JuiceAdvanceBoot(self, 0.12f, @"Preparing the Wine prefix…");

    if ([text containsString:@"Wine server:"])
        JuiceAdvanceBoot(self, 0.22f, @"Starting Wine services…");

    if ([text containsString:@"JUICE_LOWVA_HELPER_BEGIN"])
        JuiceAdvanceBoot(self, 0.26f, @"Preparing x86 compatibility memory…");

    if ([text containsString:@"JUICE_LOWVA_KERNEL_MIN_OK"])
        JuiceAdvanceBoot(self, 0.31f, @"Low-address Windows memory unlocked…");

    if ([text containsString:@"JUICE_LOWVA_HELPER_OK"] ||
        [text containsString:@"JUICE_LOWVA_READY"])
        JuiceAdvanceBoot(self, 0.35f, @"x86 compatibility memory is ready…");

    if ([text containsString:@"[JuiceStage] running controlled wineboot initialization"])
        JuiceAdvanceBoot(self, 0.40f, @"Initializing the Windows prefix…");

    if ([text containsString:@"prefix initialization complete marker="])
        JuiceAdvanceBoot(self, 0.64f, @"Windows setup is complete…");

    if ([text containsString:@"server_init_process_done entered"])
        JuiceAdvanceBoot(self, 0.72f, @"Starting the Windows process…");

    NSInteger connectedFD = JuiceIntegerAfterPrefix(text, @"DISPLAY_CLIENT_CONNECTED fd=");
    if (connectedFD >= 0)
    {
        NSInteger target = [objc_getAssociatedObject(self, &JuiceBootTargetFDKey) integerValue];
        if (target < 0)
        {
            objc_setAssociatedObject(self, &JuiceBootTargetFDKey, @(connectedFD), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            JuiceAdvanceBoot(self, 0.84f, @"Connecting the Windows display…");
        }
    }

    NSInteger helloFD = JuiceIntegerAfterPrefix(text, @"DISPLAY_EVENT HELLO fd=");
    NSInteger targetFD = [objc_getAssociatedObject(self, &JuiceBootTargetFDKey) integerValue];
    if (helloFD >= 0 && helloFD == targetFD)
        JuiceAdvanceBoot(self, 0.94f, @"Waiting for the first Windows frame…");
}

static void JuiceBootLaunchRequested(id self, SEL _cmd)
{
    JuiceShowBoot(self, @"Preparing the Windows runtime…");
    if (OriginalLaunchRequested) OriginalLaunchRequested(self, _cmd);
}

static void JuiceBootAppend(id self, SEL _cmd, NSString *text)
{
    if (OriginalAppend) OriginalAppend(self, _cmd, text);
    JuiceInspectBootLog(self, text);
}

static void JuiceBootPresentFrame(id self, SEL _cmd, JuiceMsg message, NSData *data,
                                  int fd, pid_t peerPID, BOOL first)
{
    if (OriginalPresentFrame)
        OriginalPresentFrame(self, _cmd, message, data, fd, peerPID, first);

    if (!JuiceBootIsActive(self)) return;
    NSInteger targetFD = [objc_getAssociatedObject(self, &JuiceBootTargetFDKey) integerValue];
    if (targetFD >= 0 && fd == targetFD && message.width > 0 && message.height > 0)
        JuiceFinishBoot(self);
}

__attribute__((constructor))
static void JuiceInstallBootProgress(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method launch = class_getInstanceMethod(cls, NSSelectorFromString(@"launchRequested"));
    if (launch)
        OriginalLaunchRequested = (void (*)(id, SEL))method_setImplementation(launch, (IMP)JuiceBootLaunchRequested);

    Method append = class_getInstanceMethod(cls, NSSelectorFromString(@"append:"));
    if (append)
        OriginalAppend = (void (*)(id, SEL, NSString *))method_setImplementation(append, (IMP)JuiceBootAppend);

    SEL frameSelector = NSSelectorFromString(@"presentFrameMessage:data:client:peerPID:first:");
    Method frame = class_getInstanceMethod(cls, frameSelector);
    if (frame)
        OriginalPresentFrame = (void (*)(id, SEL, JuiceMsg, NSData *, int, pid_t, BOOL))
            method_setImplementation(frame, (IMP)JuiceBootPresentFrame);
}
