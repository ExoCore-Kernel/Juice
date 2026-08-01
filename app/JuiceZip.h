#import <Foundation/Foundation.h>

@interface JuiceZip : NSObject
+ (BOOL)extractArchiveAtPath:(NSString *)archivePath
                 toDirectory:(NSString *)destination
                       error:(NSError **)error;
@end
