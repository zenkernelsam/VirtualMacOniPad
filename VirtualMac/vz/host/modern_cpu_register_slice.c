#include "modern_cpu_register_slice.h"

static int SIMDIndex(hv_simd_fp_reg_t f){return (uint32_t)f<32?(int)f:-1;}
bool VZSliceSIMDEqual(hv_simd_fp_uchar16_t a,hv_simd_fp_uchar16_t b){
    for(unsigned i=0;i<16;++i)if(a[i]!=b[i])return false;
    return true;
}
static bool Equal(unsigned i,VZSliceValue a,VZSliceValue b){return i<32?VZSliceSIMDEqual(a.simd,b.simd):a.sys==b.sys;}
bool VZSliceOwnerValid(const VZSliceOps *o,const VZSliceOwner *s,VZSliceHandle h){
    return o&&o->identityVerified&&o->vmProviderABI==13&&o->vcpuProviderABI==13&&o->currentThread&&
        s&&h.owner==s&&s->owned&&s->idValid&&s->id<64&&s->generation&&
        h.generation==s->generation&&h.id==s->id&&s->ownerThread&&o->currentThread()==s->ownerThread;
}
static bool Guard(VZSliceShadow *s){
    if(!s||s->magic!=VZ_SLICE_MAGIC||s->schemaVersion!=4||!s->bound||!s->ops||
       !s->ops->context||!s->ops->readMemory||!VZSliceOwnerValid(s->ops,s->owner,s->handle)){
        if(s)s->snapshotReady=false;
        return false;
    }
    const void *current=s->ops->context(s->handle.id);uint64_t version=0;
    bool okay=current&&current==s->genuineContext&&s->ops->readMemory((const uint8_t*)current+0x4000,8,&version)&&version==VZ_SLICE_NATIVE_VERSION;
    if(okay)s->versionObserved=version;else s->snapshotReady=false;
    return okay;
}
static VZSliceStatus ReadNative(VZSliceShadow *s,unsigned i,VZSliceValue *out,VZSliceValue *raw,hv_return_t *rc){
    if(!Guard(s))return VZ_SLICE_NOT_READY;
    VZSliceValue actual={0},memory={0};hv_return_t code;
    if(i<32){
        code=s->ops->getSIMD(s->handle.id,(hv_simd_fp_reg_t)i,&actual.simd);
        if(rc)*rc=code;
        if(code)return VZ_SLICE_NATIVE_ERROR;
        if(!s->ops->readMemory((const uint8_t*)s->genuineContext+(0x140+16*i),16,&memory.simd))return VZ_SLICE_MISMATCH;
    }else{
        code=s->ops->getSys(s->handle.id,HV_SYS_REG_SCTLR_EL1,&actual.sys);
        if(rc)*rc=code;
        if(code)return VZ_SLICE_NATIVE_ERROR;
        if(!s->ops->readMemory((const uint8_t*)s->genuineContext+0x400,8,&memory.sys))return VZ_SLICE_MISMATCH;
    }
    if(!Guard(s))return VZ_SLICE_NOT_READY;
    if(out)*out=actual;
    if(raw)*raw=memory;
    return Equal(i,actual,memory)?VZ_SLICE_OK:VZ_SLICE_MISMATCH;
}
static hv_return_t SetNative(VZSliceShadow *s,unsigned i,VZSliceValue value){
    // SDK vector value travels in q0; never substitute a two-word aggregate.
    return i<32?s->ops->setSIMD(s->handle.id,(hv_simd_fp_reg_t)i,value.simd):
        s->ops->setSys(s->handle.id,HV_SYS_REG_SCTLR_EL1,value.sys);
}
VZSliceStatus VZSliceBind(VZSliceShadow *s,const VZSliceOps *o,const VZSliceOwner *owner,VZSliceHandle handle){
    if(!s)return VZ_SLICE_NOT_READY;
    *s=(VZSliceShadow){0};
    if(!o||!o->context||!o->readMemory||!o->getSIMD||!o->setSIMD||!o->getSys||!o->setSys||!VZSliceOwnerValid(o,owner,handle))return VZ_SLICE_NOT_READY;
    const void *context=o->context(handle.id);if(!context)return VZ_SLICE_NOT_READY;
    *s=(VZSliceShadow){.magic=VZ_SLICE_MAGIC,.schemaVersion=4,.bound=true,.ops=o,.owner=owner,.handle=handle,.genuineContext=context};
    VZSliceStatus result=VZSliceRefresh(s);
    if(result==VZ_SLICE_OK)for(unsigned i=0;i<33;++i)s->originalAtBind[i]=s->observed[i];
    return result;
}
VZSliceStatus VZSliceRefresh(VZSliceShadow *s){
    if(!Guard(s))return VZ_SLICE_NOT_READY;
    if(s->pendingMask)return VZ_SLICE_PENDING;
    s->snapshotReady=false;VZSliceValue values[33];
    for(unsigned i=0;i<33;++i){VZSliceStatus code=ReadNative(s,i,&values[i],NULL,NULL);if(code!=VZ_SLICE_OK)return code;}
    if(!Guard(s))return VZ_SLICE_NOT_READY;
    for(unsigned i=0;i<33;++i)s->observed[i]=s->requested[i]=values[i];
    s->snapshotReady=true;return VZ_SLICE_OK;
}
VZSliceStatus VZSliceReadSIMD(VZSliceShadow *s,hv_simd_fp_reg_t f,hv_simd_fp_uchar16_t *value){
    int i=SIMDIndex(f);if(i<0)return VZ_SLICE_UNSUPPORTED;
    if(!value||!Guard(s)||!s->snapshotReady)return VZ_SLICE_NOT_READY;
    *value=s->observed[i].simd;return VZ_SLICE_OK;
}
VZSliceStatus VZSliceReadSCTLR(VZSliceShadow *s,hv_sys_reg_t f,uint64_t *value){
    if(f!=HV_SYS_REG_SCTLR_EL1)return VZ_SLICE_UNSUPPORTED;
    if(!value||!Guard(s)||!s->snapshotReady)return VZ_SLICE_NOT_READY;
    *value=s->observed[32].sys;return VZ_SLICE_OK;
}
static VZSliceStatus Stage(VZSliceShadow *s,unsigned i,VZSliceValue value){
    if(!Guard(s)||!s->snapshotReady)return VZ_SLICE_NOT_READY;
    if(s->pendingMask&&s->pendingMask!=(UINT64_C(1)<<i))return VZ_SLICE_PENDING;
    s->requested[i]=value;s->pendingMask=UINT64_C(1)<<i;return VZ_SLICE_OK;
}
VZSliceStatus VZSliceStageSIMD(VZSliceShadow *s,hv_simd_fp_reg_t f,hv_simd_fp_uchar16_t value){
    int i=SIMDIndex(f);if(i<0)return VZ_SLICE_UNSUPPORTED;
    return Stage(s,(unsigned)i,(VZSliceValue){.simd=value});
}
VZSliceStatus VZSliceStageSCTLR(VZSliceShadow *s,hv_sys_reg_t f,uint64_t value){
    if(f!=HV_SYS_REG_SCTLR_EL1)return VZ_SLICE_UNSUPPORTED;
    if(!Guard(s)||!s->snapshotReady)return VZ_SLICE_NOT_READY;
    // This first SCTLR slice permits the observed production value or exact originals.
    if(value!=UINT64_C(0x30800180)&&value!=s->observed[32].sys&&value!=s->originalAtBind[32].sys)return VZ_SLICE_UNSUPPORTED;
    return Stage(s,32,(VZSliceValue){.sys=value});
}
VZSliceStatus VZSliceRoundTripOne(VZSliceShadow *s,VZSliceResult *r){
    if(!r)return VZ_SLICE_NOT_READY;
    *r=(VZSliceResult){.status=VZ_SLICE_NOT_READY,.saveRC=INT_MIN,.setRC=INT_MIN,.checkRC=INT_MIN,.restoreRC=INT_MIN,.restoredRC=INT_MIN};
    if(!Guard(s)||!s->snapshotReady)return r->status;
    unsigned i=0;while(i<33&&!(s->pendingMask&(UINT64_C(1)<<i)))++i;
    if(i==33||s->pendingMask!=(UINT64_C(1)<<i))return r->status=VZ_SLICE_PENDING;
    r->kind=i<32?VZ_SLICE_SIMD:VZ_SLICE_SYS;r->field=i<32?(uint32_t)(hv_simd_fp_reg_t)i:(uint32_t)HV_SYS_REG_SCTLR_EL1;r->target=s->requested[i];
    VZSliceStatus before=ReadNative(s,i,&r->original,NULL,&r->saveRC);
    if(before!=VZ_SLICE_OK||!Equal(i,r->original,s->observed[i])){s->snapshotReady=false;return r->status=before==VZ_SLICE_OK?VZ_SLICE_MISMATCH:before;}
    r->saved=true;if(!Guard(s))return r->status=VZ_SLICE_NOT_READY;
    r->setAttempted=true;r->setRC=SetNative(s,i,r->target);
    VZSliceStatus after=ReadNative(s,i,&r->publicSet,&r->rawSet,&r->checkRC);
    r->writeVerified=!r->setRC&&after==VZ_SLICE_OK&&Equal(i,r->publicSet,r->target)&&Equal(i,r->rawSet,r->target);
    // Restore on successful writes AND partial writes followed by a native error.
    // If identity/owner/version ceases to be genuine, never call on a foreign CPU.
    if(!Guard(s)){s->snapshotReady=false;return r->status=VZ_SLICE_RESTORE_FAILED;}
    r->restoreAttempted=true;r->restoreRC=SetNative(s,i,r->original);
    VZSliceStatus restored=ReadNative(s,i,&r->publicRestored,&r->rawRestored,&r->restoredRC);
    r->exactRestored=!r->restoreRC&&restored==VZ_SLICE_OK&&Equal(i,r->publicRestored,r->original)&&Equal(i,r->rawRestored,r->original);
    s->snapshotReady=false;
    if(!r->exactRestored)return r->status=VZ_SLICE_RESTORE_FAILED;
    s->pendingMask=0;VZSliceStatus refreshed=VZSliceRefresh(s);r->snapshotRefreshed=refreshed==VZ_SLICE_OK;
    if(!r->writeVerified)return r->status=r->setRC||r->checkRC?VZ_SLICE_NATIVE_ERROR:VZ_SLICE_MISMATCH;
    return r->status=refreshed;
}
VZSliceStatus VZSliceCancelAndRefresh(VZSliceShadow *s){
    if(!Guard(s))return VZ_SLICE_NOT_READY;
    s->pendingMask=0;return VZSliceRefresh(s);
}
