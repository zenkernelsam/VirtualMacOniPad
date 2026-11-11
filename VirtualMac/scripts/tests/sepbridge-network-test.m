// Public fixture addresses only. Interface enumeration is mocked throughout.
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static struct ifaddrs fixtures[32];
static struct sockaddr_storage addresses[32], masks[32];
static unsigned count, released;
static int queryFailure;

static int fixtureGetIfaddrs(struct ifaddrs **result) {
    *result = queryFailure || !count ? NULL : fixtures;
    return queryFailure ? -1 : 0;
}
static void fixtureFreeIfaddrs(struct ifaddrs *value) {
    if (value != fixtures) { fputs("FAIL invalid fixture free\n", stderr); exit(1); }
    released++;
}
#define getifaddrs fixtureGetIfaddrs
#define freeifaddrs fixtureFreeIfaddrs
#include "../../vz/guest/SEPBridgeNetwork.h"
#undef getifaddrs
#undef freeifaddrs

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return 1; } } while (0)

static void reset(void) {
    memset(fixtures, 0, sizeof(fixtures));
    memset(addresses, 0, sizeof(addresses));
    memset(masks, 0, sizeof(masks));
    count = released = 0; queryFailure = 0;
}
static void add(const char *name, unsigned flags, const char *address, const char *mask, int family) {
    unsigned index = count++;
    fixtures[index].ifa_name = (char *)name;
    fixtures[index].ifa_flags = flags;
    fixtures[index].ifa_addr = (void *)&addresses[index];
    if (index) fixtures[index - 1].ifa_next = &fixtures[index];
    if (family == AF_INET) {
        struct sockaddr_in *ip = (void *)&addresses[index];
        ip->sin_len = sizeof(*ip); ip->sin_family = AF_INET;
        if (inet_pton(AF_INET, address, &ip->sin_addr) != 1) abort();
        if (mask) {
            struct sockaddr_in *netmask = (void *)&masks[index];
            netmask->sin_len = sizeof(*netmask); netmask->sin_family = AF_INET;
            if (inet_pton(AF_INET, mask, &netmask->sin_addr) != 1) abort();
            fixtures[index].ifa_netmask = (void *)netmask;
        }
    } else {
        struct sockaddr_in6 *ip = (void *)&addresses[index];
        ip->sin6_len = sizeof(*ip); ip->sin6_family = AF_INET6;
        if (inet_pton(AF_INET6, address, &ip->sin6_addr) != 1) abort();
    }
}
static uint32_t ip(const char *value) {
    struct in_addr address;
    if (inet_pton(AF_INET, value, &address) != 1) abort();
    return address.s_addr;
}

static int privateChecks(void) {
    for (NSString *value in @[@"10.0.0.0", @"10.255.255.255", @"172.16.0.0",
                              @"172.31.255.255", @"192.168.0.0", @"192.168.255.255"])
        CHECK(VMSEPPrivateIPv4(ip(value.UTF8String)));
    for (NSString *value in @[@"9.255.255.255", @"11.0.0.0", @"172.15.255.255",
                              @"172.32.0.0", @"192.167.255.255", @"192.169.0.0",
                              @"127.0.0.1", @"0.0.0.0", @"169.254.1.1", @"1.1.1.1"])
        CHECK(!VMSEPPrivateIPv4(ip(value.UTF8String)));
    return 0;
}
static int interfaceChecks(void) {
    for (NSString *name in @[@"en0", @"en12", @"bridge100", @"pdp_ip0", @"pdp_ip27"])
        CHECK(VMSEPInterfaceAllowed(name.UTF8String, IFF_UP));
    for (NSString *name in @[@"lo0", @"utun0", @"awdl0", @"ap1", @"vmenet0", @"en",
                             @"en-1", @"en0junk", @"bridge", @"bridge101 ", @"pdp_ip"])
        CHECK(!VMSEPInterfaceAllowed(name.UTF8String, IFF_UP));
    CHECK(!VMSEPInterfaceAllowed(NULL, IFF_UP));
    CHECK(!VMSEPInterfaceAllowed("en0", 0));
    CHECK(!VMSEPInterfaceAllowed("en0", IFF_UP | IFF_LOOPBACK));
    return 0;
}
static int hostChecks(void) {
    reset();
    add("en0", IFF_UP, "192.168.68.66", "255.255.252.0", AF_INET);
    add("bridge100", IFF_UP, "192.168.64.1", "255.255.255.0", AF_INET);
    add("en1", IFF_UP, "192.168.68.66", "255.255.252.0", AF_INET);
    add("pdp_ip0", IFF_UP, "10.231.4.160", "255.255.255.255", AF_INET);
    add("pdp_ip1", IFF_UP, "172.20.10.1", "255.255.255.240", AF_INET);
    add("en2", 0, "192.168.99.1", "255.255.255.0", AF_INET);
    add("en3", IFF_UP, "1.1.1.1", "255.255.255.0", AF_INET);
    add("lo0", IFF_UP | IFF_LOOPBACK, "127.0.0.1", "255.0.0.0", AF_INET);
    add("utun1", IFF_UP, "10.0.0.2", "255.255.255.0", AF_INET);
    add("en4", IFF_UP, "fd00::66", NULL, AF_INET6);
    NSArray *expected = @[@"10.231.4.160", @"172.20.10.1", @"192.168.64.1", @"192.168.68.66"];
    CHECK([VMSEPHostAddresses() isEqual:expected]);
    CHECK(released == 1);
    reset(); queryFailure = 1;
    CHECK(VMSEPHostAddresses().count == 0 && released == 0);
    return 0;
}
static int wifiChecks(void) {
    reset();
    add("en0", IFF_UP, "192.168.68.59", "255.255.252.0", AF_INET);
    CHECK([VMSEPPreferredHost(@[@"192.168.64.1", @"192.168.68.66"]) isEqual:@"192.168.68.66"]);
    CHECK([VMSEPPreferredHost(@[@"192.168.68.66", @"192.168.64.1"]) isEqual:@"192.168.68.66"]);
    CHECK([VMSEPPreferredHost(@[@"192.168.64.1", @"192.168.71.66"]) isEqual:@"192.168.71.66"]);
    CHECK(released == 3);
    return 0;
}
static int natChecks(void) {
    reset();
    add("en0", IFF_UP, "192.168.64.2", "255.255.255.0", AF_INET);
    CHECK([VMSEPPreferredHost(@[@"192.168.68.66", @"192.168.64.1"]) isEqual:@"192.168.64.1"]);
    CHECK([VMSEPPreferredHost(@[@"192.168.64.1", @"192.168.68.66"]) isEqual:@"192.168.64.1"]);
    return 0;
}
static int candidateChecks(void) {
    reset();
    add("en0", IFF_UP, "192.168.68.59", "255.255.252.0", AF_INET);
    CHECK(!VMSEPPreferredHost(nil));
    CHECK(!VMSEPPreferredHost((NSArray *)@"192.168.68.66"));
    CHECK(!VMSEPPreferredHost(@[]));
    CHECK(!VMSEPPreferredHost(@[@1, NSNull.null, @"", @"not-an-address", @"::1", @"fd00::1",
                                @"127.0.0.1", @"169.254.1.1", @"1.1.1.1", @"192.168.68.66junk"]));
    CHECK([VMSEPPreferredHost(@[@"fd00::1", @"192.168.68.66", @"192.168.68.66"])
           isEqual:@"192.168.68.66"]);
    return 0;
}
static int downChecks(void) {
    reset();
    add("en9", 0, "192.168.64.2", "255.255.255.0", AF_INET);
    add("utun0", IFF_UP, "192.168.64.2", "255.255.255.0", AF_INET);
    add("en8", IFF_UP | IFF_LOOPBACK, "192.168.64.2", "255.255.255.0", AF_INET);
    add("en0", IFF_UP, "192.168.68.59", "255.255.252.0", AF_INET);
    add("en4", IFF_UP, "fd00::66", NULL, AF_INET6);
    CHECK([VMSEPPreferredHost(@[@"192.168.64.1", @"192.168.68.66"]) isEqual:@"192.168.68.66"]);
    return 0;
}
static int incompleteMaskChecks(void) {
    reset();
    // An UP interface can be present before its DHCP address/mask is ready.
    // That /0 must not outrank the guest's actual /22 Wi-Fi subnet.
    add("bridge100", IFF_UP, "0.0.0.0", "0.0.0.0", AF_INET);
    add("en0", IFF_UP, "192.168.68.59", "255.255.252.0", AF_INET);
    CHECK([VMSEPPreferredHost(@[@"192.168.64.1", @"192.168.68.66"]) isEqual:@"192.168.68.66"]);
    reset();
    add("bridge100", IFF_UP, "192.168.64.2", "0.0.0.0", AF_INET);
    add("en0", IFF_UP, "192.168.68.59", "255.255.252.0", AF_INET);
    CHECK([VMSEPPreferredHost(@[@"192.168.64.1", @"192.168.68.66"]) isEqual:@"192.168.68.66"]);
    reset();
    add("bridge100", IFF_UP, "192.168.64.2", "255.0.255.0", AF_INET);
    add("en0", IFF_UP, "192.168.68.59", "255.255.252.0", AF_INET);
    CHECK([VMSEPPreferredHost(@[@"192.168.64.1", @"192.168.68.66"]) isEqual:@"192.168.68.66"]);
    reset();
    add("bridge100", IFF_UP, "192.168.64.2", "255.255.255.0", AF_INET);
    ((struct sockaddr_in *)fixtures[0].ifa_netmask)->sin_family = AF_INET6;
    add("en0", IFF_UP, "192.168.68.59", "255.255.252.0", AF_INET);
    CHECK([VMSEPPreferredHost(@[@"192.168.64.1", @"192.168.68.66"]) isEqual:@"192.168.68.66"]);
    return 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) return 64;
    if (!strcmp(argv[1], "private")) return privateChecks();
    if (!strcmp(argv[1], "interfaces")) return interfaceChecks();
    if (!strcmp(argv[1], "hosts")) return hostChecks();
    if (!strcmp(argv[1], "wifi")) return wifiChecks();
    if (!strcmp(argv[1], "nat")) return natChecks();
    if (!strcmp(argv[1], "candidates")) return candidateChecks();
    if (!strcmp(argv[1], "down")) return downChecks();
    if (!strcmp(argv[1], "incomplete-mask")) return incompleteMaskChecks();
    return 64;
} }
