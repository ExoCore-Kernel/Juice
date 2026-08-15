#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

/*
 * Multi-window presentation fixes for the UIKit host.
 *
 * The first compositor rendered every Wine window into the full 1024x768
 * virtual desktop. That is technically desktop-correct, but it makes normal
 * small Windows applications occupy a tiny patch of an iPad screen. It also
 * meant input coordinates stopped matching once the host view should have
 * been cropped/scaled around the visible window group.
 *
 * Keep Wine's desktop coordinates internally, but present only the bounding
 * viewport of the visible windows. UIKit can then aspect-fit that viewport in
 * exactly the same way as legacy single-window mode. Mouse/touch input is
 * translated back through the viewport and, if needed, through any difference
 * between the current window rectangle and its backing surface dimensions.
 */

#define JUICE_MAGIC 0x4a554943u
#define MSG_INPUT 100u
#define INPUT_LEFT_DOWN 1u
#define INPUT_LEFT_UP 2u
#define INPUT_RIGHT_DOWN 4u
#define INPUT_RIGHT_UP 8u

typedef struct
{
    uint32_t magic, type, size;
    uint64_t hwnd;
    int32_t x, y, width, height;
    uint32_t stride, flags;
} JuiceMsg;

static void (*OriginalCompositeWineDesktop)(id, SEL);
static void (*OriginalHandleCanvasInput)(id, SEL, JuiceMsg);
static char JuiceCompositeViewportKey;
static char JuiceCompositeLoggedViewportKey;

static id JuiceValue(id object, NSString *key)
{
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static void JuiceSetValue(id object, NSString *key, id value)
{
    @try { [object setValue:value forKey:key]; }
    @catch (__unused NSException *exception) {}
}

static void JuiceAppend(id self, NSString *text)
{
    SEL selector = NSSelectorFromString(@"append:");
    if ([self respondsToSelector:selector])
        ((void (*)(id, SEL, id))objc_msgSend)(self, selector, text);
}

static CGRect JuiceStateRect(id state)
{
    NSValue *value = JuiceValue(state, @"frame");
    CGRect rect = [value isKindOfClass:NSValue.class] ? value.CGRectValue : CGRectZero;
    UIImage *image = JuiceValue(state, @"image");

    if (rect.size.width <= 0.0 || rect.size.height <= 0.0)
        rect = CGRectMake(rect.origin.x, rect.origin.y, image.size.width, image.size.height);
    return CGRectStandardize(rect);
}

static BOOL JuiceStateDrawable(id state)
{
    return [JuiceValue(state, @"visible") boolValue] && [JuiceValue(state, @"image") isKindOfClass:UIImage.class];
}

static CGRect JuiceDesktopRect(id self)
{
    NSValue *value = JuiceValue(self, @"wineDesktopSize");
    CGSize size = [value isKindOfClass:NSValue.class] ? value.CGSizeValue : CGSizeZero;
    if (size.width < 1.0 || size.height < 1.0) size = CGSizeMake(1024.0, 768.0);
    return CGRectMake(0.0, 0.0, size.width, size.height);
}

static CGRect JuiceClippedWindowRect(id state, CGRect desktop)
{
    CGRect rect = JuiceStateRect(state);
    if (CGRectIsEmpty(rect) || CGRectIsNull(rect)) return CGRectNull;
    CGRect clipped = CGRectIntersection(rect, desktop);
    return CGRectIsEmpty(clipped) || CGRectIsNull(clipped) ? CGRectNull : clipped;
}

static CGRect JuiceViewportForWindows(id self, NSArray<NSNumber *> *order, NSDictionary<NSNumber *, id> *windows)
{
    CGRect desktop = JuiceDesktopRect(self);
    CGRect content = CGRectNull;

    for (NSNumber *key in order)
    {
        id state = windows[key];
        if (!JuiceStateDrawable(state)) continue;
        CGRect rect = JuiceClippedWindowRect(state, desktop);
        if (CGRectIsNull(rect)) continue;
        content = CGRectIsNull(content) ? rect : CGRectUnion(content, rect);
    }

    if (CGRectIsNull(content)) return desktop;

    /* A little breathing room without reintroducing the mostly-empty desktop. */
    CGFloat pad = MIN(16.0, MAX(4.0, MIN(content.size.width, content.size.height) * 0.03));
    CGRect viewport = CGRectIntersection(CGRectInset(content, -pad, -pad), desktop);
    if (CGRectIsNull(viewport) || CGRectIsEmpty(viewport)) viewport = content;

    CGFloat minX = floor(CGRectGetMinX(viewport));
    CGFloat minY = floor(CGRectGetMinY(viewport));
    CGFloat maxX = ceil(CGRectGetMaxX(viewport));
    CGFloat maxY = ceil(CGRectGetMaxY(viewport));
    return CGRectMake(minX, minY, MAX(1.0, maxX - minX), MAX(1.0, maxY - minY));
}

static void JuiceLogViewportIfChanged(id self, CGRect viewport, CGRect desktop)
{
    NSValue *previous = objc_getAssociatedObject(self, &JuiceCompositeLoggedViewportKey);
    if (previous && CGRectEqualToRect(previous.CGRectValue, viewport)) return;
    objc_setAssociatedObject(self, &JuiceCompositeLoggedViewportKey,
                             [NSValue valueWithCGRect:viewport], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    JuiceAppend(self, [NSString stringWithFormat:
        @"MULTI_WINDOW_VIEWPORT rect=%.0f,%.0f %.0fx%.0f desktop=%.0fx%.0f\n",
        viewport.origin.x, viewport.origin.y, viewport.size.width, viewport.size.height,
        desktop.size.width, desktop.size.height]);
}

static void JuiceFixedCompositeWineDesktop(id self, SEL _cmd)
{
    if (![JuiceValue(self, @"experimentalMultiWindow") boolValue])
    {
        if (OriginalCompositeWineDesktop) OriginalCompositeWineDesktop(self, _cmd);
        return;
    }

    NSDictionary<NSNumber *, id> *windows = JuiceValue(self, @"wineWindows");
    NSArray<NSNumber *> *order = JuiceValue(self, @"wineWindowOrder");
    id canvas = JuiceValue(self, @"canvas");
    if (![windows isKindOfClass:NSDictionary.class] || ![order isKindOfClass:NSArray.class] || !canvas)
    {
        if (OriginalCompositeWineDesktop) OriginalCompositeWineDesktop(self, _cmd);
        return;
    }

    CGRect desktop = JuiceDesktopRect(self);
    CGRect viewport = JuiceViewportForWindows(self, order, windows);
    objc_setAssociatedObject(self, &JuiceCompositeViewportKey,
                             [NSValue valueWithCGRect:viewport], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIGraphicsBeginImageContextWithOptions(viewport.size, YES, 1.0);
    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0.0, 0.0, viewport.size.width, viewport.size.height));

    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, -viewport.origin.x, -viewport.origin.y);

    id topState = nil;
    for (NSNumber *key in order)
    {
        id state = windows[key];
        if (!JuiceStateDrawable(state)) continue;

        CGRect rect = JuiceStateRect(state);
        if (CGRectIsEmpty(rect) || CGRectIsNull(rect) || !CGRectIntersectsRect(rect, viewport)) continue;
        UIImage *image = JuiceValue(state, @"image");
        [image drawInRect:rect];
        topState = state;
    }

    CGContextRestoreGState(context);
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (result) JuiceSetValue(canvas, @"image", result);
    if (topState)
    {
        NSNumber *hwnd = JuiceValue(topState, @"hwnd");
        NSNumber *client = JuiceValue(topState, @"clientFD");
        if (hwnd) JuiceSetValue(canvas, @"hwnd", hwnd);
        if (client) JuiceSetValue(self, @"activeClient", client);
    }
    JuiceLogViewportIfChanged(self, viewport, desktop);
}

static id JuiceTopWindowAtDesktopPoint(NSDictionary<NSNumber *, id> *windows,
                                       NSArray<NSNumber *> *order, CGPoint point, CGRect desktop)
{
    for (NSNumber *key in order.reverseObjectEnumerator)
    {
        id state = windows[key];
        if (!JuiceStateDrawable(state)) continue;
        CGRect rect = JuiceClippedWindowRect(state, desktop);
        if (!CGRectIsNull(rect) && CGRectContainsPoint(rect, point)) return state;
    }
    return nil;
}

static BOOL JuiceSendMessageToFD(id self, JuiceMsg *message, NSData *payload, int fd)
{
    SEL selector = NSSelectorFromString(@"sendMessage:payload:toFD:");
    if (![self respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL, JuiceMsg *, id, int))objc_msgSend)(self, selector, message, payload, fd);
}

static CGFloat JuiceClamp(CGFloat value, CGFloat upper)
{
    if (value < 0.0) return 0.0;
    if (upper > 0.0 && value >= upper) return upper - 1.0;
    return value;
}

static void JuiceFixedHandleCanvasInput(id self, SEL _cmd, JuiceMsg message)
{
    if (![JuiceValue(self, @"experimentalMultiWindow") boolValue])
    {
        if (OriginalHandleCanvasInput) OriginalHandleCanvasInput(self, _cmd, message);
        return;
    }

    NSDictionary<NSNumber *, id> *windows = JuiceValue(self, @"wineWindows");
    NSArray<NSNumber *> *order = JuiceValue(self, @"wineWindowOrder");
    if (![windows isKindOfClass:NSDictionary.class] || ![order isKindOfClass:NSArray.class]) return;

    NSValue *viewportValue = objc_getAssociatedObject(self, &JuiceCompositeViewportKey);
    CGRect viewport = viewportValue ? viewportValue.CGRectValue : JuiceDesktopRect(self);
    CGPoint desktopPoint = CGPointMake(message.x + viewport.origin.x, message.y + viewport.origin.y);
    CGRect desktop = JuiceDesktopRect(self);

    BOOL down = (message.flags & (INPUT_LEFT_DOWN | INPUT_RIGHT_DOWN)) != 0;
    BOOL up = (message.flags & (INPUT_LEFT_UP | INPUT_RIGHT_UP)) != 0;
    id target = nil;

    int capturedClient = [JuiceValue(self, @"inputClient") intValue];
    uint64_t capturedHwnd = [JuiceValue(self, @"inputHwnd") unsignedLongLongValue];
    if (!down && capturedClient >= 0 && capturedHwnd)
    {
        target = windows[@(capturedHwnd)];
        if (!JuiceStateDrawable(target)) target = nil;
    }
    if (!target) target = JuiceTopWindowAtDesktopPoint(windows, order, desktopPoint, desktop);
    if (!target) return;

    uint64_t hwnd = [JuiceValue(target, @"hwnd") unsignedLongLongValue];
    int client = [JuiceValue(target, @"clientFD") intValue];
    CGRect rect = JuiceStateRect(target);
    UIImage *image = JuiceValue(target, @"image");
    if (client < 0 || !hwnd || CGRectIsEmpty(rect) || !image) return;

    if (down)
    {
        JuiceSetValue(self, @"inputHwnd", @(hwnd));
        JuiceSetValue(self, @"inputClient", @(client));
    }

    CGFloat localX = desktopPoint.x - rect.origin.x;
    CGFloat localY = desktopPoint.y - rect.origin.y;

    /* Normally these ratios are 1. They also make input survive a resize race
       where the host has new geometry one frame before Wine swaps surfaces. */
    if (rect.size.width > 0.0 && image.size.width > 0.0) localX *= image.size.width / rect.size.width;
    if (rect.size.height > 0.0 && image.size.height > 0.0) localY *= image.size.height / rect.size.height;

    localX = JuiceClamp(localX, image.size.width);
    localY = JuiceClamp(localY, image.size.height);

    message.magic = JUICE_MAGIC;
    message.type = MSG_INPUT;
    message.hwnd = hwnd;
    message.x = (int32_t)floor(localX);
    message.y = (int32_t)floor(localY);

    id canvas = JuiceValue(self, @"canvas");
    if (canvas) JuiceSetValue(canvas, @"hwnd", @(hwnd));
    JuiceSetValue(self, @"activeClient", @(client));
    JuiceSendMessageToFD(self, &message, nil, client);

    if (up)
    {
        JuiceSetValue(self, @"inputHwnd", @0);
        JuiceSetValue(self, @"inputClient", @(-1));
    }
}

__attribute__((constructor))
static void JuiceInstallMultiWindowFix(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    Method composite = class_getInstanceMethod(cls, NSSelectorFromString(@"compositeWineDesktop"));
    if (composite)
        OriginalCompositeWineDesktop = (void (*)(id, SEL))method_setImplementation(composite, (IMP)JuiceFixedCompositeWineDesktop);

    Method input = class_getInstanceMethod(cls, NSSelectorFromString(@"handleCanvasInput:"));
    if (input)
        OriginalHandleCanvasInput = (void (*)(id, SEL, JuiceMsg))method_setImplementation(input, (IMP)JuiceFixedHandleCanvasInput);
}
