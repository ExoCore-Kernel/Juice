#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface JuiceController : UIViewController
@end

static void (*OriginalFullscreenTapped)(id, SEL);
static void (*OriginalLaunchRequestedForOverlayVisibility)(id, SEL);

static BOOL JuiceControllerIsFullscreen(id controller)
{
    @try
    {
        return [[controller valueForKey:@"fullscreen"] boolValue];
    }
    @catch (__unused NSException *exception)
    {
        return NO;
    }
}

static void JuiceHideBootOverlayViews(UIView *view)
{
    if ([NSStringFromClass(view.class) isEqualToString:@"JuiceBootOverlayView"])
    {
        view.hidden = YES;
        view.alpha = 0.0;
        return;
    }

    for (UIView *subview in view.subviews)
        JuiceHideBootOverlayViews(subview);
}

static void JuiceHideBootOverlayIfWindowed(id controller)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (JuiceControllerIsFullscreen(controller)) return;
        UIViewController *viewController = controller;
        JuiceHideBootOverlayViews(viewController.view);
    });
}

static void JuiceFullscreenTappedWithBootVisibility(id self, SEL _cmd)
{
    if (OriginalFullscreenTapped) OriginalFullscreenTapped(self, _cmd);

    /* The progress overlay is intentionally a fullscreen-only surface.
       Leaving fullscreen must always expose the controls and full log,
       including when Wine startup is still active or has just failed. */
    JuiceHideBootOverlayIfWindowed(self);
}

static void JuiceLaunchRequestedWithBootVisibility(id self, SEL _cmd)
{
    if (OriginalLaunchRequestedForOverlayVisibility)
        OriginalLaunchRequestedForOverlayVisibility(self, _cmd);

    /* BootProgress may have made the overlay visible while a manual launch
       was requested from the normal windowed UI. Keep logs readable there. */
    JuiceHideBootOverlayIfWindowed(self);
}

__attribute__((constructor))
static void JuiceInstallBootOverlayVisibility(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method fullscreen = class_getInstanceMethod(cls, NSSelectorFromString(@"fullscreenTapped"));
    if (fullscreen)
    {
        OriginalFullscreenTapped = (void (*)(id, SEL))
            method_setImplementation(fullscreen, (IMP)JuiceFullscreenTappedWithBootVisibility);
    }

    Method launch = class_getInstanceMethod(cls, NSSelectorFromString(@"launchRequested"));
    if (launch)
    {
        OriginalLaunchRequestedForOverlayVisibility = (void (*)(id, SEL))
            method_setImplementation(launch, (IMP)JuiceLaunchRequestedWithBootVisibility);
    }
}
