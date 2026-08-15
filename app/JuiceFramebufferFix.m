#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/*
 * Correct the pixel interpretation used by the UIKit display transport.
 *
 * Wine's ordinary 32-bit window surfaces are BI_RGB/XRGB8888.  In memory the
 * bytes are B, G, R, X; the high byte is padding and is not an alpha channel.
 * Juice originally wrapped every frame as premultiplied BGRA, which made Core
 * Graphics treat that undefined X byte as alpha.  GDI is free to leave X as
 * zero or any other value, so valid colors could be blended as transparent or
 * invalid premultiplied pixels.  That is what produced the bright magenta,
 * green, and stale-looking blocks visible in software-rendered applications.
 *
 * Wine's macOS driver makes the same distinction and uses
 * kCGImageAlphaNoneSkipFirst for non-alpha window surfaces.  Juice currently
 * transports only the opaque software framebuffer (the IPC protocol does not
 * carry per-window alpha metadata yet), so use those matching XRGB semantics
 * at the UIKit boundary.  If layered-window alpha is added to the transport in
 * the future, it should select PremultipliedFirst explicitly for those frames.
 */

static UIImage *JuiceOpaqueImageFromBGRA(id self, SEL _cmd, NSData *data,
                                         int width, int height, uint32_t stride)
{
    (void)self;
    (void)_cmd;

    if (![data isKindOfClass:NSData.class] || width <= 0 || height <= 0) return nil;
    if (stride < (uint32_t)width * 4u) return nil;

    size_t required = (size_t)stride * (size_t)height;
    if (required > data.length) return nil;

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if (!provider) return nil;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace)
    {
        CGDataProviderRelease(provider);
        return nil;
    }

    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
    CGImageRef cgImage = CGImageCreate((size_t)width, (size_t)height, 8, 32,
                                      (size_t)stride, colorSpace, bitmapInfo,
                                      provider, NULL, false, kCGRenderingIntentDefault);
    UIImage *image = cgImage ? [UIImage imageWithCGImage:cgImage
                                                   scale:1.0
                                             orientation:UIImageOrientationUp] : nil;

    if (cgImage) CGImageRelease(cgImage);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    return image;
}

__attribute__((constructor))
static void JuiceInstallFramebufferFix(void)
{
    Class cls = NSClassFromString(@"JuiceController");
    if (!cls) return;

    SEL selector = NSSelectorFromString(@"imageFromBGRA:width:height:stride:");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;

    method_setImplementation(method, (IMP)JuiceOpaqueImageFromBGRA);
}
