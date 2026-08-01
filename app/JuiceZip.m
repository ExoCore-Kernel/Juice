#import "JuiceZip.h"

#import <limits.h>
#import <zlib.h>

static NSString *const JuiceZipErrorDomain = @"com.jacksipad.juice.zip";

static uint16_t JZRead16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t JZRead32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static BOOL JZRangeIsValid(NSUInteger offset, NSUInteger size, NSUInteger total)
{
    return offset <= total && size <= total - offset;
}

static BOOL JZFail(NSError **error, NSInteger code, NSString *message)
{
    if (error)
        *error = [NSError errorWithDomain:JuiceZipErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

static NSString *JZEntryName(const uint8_t *bytes, NSUInteger length, BOOL utf8)
{
    NSStringEncoding encoding = utf8 ? NSUTF8StringEncoding : NSISOLatin1StringEncoding;
    NSString *name = [[NSString alloc] initWithBytes:bytes length:length encoding:encoding];
    if (!name && !utf8)
        name = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    return [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

static NSString *JZSafeDestination(NSString *root, NSString *entry)
{
    if (!entry.length || [entry hasPrefix:@"/"]) return nil;

    NSMutableArray<NSString *> *safe = [NSMutableArray array];
    for (NSString *component in [entry componentsSeparatedByString:@"/"])
    {
        if (!component.length || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."] || [component containsString:@":"]) return nil;
        [safe addObject:component];
    }
    if (!safe.count) return nil;

    NSString *path = [root stringByAppendingPathComponent:[safe componentsJoinedByString:@"/"]];
    NSString *standardRoot = root.stringByStandardizingPath;
    NSString *standardPath = path.stringByStandardizingPath;
    NSString *prefix = [standardRoot stringByAppendingString:@"/"];
    return [standardPath hasPrefix:prefix] ? standardPath : nil;
}

@implementation JuiceZip

+ (BOOL)extractArchiveAtPath:(NSString *)archivePath
                 toDirectory:(NSString *)destination
                       error:(NSError **)error
{
    NSError *readError = nil;
    NSData *archive = [NSData dataWithContentsOfFile:archivePath
                                            options:NSDataReadingMappedIfSafe
                                              error:&readError];
    if (!archive)
    {
        if (error) *error = readError;
        return NO;
    }

    const uint8_t *bytes = archive.bytes;
    NSUInteger length = archive.length;
    if (length < 22) return JZFail(error, 1, @"The ZIP archive is truncated.");

    NSUInteger searchStart = length > 22 + UINT16_MAX ? length - 22 - UINT16_MAX : 0;
    NSUInteger eocdOffset = NSNotFound;
    for (NSUInteger offset = length - 22;; offset--)
    {
        if (JZRead32(bytes + offset) == 0x06054b50 &&
            offset + 22u + JZRead16(bytes + offset + 20) == length)
        {
            eocdOffset = offset;
            break;
        }
        if (offset == searchStart) break;
    }
    if (eocdOffset == NSNotFound)
        return JZFail(error, 2, @"The ZIP central directory was not found.");

    const uint8_t *eocd = bytes + eocdOffset;
    uint16_t disk = JZRead16(eocd + 4);
    uint16_t centralDisk = JZRead16(eocd + 6);
    uint16_t diskEntries = JZRead16(eocd + 8);
    uint16_t entryCount = JZRead16(eocd + 10);
    uint32_t centralSize = JZRead32(eocd + 12);
    uint32_t centralOffset = JZRead32(eocd + 16);
    if (disk || centralDisk || diskEntries != entryCount)
        return JZFail(error, 3, @"Multi-volume ZIP archives are not supported.");
    if (entryCount == UINT16_MAX || centralSize == UINT32_MAX || centralOffset == UINT32_MAX)
        return JZFail(error, 4, @"ZIP64 archives are not supported yet.");
    if (!JZRangeIsValid(centralOffset, centralSize, eocdOffset) ||
        (NSUInteger)centralOffset + centralSize != eocdOffset)
        return JZFail(error, 5, @"The ZIP central directory is outside the archive.");

    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtPath:destination
          withIntermediateDirectories:YES attributes:nil error:error])
        return NO;

    NSUInteger cursor = centralOffset;
    uint64_t extractedTotal = 0;
    for (uint16_t index = 0; index < entryCount; index++)
    {
        if (!JZRangeIsValid(cursor, 46, length) || JZRead32(bytes + cursor) != 0x02014b50)
            return JZFail(error, 6, @"A ZIP directory entry is invalid.");

        const uint8_t *central = bytes + cursor;
        uint16_t flags = JZRead16(central + 8);
        uint16_t method = JZRead16(central + 10);
        uint32_t expectedCRC = JZRead32(central + 16);
        uint32_t compressedSize = JZRead32(central + 20);
        uint32_t uncompressedSize = JZRead32(central + 24);
        uint16_t nameLength = JZRead16(central + 28);
        uint16_t extraLength = JZRead16(central + 30);
        uint16_t commentLength = JZRead16(central + 32);
        uint16_t startDisk = JZRead16(central + 34);
        uint32_t localOffset = JZRead32(central + 42);
        NSUInteger centralEntrySize = 46u + nameLength + extraLength + commentLength;

        if (!JZRangeIsValid(cursor, centralEntrySize, length))
            return JZFail(error, 7, @"A ZIP filename or metadata field is truncated.");
        if (flags & 1)
            return JZFail(error, 8, @"Password-protected ZIP archives are not supported.");
        if (startDisk)
            return JZFail(error, 9, @"Multi-volume ZIP entries are not supported.");
        if (compressedSize == UINT32_MAX || uncompressedSize == UINT32_MAX ||
            localOffset == UINT32_MAX)
            return JZFail(error, 10, @"ZIP64 entries are not supported yet.");
        if (method != 0 && method != 8)
            return JZFail(error, 11,
                          [NSString stringWithFormat:@"Unsupported ZIP compression method %u.", method]);

        NSString *name = JZEntryName(central + 46, nameLength, (flags & (1u << 11)) != 0);
        NSString *outputPath = name ? JZSafeDestination(destination, name) : nil;
        if (!outputPath)
            return JZFail(error, 12, @"The ZIP contains an unsafe or invalid path.");

        BOOL directory = [name hasSuffix:@"/"];
        if (directory)
        {
            if (![files createDirectoryAtPath:outputPath
                  withIntermediateDirectories:YES attributes:nil error:error])
                return NO;
            cursor += centralEntrySize;
            continue;
        }

        extractedTotal += uncompressedSize;
        if (extractedTotal > (uint64_t)4 * 1024 * 1024 * 1024)
            return JZFail(error, 13, @"The extracted ZIP would exceed Juice's 4 GiB safety limit.");
        if (!JZRangeIsValid(localOffset, 30, length) ||
            JZRead32(bytes + localOffset) != 0x04034b50)
            return JZFail(error, 14, @"A ZIP local file header is invalid.");

        const uint8_t *local = bytes + localOffset;
        uint16_t localNameLength = JZRead16(local + 26);
        uint16_t localExtraLength = JZRead16(local + 28);
        NSUInteger dataOffset = (NSUInteger)localOffset + 30u + localNameLength + localExtraLength;
        if (!JZRangeIsValid(dataOffset, compressedSize, length))
            return JZFail(error, 15, @"Compressed ZIP data is truncated.");

        NSString *parent = outputPath.stringByDeletingLastPathComponent;
        if (![files createDirectoryAtPath:parent
              withIntermediateDirectories:YES attributes:nil error:error])
            return NO;

        NSData *output = nil;
        if (method == 0)
        {
            if (compressedSize != uncompressedSize)
                return JZFail(error, 16, @"A stored ZIP entry has inconsistent sizes.");
            output = [NSData dataWithBytesNoCopy:(void *)(bytes + dataOffset)
                                         length:uncompressedSize
                                   freeWhenDone:NO];
        }
        else
        {
            if (compressedSize > UINT_MAX || uncompressedSize > UINT_MAX)
                return JZFail(error, 17, @"A ZIP entry is too large to decompress.");

            NSMutableData *inflated = [NSMutableData dataWithLength:uncompressedSize];
            Bytef emptyOutput = 0;
            z_stream stream = {0};
            stream.next_in = (Bytef *)(bytes + dataOffset);
            stream.avail_in = compressedSize;
            stream.next_out = uncompressedSize ? inflated.mutableBytes : &emptyOutput;
            stream.avail_out = uncompressedSize ? uncompressedSize : 1;

            int status = inflateInit2(&stream, -MAX_WBITS);
            if (status == Z_OK) status = inflate(&stream, Z_FINISH);
            inflateEnd(&stream);
            if (status != Z_STREAM_END || stream.total_out != uncompressedSize)
                return JZFail(error, 18,
                              [NSString stringWithFormat:@"Could not decompress %@.", name]);
            output = inflated;
        }

        uLong actualCRC = crc32(0L, Z_NULL, 0);
        actualCRC = crc32(actualCRC, output.bytes, (uInt)output.length);
        if ((uint32_t)actualCRC != expectedCRC)
            return JZFail(error, 19,
                          [NSString stringWithFormat:@"Checksum verification failed for %@.", name]);

        NSError *writeError = nil;
        if (![output writeToFile:outputPath options:0 error:&writeError])
        {
            if (error) *error = writeError;
            return NO;
        }
        cursor += centralEntrySize;
    }
    if (cursor != (NSUInteger)centralOffset + centralSize)
        return JZFail(error, 20, @"The ZIP central directory size is inconsistent.");
    return YES;
}

@end
