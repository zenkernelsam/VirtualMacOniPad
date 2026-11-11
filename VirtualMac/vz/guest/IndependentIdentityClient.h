// Client for the user-owned native ADI provider. Never launches a subprocess
// inside an Apple daemon, never returns the host identity on provider failure.
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static BOOL VMIndependentEnabled(void) {
    const char *value = getenv("VM_INDEPENDENT_IDENTITY");
    return value && !strcmp(value, "1");
}
static int VMIdentityIO(int fd, void *bytes, size_t length, BOOL writing) {
    while (length) {
        ssize_t n = writing ? write(fd, bytes, length) : read(fd, bytes, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        bytes = (char *)bytes + n; length -= (size_t)n;
    }
    return 0;
}
static NSDictionary *VMIdentityPayload(NSError **error) {
    NSMutableData *body = nil;
    id payload = nil;
    const char *port = getenv("VM_INDEPENDENT_IDENTITY_PORT");
    const char *hex = getenv("VM_INDEPENDENT_IDENTITY_TOKEN");
    char *end = NULL;
    long number = port ? strtol(port, &end, 10) : 0;
    if (!port || !end || *end || number < 1024 || number > 65535 ||
        !hex || strlen(hex) != 64) goto unavailable;
    unsigned char request[33];
    for (unsigned i = 0; i < 32; i++) {
        unsigned value = 0;
        char digits[3] = {hex[i * 2], hex[i * 2 + 1], 0};
        char *tail = NULL;
        if (!isxdigit(digits[0]) || !isxdigit(digits[1])) goto unavailable;
        value = (unsigned)strtoul(digits, &tail, 16);
        if (*tail) goto unavailable;
        request[i] = (unsigned char)value;
    }
    request[32] = 'P';
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) goto unavailable;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval timeout = {8, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address); address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons((uint16_t)number);
    uint32_t length = 0;
    if (connect(fd, (void *)&address, sizeof(address)) ||
        VMIdentityIO(fd, request, sizeof(request), YES) ||
        VMIdentityIO(fd, &length, sizeof(length), NO)) { close(fd); goto unavailable; }
    length = ntohl(length);
    if (!length || length > 65536) { close(fd); goto unavailable; }
    body = [NSMutableData dataWithLength:length];
    if (VMIdentityIO(fd, body.mutableBytes, length, NO)) { close(fd); goto unavailable; }
    close(fd);
    payload = [NSPropertyListSerialization propertyListWithData:body
        options:NSPropertyListImmutable format:NULL error:error];
    if ([payload isKindOfClass:NSDictionary.class] &&
        [payload[@"independentEnabled"] isKindOfClass:NSNumber.class] &&
        [payload[@"independentEnabled"] boolValue] &&
        [payload[@"anisetteArchive"] isKindOfClass:NSData.class] &&
        [payload[@"nativeHeaders"] isKindOfClass:NSDictionary.class]) return payload;
unavailable:
    if (error) *error = [NSError errorWithDomain:@"VirtualMacIndependentIdentity"
        code:1 userInfo:@{NSLocalizedDescriptionKey:@"Independent identity is not ready"}];
    return nil;
}
static id VMIdentityAnisette(NSDictionary *payload, NSError **error) {
    Class cls = NSClassFromString(@"AKAnisetteData");
    if (!cls || ![payload isKindOfClass:NSDictionary.class] ||
        ![payload[@"anisetteArchive"] isKindOfClass:NSData.class]) return nil;
    return [NSKeyedUnarchiver unarchivedObjectOfClass:cls
        fromData:payload[@"anisetteArchive"] error:error];
}
static NSDictionary *VMIdentityMergeHeaders(NSDictionary *original,
    NSDictionary *payload, NSError **error) {
    NSDictionary *headers = [payload isKindOfClass:NSDictionary.class]
        ? payload[@"nativeHeaders"] : nil;
    NSArray *required = @[@"X-Apple-I-MD", @"X-Apple-I-MD-M",
        @"X-Apple-I-MD-RINFO", @"X-Apple-I-MD-LU", @"X-Mme-Device-Id"];
    NSMutableDictionary *result = nil;
    if (![original isKindOfClass:NSDictionary.class] ||
        ![headers isKindOfClass:NSDictionary.class]) goto invalid;
    for (NSString *key in required)
        if (![headers[key] isKindOfClass:NSString.class] || ![headers[key] length]) goto invalid;
    if ([headers[@"X-Apple-I-MD-M"] length] != 80 ||
        [headers[@"X-Apple-I-MD"] length] != 40) goto invalid;
    result = [original mutableCopy];
    for (NSString *old in original.allKeys) {
        if (![old isKindOfClass:NSString.class]) continue;
        for (NSString *key in required)
            if ([old caseInsensitiveCompare:key] == NSOrderedSame) { [result removeObjectForKey:old]; break; }
    }
    for (NSString *key in required) result[key] = headers[key];
    return result;
invalid:
    if (error) *error = [NSError errorWithDomain:@"VirtualMacIndependentIdentity"
        code:2 userInfo:@{NSLocalizedDescriptionKey:@"Independent identity headers are incomplete"}];
    return nil;
}
