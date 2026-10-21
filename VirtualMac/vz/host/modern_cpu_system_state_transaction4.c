// Adapted from the verified private 70-field journal; source module unchanged.
#include "modern_cpu_system_state_transaction4.h"
#include <string.h>

const VZSysTxn4Field VZSysTxn4Fields[VZ_SYS_TXN4_FIELD_COUNT]={
    {VZ_TXN_SYS,HV_SYS_REG_TPIDR_EL1,0x358,8},
    {VZ_TXN_SYS,HV_SYS_REG_TPIDR_EL0,0x360,8},
    {VZ_TXN_SYS,HV_SYS_REG_TPIDRRO_EL0,0x368,8},
    {VZ_TXN_SYS,HV_SYS_REG_CSSELR_EL1,0x388,8}
};
const size_t VZSysTxn4DirtyOffsets[VZ_SYS_TXN4_DIRTY_WORD_COUNT]={0x670,0x678,0x748};

static bool Bit(const uint64_t mask[2],unsigned i){return i<4&&(mask[i/64]&(UINT64_C(1)<<(i%64)));}
static void PutBit(uint64_t mask[2],unsigned i){mask[i/64]|=UINT64_C(1)<<(i%64);}
static void ClearBit(uint64_t mask[2],unsigned i){mask[i/64]&=~(UINT64_C(1)<<(i%64));}
static bool Any(const uint64_t mask[2]){return mask[0]||mask[1];}
static bool MaskLegal(const uint64_t mask[2]){return !mask[1]&&!(mask[0]&~UINT64_C(0xf));}
bool VZSysTxn4ValueEqual(unsigned i,VZSysTxn4Value a,VZSysTxn4Value b){
    if(i>=VZ_SYS_TXN4_FIELD_COUNT)return false;
    return a.scalar==b.scalar;
}
static bool ValuesEqual(const VZSysTxn4Value a[4],const VZSysTxn4Value b[4]){
    for(unsigned i=0;i<4;++i)if(!VZSysTxn4ValueEqual(i,a[i],b[i]))return false;
    return true;
}
static bool DirtyEqual(const uint64_t a[3],const uint64_t b[3]){
    for(unsigned i=0;i<3;++i)if(a[i]!=b[i])return false;
    return true;
}
static int Index(VZSysTxn4Kind kind,uint32_t field){
    for(unsigned i=0;i<4;++i)if(VZSysTxn4Fields[i].kind==kind&&VZSysTxn4Fields[i].field==field)return (int)i;
    return -1;
}
bool VZSysTxn4OwnerValid(const VZSysTxn4Ops *o,const VZSysTxn4Owner *s,VZSysTxn4Handle h){
    return o&&o->identityVerified&&o->vmProviderABI==13&&o->vcpuProviderABI==13&&
        o->providerEpoch&&o->currentThread&&s&&h.owner==s&&s->owned&&s->idValid&&
        s->id<64&&h.id==s->id&&s->generation&&h.generation==s->generation&&
        s->leaseEpoch&&h.leaseEpoch==s->leaseEpoch&&s->stateEpoch&&s->ownerThread&&
        o->currentThread()==s->ownerThread&&s->neverRun&&!s->quarantined;
}
static bool CallbacksStable(const VZSysTxn4 *t){
    return t&&t->ops&&t->ops->context&&t->ops->readMemory&&t->ops->currentThread&&
       t->ops->getSys&&t->ops->setSys&&
       t->ops->context==t->frozenOps.context&&t->ops->readMemory==t->frozenOps.readMemory&&
       t->ops->currentThread==t->frozenOps.currentThread&&
       t->ops->getSys==t->frozenOps.getSys&&t->ops->setSys==t->frozenOps.setSys;
}
static bool Guard(VZSysTxn4 *t){
    if(!t||t->magic!=VZ_SYS_TXN4_MAGIC||t->state==VZ_TXN_UNBOUND||t->state==VZ_TXN_POISON_STATE||
       !CallbacksStable(t)||
       !VZSysTxn4OwnerValid(t->ops,t->owner,t->handle)||t->owner->activeLease!=t||
       t->ops->providerEpoch!=t->providerEpoch||t->owner->stateEpoch!=t->ownerStateEpoch)return false;
    const void *current=t->frozenOps.context(t->handle.id);uint64_t version=0;
    return current&&current==t->genuineContext&&
        t->frozenOps.readMemory((const uint8_t*)current+0x4000,8,&version)&&version==VZ_SYS_TXN4_NATIVE_VERSION&&
        CallbacksStable(t)&&VZSysTxn4OwnerValid(t->ops,t->owner,t->handle)&&t->owner->activeLease==t&&
        t->ops->providerEpoch==t->providerEpoch&&t->owner->stateEpoch==t->ownerStateEpoch&&CallbacksStable(t);
}
static void Poison(VZSysTxn4 *t,VZSysTxn4Result *r){
    if(!t)return;
    // Only mark the local owner record if it still names this exact lifetime.
    // No native API, owner/epoch reset, or foreign lifetime mutation is allowed.
    if(t->owner&&t->frozenOps.currentThread&&
       t->owner->activeLease==t&&t->owner->id==t->handle.id&&
       t->owner->generation==t->handle.generation&&t->owner->leaseEpoch==t->handle.leaseEpoch&&
       t->frozenOps.currentThread()==t->owner->ownerThread){t->owner->quarantined=true;if(r)r->quarantined=true;}
    t->state=VZ_TXN_POISON_STATE;
}
static VZSysTxn4Status ReadNative(VZSysTxn4 *t,unsigned i,VZSysTxn4Value *out){
    if(i>=4)return VZ_TXN_UNSUPPORTED;
    if(!Guard(t))return VZ_TXN_NOT_READY;
    const VZSysTxn4Field *f=&VZSysTxn4Fields[i];VZSysTxn4Value actual={0},raw={0};hv_return_t rc;
    rc=t->ops->getSys(t->handle.id,(hv_sys_reg_t)f->field,&actual.scalar);
    if(rc)return VZ_TXN_NATIVE_ERROR;
    if(!Guard(t))return VZ_TXN_NOT_READY;
    // Read-only old native slot is cross-checked against the genuine typed API.
    if(!t->frozenOps.readMemory((const uint8_t*)t->genuineContext+f->offset,f->width,&raw))return VZ_TXN_MISMATCH;
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(!VZSysTxn4ValueEqual(i,actual,raw))return VZ_TXN_MISMATCH;
    if(out)*out=actual;
    return VZ_TXN_OK;
}
static hv_return_t SetNative(VZSysTxn4 *t,unsigned i,VZSysTxn4Value v){
    const VZSysTxn4Field *f=&VZSysTxn4Fields[i];
    // All four fields use the real SDK scalar system-register ABI.
    return t->ops->setSys(t->handle.id,(hv_sys_reg_t)f->field,v.scalar);
}
static VZSysTxn4Status ReadDirty(VZSysTxn4 *t,uint64_t values[3]){
    if(!Guard(t))return VZ_TXN_NOT_READY;
    for(unsigned i=0;i<3;++i){
        if(!Guard(t))return VZ_TXN_NOT_READY;
        if(!t->frozenOps.readMemory((const uint8_t*)t->genuineContext+VZSysTxn4DirtyOffsets[i],8,&values[i]))return VZ_TXN_MISMATCH;
        if(!Guard(t))return VZ_TXN_NOT_READY;
    }
    return Guard(t)?VZ_TXN_OK:VZ_TXN_NOT_READY;
}
VZSysTxn4Status VZSysTxn4Observe(VZSysTxn4 *t,VZSysTxn4Value values[4],uint64_t dirty[3]){
    if(!values||!dirty)return VZ_TXN_NOT_READY;
    uint64_t before[3],after[3];VZSysTxn4Value actual[4];
    VZSysTxn4Status code=ReadDirty(t,before);if(code!=VZ_TXN_OK)return code;
    for(unsigned i=0;i<4;++i){code=ReadNative(t,i,&actual[i]);if(code!=VZ_TXN_OK)return code;}
    code=ReadDirty(t,after);if(code!=VZ_TXN_OK)return code;
    if(!DirtyEqual(before,after))return VZ_TXN_CONFLICT;
    memcpy(values,actual,sizeof(actual));memcpy(dirty,after,sizeof(after));return VZ_TXN_OK;
}
VZSysTxn4Status VZSysTxn4Bind(VZSysTxn4 *t,const VZSysTxn4Ops *o,VZSysTxn4Owner *s,VZSysTxn4Handle h){
    if(!t)return VZ_TXN_NOT_READY;
    // Rebinding a live transaction would discard its journal and is forbidden.
    // Storage is explicitly zero-initialized by the caller; never read unknown
    // automatic storage or erase a live journal because another owner was given.
    if(t->magic||t->state!=VZ_TXN_UNBOUND)return VZ_TXN_PENDING;
    if(!o||!o->context||!o->readMemory||
       !o->getSys||!o->setSys||!VZSysTxn4OwnerValid(o,s,h))return VZ_TXN_NOT_READY;
    if(s->activeLease)return VZ_TXN_PENDING;
    VZSysTxn4Ops frozen=*o;const void *context=frozen.context(h.id);
    VZSysTxn4 check={.ops=o,.frozenOps=frozen};
    if(!context||!CallbacksStable(&check)||!VZSysTxn4OwnerValid(o,s,h)||s->activeLease)return VZ_TXN_NOT_READY;
    *t=(VZSysTxn4){.magic=VZ_SYS_TXN4_MAGIC,.state=VZ_TXN_BOUND,.ops=o,.frozenOps=frozen,.owner=s,.handle=h,
        .genuineContext=context,.providerEpoch=frozen.providerEpoch,.ownerStateEpoch=s->stateEpoch};
    s->activeLease=t;VZSysTxn4Status code=ReadNative(t,VZ_SYS_TXN4_CSSELR_INDEX,&t->originalCSSELR);
    if(code!=VZ_TXN_OK){
        if(s->activeLease==t&&s->generation==h.generation&&s->leaseEpoch==h.leaseEpoch&&
           s->id==h.id&&t->frozenOps.currentThread()==s->ownerThread)s->activeLease=NULL;
        *t=(VZSysTxn4){0};
    }
    return code;
}
VZSysTxn4Status VZSysTxn4Snapshot(VZSysTxn4 *t){
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(t->state==VZ_TXN_COMMIT_STATE)return VZ_TXN_COMMITTED;
    if(Any(t->pending))return VZ_TXN_PENDING;
    if(t->snapshotSerial==UINT64_MAX)return VZ_TXN_EPOCH_EXHAUSTED;
    VZSysTxn4Value values[4];uint64_t dirty[3];VZSysTxn4Status code=VZSysTxn4Observe(t,values,dirty);
    if(code!=VZ_TXN_OK)return code;
    memcpy(t->baseline,values,sizeof(values));memcpy(t->requested,values,sizeof(values));
    memcpy(t->snapshotDirty,dirty,sizeof(dirty));memset(t->committed,0,sizeof(t->committed));
    memset(t->attempted,0,sizeof(t->attempted));++t->snapshotSerial;t->state=VZ_TXN_SNAPSHOT;
    return VZ_TXN_OK;
}
static VZSysTxn4Status Stage(VZSysTxn4 *t,VZSysTxn4Kind kind,uint32_t field,VZSysTxn4Value value){
    int index=Index(kind,field);if(index<0)return VZ_TXN_UNSUPPORTED;
    unsigned i=(unsigned)index;
    if(VZSysTxn4Fields[i].width==4&&value.scalar>UINT32_MAX)return VZ_TXN_UNSUPPORTED;
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(t->state==VZ_TXN_COMMIT_STATE)return VZ_TXN_COMMITTED;
    if(t->state!=VZ_TXN_SNAPSHOT&&t->state!=VZ_TXN_STAGED)return VZ_TXN_NOT_READY;
    if(i==VZ_SYS_TXN4_CSSELR_INDEX&&value.scalar>UINT64_C(0xf)&&
       value.scalar!=t->baseline[i].scalar&&value.scalar!=t->originalCSSELR.scalar)return VZ_TXN_UNSUPPORTED;
    if(!MaskLegal(t->pending))return VZ_TXN_NOT_READY;
    t->requested[i]=value;
    if(VZSysTxn4ValueEqual(i,value,t->baseline[i]))ClearBit(t->pending,i);else PutBit(t->pending,i);
    t->state=Any(t->pending)?VZ_TXN_STAGED:VZ_TXN_SNAPSHOT;return VZ_TXN_OK;
}
VZSysTxn4Status VZSysTxn4StageSys(VZSysTxn4 *t,hv_sys_reg_t f,uint64_t v){return Stage(t,VZ_TXN_SYS,(uint32_t)f,(VZSysTxn4Value){.scalar=v});}
VZSysTxn4Status VZSysTxn4CancelStaged(VZSysTxn4 *t){
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(t->state==VZ_TXN_COMMIT_STATE)return VZ_TXN_COMMITTED;
    if(t->state!=VZ_TXN_SNAPSHOT&&t->state!=VZ_TXN_STAGED)return VZ_TXN_NOT_READY;
    memcpy(t->requested,t->baseline,sizeof(t->baseline));memset(t->pending,0,sizeof(t->pending));
    t->state=VZ_TXN_SNAPSHOT;return VZ_TXN_OK;
}
static bool StartResult(VZSysTxn4 *t,VZSysTxn4Result *r){
    if(!r)return false;
    *r=(VZSysTxn4Result){.status=VZ_TXN_NOT_READY,.triggerStatus=VZ_TXN_OK,.failedIndex=-1,
        .setRC=INT_MIN,.restoreRC=INT_MIN};
    if(t&&t->owner){r->ownerEpochBefore=t->ownerStateEpoch;r->ownerEpochAfter=t->owner->stateEpoch;}
    return true;
}
static void ReportDirty(VZSysTxn4 *t,VZSysTxn4Result *r,const uint64_t after[3]){
    memcpy(r->dirtyBefore,t->snapshotDirty,sizeof(r->dirtyBefore));
    memcpy(r->dirtyAfter,after,sizeof(r->dirtyAfter));r->dirtyObserved=true;
    r->nativeDirtyExactlyRestored=DirtyEqual(t->snapshotDirty,after);
}
static bool AdvanceEpoch(VZSysTxn4 *t,VZSysTxn4Result *r){
    if(!Guard(t)||t->ownerStateEpoch==UINT64_MAX)return false;
    ++t->owner->stateEpoch;t->ownerStateEpoch=t->owner->stateEpoch;r->ownerEpochAfter=t->ownerStateEpoch;
    return true;
}
static VZSysTxn4Status RestoreAttempted(VZSysTxn4 *t,VZSysTxn4Result *r,VZSysTxn4Status trigger){
    r->triggerStatus=trigger;memcpy(r->attempted,t->attempted,sizeof(r->attempted));
    bool allSettersOkay=true;
    // The failing setter is in attempted before its invocation, even if it
    // returned an error after writing bytes. Restore it, then prior fields.
    for(unsigned cursor=4;cursor>0;--cursor){unsigned i=cursor-1;if(!Bit(t->attempted,i))continue;
        if(!Guard(t)){r->foreignRestoreBlocked=true;Poison(t,r);return r->status=VZ_TXN_RESTORE_FAILED;}
        PutBit(r->restoreAttempted,i);hv_return_t rc=SetNative(t,i,t->baseline[i]);
        if(rc){allSettersOkay=false;r->restoreRC=rc;}else if(r->restoreRC==INT_MIN)r->restoreRC=0;
        if(!Guard(t)){r->foreignRestoreBlocked=true;Poison(t,r);return r->status=VZ_TXN_RESTORE_FAILED;}
        VZSysTxn4Value value;VZSysTxn4Status read=ReadNative(t,i,&value);
        if(read!=VZ_TXN_OK||!VZSysTxn4ValueEqual(i,value,t->baseline[i]))allSettersOkay=false;
        // A native restore error does not skip remaining same-owner originals.
    }
    VZSysTxn4Value values[4];uint64_t dirty[3];VZSysTxn4Status observed=VZSysTxn4Observe(t,values,dirty);
    r->restoreCallsSucceeded=allSettersOkay;
    r->registerValuesExactlyRestored=allSettersOkay&&observed==VZ_TXN_OK&&ValuesEqual(values,t->baseline);
    if(observed==VZ_TXN_OK)ReportDirty(t,r,dirty);
    if(!r->registerValuesExactlyRestored||!AdvanceEpoch(t,r)){
        if(!Guard(t))r->foreignRestoreBlocked=true;
        Poison(t,r);return r->status=VZ_TXN_RESTORE_FAILED;
    }
    memset(t->pending,0,sizeof(t->pending));memset(t->attempted,0,sizeof(t->attempted));
    memcpy(t->requested,t->baseline,sizeof(t->baseline));t->state=VZ_TXN_RECOVERED;
    return r->status=trigger;
}
static VZSysTxn4Status Preflight(VZSysTxn4 *t,const VZSysTxn4Value expected[4],const uint64_t dirtyExpected[3]){
    VZSysTxn4Value values[4];uint64_t dirty[3];VZSysTxn4Status code=VZSysTxn4Observe(t,values,dirty);
    if(code!=VZ_TXN_OK)return code;
    return ValuesEqual(values,expected)&&DirtyEqual(dirty,dirtyExpected)?VZ_TXN_OK:VZ_TXN_CONFLICT;
}
VZSysTxn4Status VZSysTxn4Commit(VZSysTxn4 *t,VZSysTxn4Result *r){
    if(!StartResult(t,r))return VZ_TXN_NOT_READY;
    if(!Guard(t))return r->status;
    if(t->state==VZ_TXN_COMMIT_STATE)return r->status=VZ_TXN_COMMITTED;
    if(t->state!=VZ_TXN_STAGED||!Any(t->pending)||!MaskLegal(t->pending))return r->status=VZ_TXN_PENDING;
    if(t->ownerStateEpoch==UINT64_MAX)return r->status=VZ_TXN_EPOCH_EXHAUSTED;
    VZSysTxn4Status code=Preflight(t,t->baseline,t->snapshotDirty);
    if(code!=VZ_TXN_OK)return r->status=code;
    memset(t->attempted,0,sizeof(t->attempted));
    for(unsigned i=0;i<4;++i){if(!Bit(t->pending,i))continue;
        if(!Guard(t))return RestoreAttempted(t,r,VZ_TXN_NOT_READY);
        PutBit(t->attempted,i);r->setRC=SetNative(t,i,t->requested[i]);
        if(!Guard(t)){r->failedIndex=(int)i;return RestoreAttempted(t,r,VZ_TXN_NOT_READY);}
        VZSysTxn4Value value;code=ReadNative(t,i,&value);
        if(r->setRC||code!=VZ_TXN_OK||!VZSysTxn4ValueEqual(i,value,t->requested[i])){
            r->failedIndex=(int)i;
            return RestoreAttempted(t,r,r->setRC?VZ_TXN_NATIVE_ERROR:code==VZ_TXN_OK?VZ_TXN_MISMATCH:code);
        }
    }
    VZSysTxn4Value values[4];uint64_t dirty[3];code=VZSysTxn4Observe(t,values,dirty);
    if(code!=VZ_TXN_OK||!ValuesEqual(values,t->requested))return RestoreAttempted(t,r,code==VZ_TXN_OK?VZ_TXN_MISMATCH:code);
    if(!AdvanceEpoch(t,r))return RestoreAttempted(t,r,VZ_TXN_NOT_READY);
    memcpy(t->committed,values,sizeof(values));memcpy(t->committedDirty,dirty,sizeof(dirty));
    memcpy(r->attempted,t->attempted,sizeof(r->attempted));ReportDirty(t,r,dirty);
    t->state=VZ_TXN_COMMIT_STATE;r->valuesCommitted=true;r->fullReadbackVerified=true;
    return r->status=VZ_TXN_OK;
}
VZSysTxn4Status VZSysTxn4Verify(VZSysTxn4 *t,VZSysTxn4Result *r){
    if(!StartResult(t,r))return VZ_TXN_NOT_READY;
    if(!Guard(t))return r->status;
    if(t->state!=VZ_TXN_COMMIT_STATE)return r->status=VZ_TXN_NOT_READY;
    VZSysTxn4Status code=Preflight(t,t->committed,t->committedDirty);
    if(code!=VZ_TXN_OK)return r->status=code;
    memcpy(r->attempted,t->attempted,sizeof(r->attempted));ReportDirty(t,r,t->committedDirty);
    r->valuesCommitted=true;r->fullReadbackVerified=true;return r->status=VZ_TXN_OK;
}
VZSysTxn4Status VZSysTxn4Restore(VZSysTxn4 *t,VZSysTxn4Result *r){
    if(!StartResult(t,r))return VZ_TXN_NOT_READY;
    if(!Guard(t))return r->status;
    if(t->state!=VZ_TXN_COMMIT_STATE||!MaskLegal(t->attempted))return r->status=VZ_TXN_NOT_READY;
    if(t->ownerStateEpoch==UINT64_MAX)return r->status=VZ_TXN_EPOCH_EXHAUSTED;
    VZSysTxn4Status code=Preflight(t,t->committed,t->committedDirty);
    if(code!=VZ_TXN_OK)return r->status=code;
    return RestoreAttempted(t,r,VZ_TXN_OK);
}
VZSysTxn4Status VZSysTxn4Release(VZSysTxn4 *t){
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(t->state==VZ_TXN_COMMIT_STATE)return VZ_TXN_COMMITTED;
    if(Any(t->pending))return VZ_TXN_PENDING;
    t->owner->activeLease=NULL;*t=(VZSysTxn4){0};return VZ_TXN_OK;
}
