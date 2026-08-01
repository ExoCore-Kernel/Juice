#import <Foundation/Foundation.h>

#import "../JuiceZip.h"

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        if (argc != 3)
        {
            fprintf(stderr, "usage: JuiceZipTest archive.zip destination\n");
            return 64;
        }
        NSString *archive = [NSString stringWithUTF8String:argv[1]];
        NSString *destination = [NSString stringWithUTF8String:argv[2]];
        NSError *error = nil;
        if (![JuiceZip extractArchiveAtPath:archive toDirectory:destination error:&error])
        {
            fprintf(stderr, "ZIP_TEST_FAILED %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        NSArray *contents = [[NSFileManager defaultManager]
            subpathsOfDirectoryAtPath:destination error:&error];
        if (!contents)
        {
            fprintf(stderr, "ZIP_TEST_ENUMERATION_FAILED %s\n",
                    error.localizedDescription.UTF8String);
            return 2;
        }
        printf("ZIP_TEST_OK files=%lu\n", (unsigned long)contents.count);
    }
    return 0;
}
