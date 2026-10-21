#include "modern_cpu_scalar_read_bridge.h"
#include <string.h>
// Deliberately describes only the inspected wire storage, not std::expected.
typedef struct {uint8_t bytes[16];} VZ27ScalarWire;
extern void VZ27ScalarReadInvoke(const void*,uint32_t,void*,void*);
static bool Guard(const VZ27ScalarReadOps *ops,const VZ27ScalarReadOps *frozen){
    if(!ops||!frozen||!ops->identityVerified||ops->providerABI!=27||
       !ops->providerEpoch||!ops->thread||!ops->signedEntry||
       !ops->currentThread||!ops->verifyEntry)return false;
    if(ops->identityVerified!=frozen->identityVerified||
       ops->providerABI!=frozen->providerABI||ops->providerEpoch!=frozen->providerEpoch||
       ops->thread!=frozen->thread||ops->signedEntry!=frozen->signedEntry||
       ops->currentThread!=frozen->currentThread||ops->verifyEntry!=frozen->verifyEntry)return false;
    return frozen->currentThread()==frozen->thread&&frozen->verifyEntry(frozen->signedEntry)&&
        ops->identityVerified==frozen->identityVerified&&
        ops->providerABI==frozen->providerABI&&ops->providerEpoch==frozen->providerEpoch&&
        ops->thread==frozen->thread&&ops->signedEntry==frozen->signedEntry&&
        ops->currentThread==frozen->currentThread&&ops->verifyEntry==frozen->verifyEntry&&
        frozen->currentThread()==frozen->thread;
}
bool VZ27ScalarReadCache(const VZ27ScalarReadOps *ops,const void *input,size_t size,
                        uint32_t field,uint64_t *out){
    if(!ops||!input||!out||size<VZ27_SCALAR_CACHE_BYTES||field>=VZ27_SCALAR_READ_COUNT)return false;
    uintptr_t begin=(uintptr_t)input,result=(uintptr_t)out;
    if(begin>UINTPTR_MAX-VZ27_SCALAR_CACHE_BYTES||result>UINTPTR_MAX-sizeof(*out)||
       (result<begin+VZ27_SCALAR_CACHE_BYTES&&begin<result+sizeof(*out)))return false;
    const VZ27ScalarReadOps frozen=*ops;
    if(!Guard(ops,&frozen))return false;
    _Alignas(16) uint8_t cache[VZ27_SCALAR_CACHE_BYTES];
    memcpy(cache,input,sizeof(cache));
    // Only +0x10 is consumed by these 34 audited branches. This bounded holder
    // has no methods/state view; it must never be supplied to any other entry.
    const void *holder[3]={NULL,NULL,cache};
    VZ27ScalarWire wire;memset(&wire,0xa5,sizeof(wire));
    if(!Guard(ops,&frozen))return false;
    VZ27ScalarReadInvoke(holder,field,&wire,frozen.signedEntry);
    if(!Guard(ops,&frozen)||wire.bytes[8]!=1)return false;
    for(unsigned i=9;i<16;++i)if(wire.bytes[i]!=0xa5)return false;
    if(memcmp(cache,input,sizeof(cache)))return false;
    uint64_t value;memcpy(&value,wire.bytes,sizeof(value));
    *out=value;return true;
}
