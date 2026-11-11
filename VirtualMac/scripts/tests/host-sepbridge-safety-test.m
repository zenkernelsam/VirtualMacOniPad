// Offline only: synthetic process records, never a real akd or injector.
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <ifaddrs.h>
#import <net/if.h>

static char tokenPath[4096];
static BOOL mockTokenRoot = YES;
static struct kinfo_proc mockProcesses[3];
static const char *mockPaths[3];
static unsigned mockProcessQueries;
static struct ifaddrs mockInterfaces[6];
static struct sockaddr_in mockAddresses[6];
static BOOL mockNetwork = NO;

static int fixtureGetifaddrs(struct ifaddrs **interfaces) {
    if (!mockNetwork) return getifaddrs(interfaces);
    *interfaces=mockInterfaces;return 0;
}
static void fixtureFreeifaddrs(struct ifaddrs *interfaces) {
    if (interfaces!=mockInterfaces) freeifaddrs(interfaces);
}

static int fixtureFstat(int fd, struct stat *info) {
    int result = fstat(fd, info);
    char path[4096] = {0};
    char canonical[4096] = {0};
    if (!result && mockTokenRoot && !fcntl(fd, F_GETPATH, path) &&
        realpath(tokenPath, canonical) && !strcmp(path, canonical)) info->st_uid = 0;
    return result;
}
static int fixturePidPath(int pid, void *output, uint32_t size) {
    for (int i=0; i<3; i++) if (mockProcesses[i].kp_proc.p_pid == pid) {
        if (!mockPaths[i]) return 0;
        return snprintf(output, size, "%s", mockPaths[i]);
    }
    return 0;
}
static void *fixtureDlsym(void *handle, const char *name) {
    (void)handle;
    return !strcmp(name, "proc_pidpath") ? (void *)fixturePidPath : NULL;
}
static int fixtureSysctl(int *mib, unsigned count, void *oldp, size_t *size,
                         void *newp, size_t newsize) {
    __atomic_fetch_add(&mockProcessQueries, 1, __ATOMIC_RELAXED);
    (void)newp; (void)newsize;
    if (count != 4 || mib[0] != CTL_KERN || mib[1] != KERN_PROC) return -1;
    if (mib[2] == KERN_PROC_ALL) {
        if (!oldp) { *size = sizeof(mockProcesses); return 0; }
        memcpy(oldp, mockProcesses, sizeof(mockProcesses));
        *size = sizeof(mockProcesses); return 0;
    }
    if (mib[2] == KERN_PROC_PID) {
        for (int i=0; i<3; i++) if (mockProcesses[i].kp_proc.p_pid == mib[3]) {
            memcpy(oldp, &mockProcesses[i], sizeof(mockProcesses[i]));
            *size = sizeof(mockProcesses[i]); return 0;
        }
    }
    return -1;
}

#define VMSEP_TOKEN_PATH tokenPath
#define fstat fixtureFstat
#define dlsym fixtureDlsym
#define sysctl fixtureSysctl
#define getifaddrs fixtureGetifaddrs
#define freeifaddrs fixtureFreeifaddrs
#define main productionHelperMain
#include "../../vz/guest/sepbridge-helper.m"
#undef main
#undef fstat
#undef dlsym
#undef sysctl
#undef getifaddrs
#undef freeifaddrs
#include "../../vz/guest/sepinject.m"

static void check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
static NSData *requestData(void) {
    return [NSPropertyListSerialization dataWithPropertyList:
        @{@"sel": @"ping", @"args": @[]} format:NSPropertyListBinaryFormat_v1_0
        options:0 error:NULL];
}
static void storeToken(uint8_t value) {
    uint8_t bytes[32]; memset(bytes, value, sizeof(bytes));
    check([[NSData dataWithBytes:bytes length:sizeof(bytes)]
        writeToFile:@(tokenPath) atomically:YES], "fixture token write");
    check(!chmod(tokenPath,0600),"fixture token permissions");
}
static void rejectedRequest(uint8_t value) {
    int sockets[2]; check(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets),"socket pair");
    uint8_t bytes[32]; memset(bytes,value,sizeof(bytes));
    check(writeAll(sockets[0],bytes,sizeof(bytes)),"send rejected token");
    guestHandle(sockets[1]);
    char byte;
    check(read(sockets[0],&byte,1)==0,"unauthenticated socket closes without reply");
    close(sockets[0]);
}
static void acceptedRequest(uint8_t value) {
    int guest[2], backend[2];
    check(!socketpair(AF_UNIX,SOCK_STREAM,0,guest),"guest sockets");
    check(!socketpair(AF_UNIX,SOCK_STREAM,0,backend),"backend sockets");
    gAkdFd=backend[0];
    NSData *req=requestData();
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    int guestWorker=guest[1], backendWorker=backend[1];
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        uint32_t len=0; check(readAll(backendWorker,&len,4),"backend frame header");
        NSMutableData *incoming=[NSMutableData dataWithLength:ntohl(len)];
        check(readAll(backendWorker,incoming.mutableBytes,incoming.length),"backend frame body");
        check([incoming isEqualToData:req],"token is removed; original frame preserved");
        NSData *reply=[NSPropertyListSerialization dataWithPropertyList:
            @{@"protocol":@2,@"args":@[],@"error":@{@"k":@"nil"}}
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        len=htonl((uint32_t)reply.length);
        check(writeAll(backendWorker,&len,4)&&writeAll(backendWorker,reply.bytes,reply.length),"backend reply");
        close(backendWorker);
    });
    dispatch_async(dispatch_get_global_queue(0,0), ^{
        guestHandle(guestWorker); dispatch_semaphore_signal(done);
    });
    uint8_t token[32]; memset(token,value,sizeof(token));
    uint32_t len=htonl((uint32_t)req.length);
    check(writeAll(guest[0],token,32)&&writeAll(guest[0],&len,4)&&
        writeAll(guest[0],req.bytes,req.length),"authenticated request");
    check(readAll(guest[0],&len,4),"authenticated response header");
    NSMutableData *reply=[NSMutableData dataWithLength:ntohl(len)];
    check(readAll(guest[0],reply.mutableBytes,reply.length),"authenticated response body");
    check(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)),"request completes");
    close(guest[0]);close(backend[0]);gAkdFd=-1;
}

static NSError *readErrorReply(int fd) {
    uint32_t length=0;
    check(readAll(fd,&length,4),"error reply header");
    NSMutableData *body=[NSMutableData dataWithLength:ntohl(length)];
    check(readAll(fd,body.mutableBytes,body.length),"error reply body");
    NSDictionary *reply=[NSPropertyListSerialization propertyListWithData:body
        options:0 format:NULL error:NULL];
    NSDictionary *wrapped=reply[@"error"];
    check([wrapped[@"k"] isEqual:@"nserr"],"error uses portable NSError tag");
    NSDictionary *value=wrapped[@"v"];
    NSError *error=[NSError errorWithDomain:value[@"d"] code:[value[@"c"] integerValue]
        userInfo:value[@"u"]];
    check([error isKindOfClass:NSError.class]&&error.domain.length&&error.code,
        "guest can safely read error domain and code");
    return error;
}

int main(void) { @autoreleasepool {
    for (NSString *address in @[@"10.0.0.1",@"10.255.255.254",@"172.16.0.1",
        @"172.31.255.254",@"192.168.64.1",@"192.168.68.66"])
        check(VMSEPPrivateIPv4(inet_addr(address.UTF8String)),"RFC1918 accepted");
    for (NSString *address in @[@"0.0.0.0",@"8.8.8.8",@"127.0.0.1",
        @"169.254.1.1",@"172.15.255.255",@"172.32.0.1",@"192.169.1.1",@"224.0.0.1"])
        check(!VMSEPPrivateIPv4(inet_addr(address.UTF8String)),"non-private address rejected");
    check(VMSEPInterfaceAllowed("en0",IFF_UP)&&VMSEPInterfaceAllowed("bridge100",IFF_UP)&&
        VMSEPInterfaceAllowed("pdp_ip0",IFF_UP),"allowed interface families");
    check(!VMSEPInterfaceAllowed("en0",0)&&!VMSEPInterfaceAllowed("en0",IFF_UP|IFF_LOOPBACK)&&
        !VMSEPInterfaceAllowed("lo0",IFF_UP)&&!VMSEPInterfaceAllowed("utun2",IFF_UP)&&
        !VMSEPInterfaceAllowed("en",IFF_UP)&&!VMSEPInterfaceAllowed("en_fake",IFF_UP),"down/loopback/other interfaces rejected");
    const char *names[]={"en0","bridge100","pdp_ip0","en1","lo0","utun0"};
    const char *ips[]={"192.168.68.66","192.168.68.66","10.2.0.1","8.8.8.8","127.0.0.1","192.168.2.1"};
    for(int i=0;i<6;i++) {
        mockInterfaces[i].ifa_name=(char *)names[i];mockInterfaces[i].ifa_flags=IFF_UP;
        mockAddresses[i].sin_family=AF_INET;mockAddresses[i].sin_addr.s_addr=inet_addr(ips[i]);
        mockInterfaces[i].ifa_addr=(void *)&mockAddresses[i];
        mockInterfaces[i].ifa_next=i<5?&mockInterfaces[i+1]:NULL;
    }
    mockNetwork=YES;
    NSArray *privateHosts=privateInterfaceAddresses();
    check(privateHosts.count==2&&[privateHosts containsObject:@(inet_addr("192.168.68.66"))]&&
        [privateHosts containsObject:@(inet_addr("10.2.0.1"))],"deduplicated private interface addresses");
    mockNetwork=NO;
    NSMutableDictionary *dynamicListeners=[NSMutableDictionary dictionary];
    NSNumber *loopback=@(htonl(INADDR_LOOPBACK));
    reconcileGuestListeners(dynamicListeners,@[loopback],0);
    int first=[dynamicListeners[loopback] intValue];check(dynamicListeners.count==1,"new address listener");
    reconcileGuestListeners(dynamicListeners,@[loopback],0);
    check([dynamicListeners[loopback] intValue]==first,"unchanged listener preserved");
    reconcileGuestListeners(dynamicListeners,nil,0);
    check(dynamicListeners.count==1,"transient enumeration failure preserves listener");
    reconcileGuestListeners(dynamicListeners,@[],0);
    check(dynamicListeners.count==0&&fcntl(first,F_GETFD)==-1,"disappearing/disabled address closes listener");
    reconcileGuestListeners(dynamicListeners,@[loopback],0);
    check(dynamicListeners.count==1,"later address appearance creates listener");
    reconcileGuestListeners(dynamicListeners,@[],0);
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"vm-host-sep-safety-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    check([NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:NO attributes:nil error:NULL],"fixture directory");
    snprintf(tokenPath,sizeof(tokenPath),"%s/token.bin",directory.fileSystemRepresentation);
    gLock=[NSLock new];
    uint8_t token[32];
    check(!readToken(token),"missing token rejected");
    storeToken(0x19);check(readToken(token)&&token[0]==0x19,"valid token read");
    mockTokenRoot=NO;check(!readToken(token),"non-root token rejected");mockTokenRoot=YES;
    chmod(tokenPath,0644);check(!readToken(token),"non-0600 token rejected");chmod(tokenPath,0600);
    rejectedRequest(0x18);acceptedRequest(0x19);
    storeToken(0x27);rejectedRequest(0x19);acceptedRequest(0x27);
    int errorSockets[2];check(!socketpair(AF_UNIX,SOCK_STREAM,0,errorSockets),"error sockets");
    replyErr(errorSockets[1],@"akd link lost");
    check(readErrorReply(errorSockets[0]).code==ENOTCONN,"bad-link typed error");
    gFd=errorSockets[1];
    runCall(@"eraseAnisetteForDevice:completion:",@[]);
    check(readErrorReply(errorSockets[0]).code==ENOTSUP,"erase returns unsupported error");
    runCall(@"syncAnisetteWithSIMData:device:completion:",@[]);
    check(readErrorReply(errorSockets[0]).code==ENOTSUP,"sync returns unsupported error");
    runCall(@"provisionAnisetteForDevice:completion:",@[]);
    check(readErrorReply(errorSockets[0]).code==ENOTSUP,"unsafe async API rejected");
    close(errorSockets[0]);close(errorSockets[1]);gFd=-1;
    __atomic_store_n(&mockProcessQueries,0,__ATOMIC_RELEASE);
    dispatch_async(dispatch_get_global_queue(0,0), ^{ injectWatchdog(); });
    usleep(100000);
    check(__atomic_load_n(&mockProcessQueries,__ATOMIC_ACQUIRE)==0,
        "idle watchdog does not scan processes or inject");
    for (int i=0;i<3;i++) {
        strcpy(mockProcesses[i].kp_proc.p_comm,"akd");
        mockProcesses[i].kp_proc.p_pid=12001+i;
        mockProcesses[i].kp_eproc.e_ucred.cr_uid=501;
        mockProcesses[i].kp_proc.p_starttime.tv_sec=100+i;
    }
    mockPaths[0]="/var/mobile/macPad/System/Library/PrivateFrameworks/AuthKit.framework/akd";
    mockPaths[1]=VMSEP_NATIVE_AKD_PATH;
    mockPaths[2]=VMSEP_NATIVE_AKD_PATH;mockProcesses[2].kp_eproc.e_ucred.cr_uid=0;
    NativeAkd candidate=findNativeAkd();check(candidate.pid==12002,"native path and UID only");
    check(revalidateAkd(candidate),"native snapshot valid");
    mockProcesses[1].kp_proc.p_starttime.tv_usec=1;
    check(!revalidateAkd(candidate),"PID reuse rejected");
    mockProcesses[1].kp_proc.p_starttime.tv_usec=0;
    mockPaths[1]=NULL;check(findNativeAkd().pid==-1,"unverifiable path rejected");
    mockPaths[1]=VMSEP_NATIVE_AKD_PATH;
    int server=listenOn(0,htonl(INADDR_LOOPBACK));check(server>=0,"loopback listener");
    struct sockaddr_in address={0};socklen_t addressSize=sizeof(address);
    check(!getsockname(server,(struct sockaddr *)&address,&addressSize),"listener address");
    dispatch_async(dispatch_get_global_queue(0,0), ^{ akdLinkThread(server); });
    int peer=socket(AF_INET,SOCK_STREAM,0);check(!connect(peer,(void *)&address,sizeof(address)),"reverse connect");
    uint32_t hello[]={htonl(0x53455031),htonl(12002)};
    writeAll(peer,hello,sizeof(hello));usleep(100000);
    check(gAkdFd==-1,"old reverse protocol rejected");close(peer);
    peer=socket(AF_INET,SOCK_STREAM,0);check(!connect(peer,(void *)&address,sizeof(address)),"macPad reverse connect");
    hello[0]=htonl(0x53455032);hello[1]=htonl(12001);
    writeAll(peer,hello,sizeof(hello));usleep(100000);
    check(gAkdFd==-1,"macPad reverse peer rejected");close(peer);
    peer=socket(AF_INET,SOCK_STREAM,0);check(!connect(peer,(void *)&address,sizeof(address)),"second reverse connect");
    hello[1]=htonl(12002);check(writeAll(peer,hello,sizeof(hello)),"versioned handshake");
    for(int i=0;i<100&&gAkdFd<0;i++)usleep(10000);
    check(gAkdFd>=0,"version 2 native reverse peer accepted");
    printf("PASS private/interface filtering, listener reconciliation, token policy/rotation, typed errors, opaque frames, idle watchdog, native identity and reverse handshake. No injector ran. Fixtures: %s\n",directory.UTF8String);
    return 0;
} }
