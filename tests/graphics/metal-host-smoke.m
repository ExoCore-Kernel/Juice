/* Native iOS Metal availability probe used to distinguish Wine/MoltenVK
 * failures from app registration or device-state failures. */
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>

@interface JuiceMetalProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

@implementation JuiceMetalProbeDelegate
-(BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    NSString *result=[NSString stringWithFormat:@"JUICE_NATIVE_METAL_%@ name=%@\n",
                      device?@"OK":@"FAIL",device.name?:@"none"];
    NSString *documents=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [NSFileManager.defaultManager createDirectoryAtPath:documents
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [result writeToFile:[documents stringByAppendingPathComponent:@"metal-host-smoke.txt"]
             atomically:YES encoding:NSUTF8StringEncoding error:nil];

    UILabel *label=[[UILabel alloc]initWithFrame:UIScreen.mainScreen.bounds];
    label.text=result;
    label.numberOfLines=0;
    label.textAlignment=NSTextAlignmentCenter;
    label.backgroundColor=UIColor.systemBackgroundColor;
    self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller=[UIViewController new];
    controller.view=label;
    self.window.rootViewController=controller;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc,char **argv)
{
    @autoreleasepool
    {
        return UIApplicationMain(argc,argv,nil,NSStringFromClass(JuiceMetalProbeDelegate.class));
    }
}
