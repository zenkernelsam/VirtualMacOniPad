#include "modern_cpu_scalar_slice.h"
#define REG(n,o,w) {VZ_SCALAR_REG,n,o,w}
const VZScalarField VZScalarFields[VZ_SCALAR_FIELD_COUNT]={
    REG(0,0x8,8),REG(1,0x10,8),REG(2,0x18,8),REG(3,0x20,8),
    REG(4,0x28,8),REG(5,0x30,8),REG(6,0x38,8),REG(7,0x40,8),
    REG(8,0x48,8),REG(9,0x50,8),REG(10,0x58,8),REG(11,0x60,8),
    REG(12,0x68,8),REG(13,0x70,8),REG(14,0x78,8),REG(15,0x80,8),
    REG(16,0x88,8),REG(17,0x90,8),REG(18,0x98,8),REG(19,0xa0,8),
    REG(20,0xa8,8),REG(21,0xb0,8),REG(22,0xb8,8),REG(23,0xc0,8),
    REG(24,0xc8,8),REG(25,0xd0,8),REG(26,0xd8,8),REG(27,0xe0,8),
    REG(28,0xe8,8),REG(29,0xf0,8),REG(30,0xf8,8),REG(31,0x108,8),
    REG(32,0x344,4),REG(33,0x340,4),
    {VZ_SCALAR_SYS,HV_SYS_REG_SP_EL0,0x370,8},
    {VZ_SCALAR_SYS,HV_SYS_REG_SP_EL1,0x378,8}
};
#undef REG
static int Index(VZScalarKind kind,uint32_t field){
    for(unsigned i=0;i<VZ_SCALAR_FIELD_COUNT;++i)if(VZScalarFields[i].kind==kind&&VZScalarFields[i].field==field)return (int)i;
    return -1;
}
bool VZScalarOwnerValid(const VZScalarOps *o,const VZScalarOwner *s,VZScalarHandle h){
    return o&&o->identityVerified&&o->vmProviderABI==13&&o->vcpuProviderABI==13&&o->currentThread&&
        s&&h.owner==s&&s->owned&&s->idValid&&s->id<64&&s->generation&&
        h.generation==s->generation&&h.id==s->id&&s->ownerThread&&o->currentThread()==s->ownerThread;
}
static bool Guard(VZScalarShadow *s){
    if(!s||s->magic!=VZ_SCALAR_MAGIC||s->schemaVersion!=5||!s->bound||!s->ops||
       !s->ops->context||!s->ops->readMemory||!VZScalarOwnerValid(s->ops,s->owner,s->handle)){
        if(s)s->snapshotReady=false;
        return false;
    }
    const void *current=s->ops->context(s->handle.id);uint64_t version=0;
    bool okay=current&&current==s->genuineContext&&s->ops->readMemory((const uint8_t*)current+0x4000,8,&version)&&version==VZ_SCALAR_NATIVE_VERSION;
    if(okay)s->versionObserved=version;else s->snapshotReady=false;
    return okay;
}
static VZScalarStatus ReadNative(VZScalarShadow *s,unsigned i,uint64_t *out,uint64_t *raw,hv_return_t *rc){
    if(!Guard(s))return VZ_SCALAR_NOT_READY;
    const VZScalarField *f=&VZScalarFields[i];uint64_t actual=0,memory=0;
    hv_return_t code=f->kind==VZ_SCALAR_REG?s->ops->getReg(s->handle.id,(hv_reg_t)f->field,&actual):
        s->ops->getSys(s->handle.id,(hv_sys_reg_t)f->field,&actual);
    if(rc)*rc=code;
    if(code)return VZ_SCALAR_NATIVE_ERROR;
    // Zero extension is explicit for FPCR/FPSR; never read adjacent raw bytes.
    if(!s->ops->readMemory((const uint8_t*)s->genuineContext+f->offset,f->width,&memory))return VZ_SCALAR_MISMATCH;
    if(!Guard(s))return VZ_SCALAR_NOT_READY;
    if(out)*out=actual;if(raw)*raw=memory;
    return actual==memory?VZ_SCALAR_OK:VZ_SCALAR_MISMATCH;
}
static hv_return_t SetNative(VZScalarShadow *s,unsigned i,uint64_t value){
    const VZScalarField *f=&VZScalarFields[i];
    return f->kind==VZ_SCALAR_REG?s->ops->setReg(s->handle.id,(hv_reg_t)f->field,value):
        s->ops->setSys(s->handle.id,(hv_sys_reg_t)f->field,value);
}
VZScalarStatus VZScalarBind(VZScalarShadow *s,const VZScalarOps *o,const VZScalarOwner *owner,VZScalarHandle handle){
    if(!s)return VZ_SCALAR_NOT_READY;
    *s=(VZScalarShadow){0};
    if(!o||!o->context||!o->readMemory||!o->getReg||!o->setReg||!o->getSys||!o->setSys||!VZScalarOwnerValid(o,owner,handle))return VZ_SCALAR_NOT_READY;
    const void *context=o->context(handle.id);if(!context)return VZ_SCALAR_NOT_READY;
    *s=(VZScalarShadow){.magic=VZ_SCALAR_MAGIC,.schemaVersion=5,.bound=true,.ops=o,.owner=owner,.handle=handle,.genuineContext=context};
    VZScalarStatus result=VZScalarRefresh(s);
    if(result==VZ_SCALAR_OK)for(unsigned i=0;i<VZ_SCALAR_FIELD_COUNT;++i)s->originalAtBind[i]=s->observed[i];
    return result;
}
VZScalarStatus VZScalarRefresh(VZScalarShadow *s){
    if(!Guard(s))return VZ_SCALAR_NOT_READY;
    if(s->pendingMask)return VZ_SCALAR_PENDING;
    s->snapshotReady=false;uint64_t values[VZ_SCALAR_FIELD_COUNT];
    for(unsigned i=0;i<VZ_SCALAR_FIELD_COUNT;++i){VZScalarStatus code=ReadNative(s,i,&values[i],NULL,NULL);if(code!=VZ_SCALAR_OK)return code;}
    if(!Guard(s))return VZ_SCALAR_NOT_READY;
    for(unsigned i=0;i<VZ_SCALAR_FIELD_COUNT;++i)s->observed[i]=s->requested[i]=values[i];
    s->snapshotReady=true;return VZ_SCALAR_OK;
}
static VZScalarStatus Read(VZScalarShadow *s,VZScalarKind kind,uint32_t field,uint64_t *value){
    int i=Index(kind,field);if(i<0)return VZ_SCALAR_UNSUPPORTED;
    if(!value||!Guard(s)||!s->snapshotReady)return VZ_SCALAR_NOT_READY;
    *value=s->observed[i];return VZ_SCALAR_OK;
}
VZScalarStatus VZScalarReadReg(VZScalarShadow *s,hv_reg_t field,uint64_t *value){return Read(s,VZ_SCALAR_REG,(uint32_t)field,value);}
VZScalarStatus VZScalarReadSP(VZScalarShadow *s,hv_sys_reg_t field,uint64_t *value){return Read(s,VZ_SCALAR_SYS,(uint32_t)field,value);}
static VZScalarStatus Stage(VZScalarShadow *s,VZScalarKind kind,uint32_t field,uint64_t value){
    int i=Index(kind,field);if(i<0)return VZ_SCALAR_UNSUPPORTED;
    if(VZScalarFields[i].width==4&&value>UINT32_MAX)return VZ_SCALAR_UNSUPPORTED;
    if(!Guard(s)||!s->snapshotReady)return VZ_SCALAR_NOT_READY;
    if(s->pendingMask&&s->pendingMask!=(UINT64_C(1)<<(unsigned)i))return VZ_SCALAR_PENDING;
    s->requested[i]=value;s->pendingMask=UINT64_C(1)<<(unsigned)i;return VZ_SCALAR_OK;
}
VZScalarStatus VZScalarStageReg(VZScalarShadow *s,hv_reg_t field,uint64_t value){return Stage(s,VZ_SCALAR_REG,(uint32_t)field,value);}
VZScalarStatus VZScalarStageSP(VZScalarShadow *s,hv_sys_reg_t field,uint64_t value){return Stage(s,VZ_SCALAR_SYS,(uint32_t)field,value);}
VZScalarStatus VZScalarRoundTripOne(VZScalarShadow *s,VZScalarResult *r){
    if(!r)return VZ_SCALAR_NOT_READY;
    *r=(VZScalarResult){.status=VZ_SCALAR_NOT_READY,.saveRC=INT_MIN,.setRC=INT_MIN,.checkRC=INT_MIN,.restoreRC=INT_MIN,.restoredRC=INT_MIN};
    if(!Guard(s)||!s->snapshotReady)return r->status;
    unsigned i=0;while(i<VZ_SCALAR_FIELD_COUNT&&!(s->pendingMask&(UINT64_C(1)<<i)))++i;
    if(i==VZ_SCALAR_FIELD_COUNT||s->pendingMask!=(UINT64_C(1)<<i))return r->status=VZ_SCALAR_PENDING;
    const VZScalarField *f=&VZScalarFields[i];r->kind=f->kind;r->field=f->field;r->target=s->requested[i];
    VZScalarStatus before=ReadNative(s,i,&r->original,NULL,&r->saveRC);
    if(before!=VZ_SCALAR_OK||r->original!=s->observed[i]){s->snapshotReady=false;return r->status=before==VZ_SCALAR_OK?VZ_SCALAR_MISMATCH:before;}
    r->saved=true;if(!Guard(s))return r->status=VZ_SCALAR_NOT_READY;
    r->setAttempted=true;r->setRC=SetNative(s,i,r->target);
    VZScalarStatus after=ReadNative(s,i,&r->publicSet,&r->rawSet,&r->checkRC);
    r->writeVerified=!r->setRC&&after==VZ_SCALAR_OK&&r->publicSet==r->target&&r->rawSet==r->target;
    // Restore on successful writes and on native errors after a partial write.
    // Ownership loss forbids calling a setter on a foreign or expired CPU.
    if(!Guard(s)){s->snapshotReady=false;return r->status=VZ_SCALAR_RESTORE_FAILED;}
    r->restoreAttempted=true;r->restoreRC=SetNative(s,i,r->original);
    VZScalarStatus restored=ReadNative(s,i,&r->publicRestored,&r->rawRestored,&r->restoredRC);
    r->exactRestored=!r->restoreRC&&restored==VZ_SCALAR_OK&&r->publicRestored==r->original&&r->rawRestored==r->original;
    s->snapshotReady=false;
    if(!r->exactRestored)return r->status=VZ_SCALAR_RESTORE_FAILED;
    s->pendingMask=0;VZScalarStatus refreshed=VZScalarRefresh(s);r->snapshotRefreshed=refreshed==VZ_SCALAR_OK;
    if(!r->writeVerified)return r->status=r->setRC||r->checkRC?VZ_SCALAR_NATIVE_ERROR:VZ_SCALAR_MISMATCH;
    return r->status=refreshed;
}
VZScalarStatus VZScalarCancelAndRefresh(VZScalarShadow *s){
    if(!Guard(s))return VZ_SCALAR_NOT_READY;
    s->pendingMask=0;return VZScalarRefresh(s);
}
