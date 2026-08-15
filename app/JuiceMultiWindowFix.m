#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

/*
 * Multi-window presentation fixes for the UIKit host.
 *
 * Keep Wine's desktop coordinates internally, but present only the bounding
 * viewport of the visible window group. Three details are important here:
 *
 *  1. The viewport must not chase a window while the user is dragging it.
 *     If the crop origin changes between touch events, the same physical
 *     finger position maps to a different Wine desktop coordinate and creates
 *     a feedback loop that looks like jitter. Lock the viewport for the whole
 *     pointer capture and recalculate it only after button-up.
 *
 *  2. Pointer messages for a moving window must stay in desktop coordinates.
 *     Converting to window-local coordinates in UIKit and then adding Wine's
 *     current window origin on the other side races the window move itself.
 *     A one-frame geometry difference becomes a visible cursor jump. Desktop
 *     coordinates are stable for the whole drag and also allow the pointer to
 *     move outside the current window rectangle while capture is active.
 *
 *  3. A Wine window surface and its latest window geometry can briefly be
 *     different sizes during create/resize. The old compositor stretched the
 *     entire backing surface to the new rectangle. Oversized stale backing
 *     pixels therefore appeared as a large white/unused area next to small
 *     apps such as WineMine. Wine's iOS software surfaces are 1 pixel per
 *     desktop unit, so preserve that 1:1 mapping and clip any excess backing
 *     pixels instead of scaling them into view.
 */

#define JUICE_MAGIC 0x4a554943u
#define MSG_INPUT 100u
#define INPUT_LEFT_DOWN 1u
#define INPUT_LEFT_UP 2u
#define INPUT_RIGHT_DOWN 4u
#define INPUT_RIGHT_UP 8u
#define INPUT_COORDS_DESKTOP 0x40000000u

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
static char JuiceCapturedViewportKey;

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

/*
 * The backing UIImage is generated directly from the Wine software surface,
 * so its pixels are desktop pixels. Never stretch a stale backing allocation
 * to a newer window rectangle. Use only the area present in both.
 */
static CGRect JuiceStateDrawableRect(id state)
{
    CGRect rect = JuiceStateRect(state);
    UIImage *image = JuiceValue(state, @"image");
    if (![image isKindOfClass:UIImage.class]) return rect;

    CGFloat width = image.size.width;
    CGFloat height = image.size.height;
    if (rect.size.width > 0.0) width = MIN(width, rect.size.width);
    if (rect.size.height > 0.0) height = MIN(height, rect.size.height);
    return CGRectMake(rect.origin.x, rect.origin.y, MAX(1.0, width), MAX(1.0, height));
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
    CGRect rect = JuiceStateDrawableRect(state);
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
        @"MULTI_WINDOW_VIEWPORT rect=%.0f,%.0f %.0fx%.0f desktop=%.0fx%.0f locked=%d\n",
        viewport.origin.x, viewport.origin.y, viewport.size.width, viewport.size.height,
        desktop.size.width, desktop.size.height,
        objc_getAssociatedObject(self, &JuiceCapturedViewportKey) != nil]);
}

static void JuiceDrawStateImage(id state, CGContextRef context)
{
    UIImage *image = JuiceValue(state, @"image");
    if (![image isKindOfClass:UIImage.class]) return;

    CGRect logical = JuiceStateRect(state);
    CGRect drawable = JuiceStateDrawableRect(state);
    if (CGRectIsEmpty(drawable) || CGRectIsNull(drawable)) return;

    /*
     * Draw the framebuffer at its native 1:1 size and clip it to the current
     * Wine window rectangle. This discards stale oversized backing pixels
     * without distorting the live application contents.
     */
    CGContextSaveGState(context);
    CGContextClipToRect(context, drawable);
    [image drawInRect:CGRectMake(logical.origin.x, logical.origin.y,
                                 image.size.width, image.size.height)];
    CGContextRestoreGState(context);
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

    int capturedClient = [JuiceValue(self, @"inputClient") intValue];
    uint64_t capturedHwnd = [JuiceValue(self, @"inputHwnd") unsignedLongLongValue];
    if (capturedClient < 0 || !capturedHwnd)
        objc_setAssociatedObject(self, &JuiceCapturedViewportKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGRect desktop = JuiceDesktopRect(self);
    NSValue *lockedValue = objc_getAssociatedObject(self, &JuiceCapturedViewportKey);
    CGRect viewport = lockedValue ? lockedValue.CGRectValue : JuiceViewportForWindows(self, order, windows);
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

        CGRect rect = JuiceStateDrawableRect(state);
        if (CGRectIsEmpty(rect) || CGRectIsNull(rect) || !CGRectIntersectsRect(rect, viewport)) continue;
        JuiceDrawStateImage(state, context);
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

    BOOL down = (message.flags & (INPUT_LEFT_DOWN | INPUT_RIGHT_DOWN)) != 0;
    BOOL up = (message.flags & (INPUT_LEFT_UP | INPUT_RIGHT_UP)) != 0;

    NSValue *viewportValue = objc_getAssociatedObject(self, &JuiceCapturedViewportKey);
    if (!viewportValue) viewportValue = objc_getAssociatedObject(self, &JuiceCompositeViewportKey);
    CGRect viewport = viewportValue ? viewportValue.CGRectValue : JuiceDesktopRect(self);

    /* Freeze the exact coordinate basis used for the button-down event. */
    if (down && !objc_getAssociatedObject(self, &JuiceCapturedViewportKey))
    {
        NSValue *locked = [NSValue valueWithCGRect:viewport];
        objc_setAssociatedObject(self, &JuiceCapturedViewportKey, locked, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGPoint desktopPoint = CGPointMake(message.x + viewport.origin.x, message.y + viewport.origin.y);
    CGRect desktop = JuiceDesktopRect(self);
    id target = nil;

    int capturedClient = [JuiceValue(self, @"inputClient") intValue];
    uint64_t capturedHwnd = [JuiceValue(self, @"inputHwnd") unsignedLongLongValue];
    if (!down && capturedClient >= 0 && capturedHwnd)
    {
        target = windows[@(capturedHwnd)];
        if (!JuiceStateDrawable(target)) target = nil;
    }
    if (!target) target = JuiceTopWindowAtDesktopPoint(windows, order, desktopPoint, desktop);
    if (!target)
    {
        if (up) objc_setAssociatedObject(self, &JuiceCapturedViewportKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    uint64_t hwnd = [JuiceValue(target, @"hwnd") unsignedLongLongValue];
    int client = [JuiceValue(target, @"clientFD") intValue];
    CGRect rect = JuiceStateDrawableRect(target);
    if (client < 0 || !hwnd || CGRectIsEmpty(rect)) return;

    if (down)
    {
        JuiceSetValue(self, @"inputHwnd", @(hwnd));
        JuiceSetValue(self, @"inputClient", @(client));
    }

    /*
     * Do not subtract rect.origin and do not clamp to the window. A title-bar
     * drag is screen-space pointer capture: the finger remains meaningful even
     * after the window has moved underneath it or the pointer leaves its old
     * rectangle. Wine consumes this flag and treats x/y as desktop coords.
     */
    message.magic = JUICE_MAGIC;
    message.type = MSG_INPUT;
    message.hwnd = hwnd;
    message.x = (int32_t)floor(desktopPoint.x);
    message.y = (int32_t)floor(desktopPoint.y);
    message.flags |= INPUT_COORDS_DESKTOP;

    id canvas = JuiceValue(self, @"canvas");
    if (canvas) JuiceSetValue(canvas, @"hwnd", @(hwnd));
    JuiceSetValue(self, @"activeClient", @(client));
    JuiceSendMessageToFD(self, &message, nil, client);

    if (up)
    {
        JuiceSetValue(self, @"inputHwnd", @0);
        JuiceSetValue(self, @"inputClient", @(-1));
        objc_setAssociatedObject(self, &JuiceCapturedViewportKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        /* Recenter only after the drag is finished. */
        SEL composite = NSSelectorFromString(@"compositeWineDesktop");
        if ([self respondsToSelector:composite])
            ((void (*)(id, SEL))objc_msgSend)(self, composite);
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
