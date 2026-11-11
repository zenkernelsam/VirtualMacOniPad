// Enumerate explicit device addresses; never bind INADDR_ANY or guess a gateway.
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
static inline int VMSEPPrivateIPv4(uint32_t address) {
    uint32_t host = ntohl(address);
    return (host & 0xff000000U) == 0x0a000000U ||
        (host & 0xfff00000U) == 0xac100000U ||
        (host & 0xffff0000U) == 0xc0a80000U;
}
static inline int VMSEPInterfaceAllowed(const char *name, unsigned flags) {
    if (!name || !(flags & IFF_UP) || (flags & IFF_LOOPBACK)) return 0;
    const char *digits = NULL;
    if (!strncmp(name,"bridge",6)) digits = name + 6;
    else if (!strncmp(name,"pdp_ip",6)) digits = name + 6;
    else if (!strncmp(name,"en",2)) digits = name + 2;
    if (!digits || !*digits) return 0;
    for (; *digits; digits++) if (!isdigit((unsigned char)*digits)) return 0;
    return 1;
}
#ifdef __OBJC__
#import <Foundation/Foundation.h>
static inline NSArray<NSString *> *VMSEPHostAddresses(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces)) return @[];
    NSMutableSet *addresses = [NSMutableSet set];
    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET ||
            !VMSEPInterfaceAllowed(item->ifa_name,item->ifa_flags)) continue;
        struct sockaddr_in *address = (void *)item->ifa_addr;
        if (!VMSEPPrivateIPv4(address->sin_addr.s_addr)) continue;
        char text[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET,&address->sin_addr,text,sizeof(text))) [addresses addObject:@(text)];
    }
    freeifaddrs(interfaces);
    return [addresses.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
static inline NSString *VMSEPPreferredHost(NSArray *candidates) {
    if (![candidates isKindOfClass:NSArray.class]) return nil;
    struct ifaddrs *interfaces = NULL;
    getifaddrs(&interfaces);
    NSString *selected = nil; int best = -1;
    for (id candidate in candidates) {
        struct in_addr remote;
        if (![candidate isKindOfClass:NSString.class] ||
            inet_pton(AF_INET,[candidate UTF8String],&remote) != 1 ||
            !VMSEPPrivateIPv4(remote.s_addr)) continue;
        int score = 0;
        for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
            if (!item->ifa_addr || !item->ifa_netmask || item->ifa_addr->sa_family != AF_INET ||
                item->ifa_netmask->sa_family != AF_INET ||
                !VMSEPInterfaceAllowed(item->ifa_name,item->ifa_flags)) continue;
            uint32_t local = ((struct sockaddr_in *)item->ifa_addr)->sin_addr.s_addr;
            uint32_t mask = ((struct sockaddr_in *)item->ifa_netmask)->sin_addr.s_addr;
            uint32_t hostMask = ntohl(mask), inverse = ~hostMask;
            if (!VMSEPPrivateIPv4(local) || !hostMask || (inverse & (inverse + 1U))) continue;
            if (remote.s_addr != local && (remote.s_addr & mask) == (local & mask)) score = 1;
        }
        if (score > best) { selected = candidate; best = score; }
    }
    if (interfaces) freeifaddrs(interfaces);
    return selected;
}
#endif
