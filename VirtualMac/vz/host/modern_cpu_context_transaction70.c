#include "modern_cpu_context_transaction70.h"
#include <string.h>

#define Q(n) {VZ_TXN_SIMD,n,0x140+16*(n),16}
#define X(n) {VZ_TXN_REG,n,0x8+8*(n),8}
const VZTxn70Field VZTxn70Fields[VZ_TXN70_FIELD_COUNT]={
    Q(0),Q(1),Q(2),Q(3),Q(4),Q(5),Q(6),Q(7),Q(8),Q(9),Q(10),Q(11),
    Q(12),Q(13),Q(14),Q(15),Q(16),Q(17),Q(18),Q(19),Q(20),Q(21),Q(22),Q(23),
    Q(24),Q(25),Q(26),Q(27),Q(28),Q(29),Q(30),Q(31),
    {VZ_TXN_SYS,HV_SYS_REG_SCTLR_EL1,0x400,8},
    X(0),X(1),X(2),X(3),X(4),X(5),X(6),X(7),X(8),X(9),X(10),X(11),
    X(12),X(13),X(14),X(15),X(16),X(17),X(18),X(19),X(20),X(21),X(22),X(23),
    X(24),X(25),X(26),X(27),X(28),X(29),X(30),
    {VZ_TXN_REG,HV_REG_PC,0x108,8},
    {VZ_TXN_REG,HV_REG_FPCR,0x344,4},
    {VZ_TXN_REG,HV_REG_FPSR,0x340,4},
    {VZ_TXN_SYS,HV_SYS_REG_SP_EL0,0x370,8},
    {VZ_TXN_SYS,HV_SYS_REG_SP_EL1,0x378,8},
    {VZ_TXN_REG,HV_REG_CPSR,0x110,4}
};
#undef Q
#undef X
const size_t VZTxn70DirtyOffsets[VZ_TXN70_DIRTY_WORD_COUNT]={0x670,0x678,0x748};

static bool Bit(const uint64_t mask[2],unsigned i){return i<70&&(mask[i/64]&(UINT64_C(1)<<(i%64)));}
static void PutBit(uint64_t mask[2],unsigned i){mask[i/64]|=UINT64_C(1)<<(i%64);}
static void ClearBit(uint64_t mask[2],unsigned i){mask[i/64]&=~(UINT64_C(1)<<(i%64));}
static bool Any(const uint64_t mask[2]){return mask[0]||mask[1];}
static bool MaskLegal(const uint64_t mask[2]){return !(mask[1]&~UINT64_C(0x3f));}
bool VZTxn70ValueEqual(unsigned i,VZTxn70Value a,VZTxn70Value b){
    if(i>=VZ_TXN70_FIELD_COUNT)return false;
    if(i>=32)return a.scalar==b.scalar;
    for(unsigned j=0;j<16;++j)if(a.simd[j]!=b.simd[j])return false;
    return true;
}
static bool ValuesEqual(const VZTxn70Value a[70],const VZTxn70Value b[70]){
    for(unsigned i=0;i<70;++i)if(!VZTxn70ValueEqual(i,a[i],b[i]))return false;
    return true;
}
static bool DirtyEqual(const uint64_t a[3],const uint64_t b[3]){
    for(unsigned i=0;i<3;++i)if(a[i]!=b[i])return false;
    return true;
}
static int Index(VZTxn70Kind kind,uint32_t field){
    for(unsigned i=0;i<70;++i)if(VZTxn70Fields[i].kind==kind&&VZTxn70Fields[i].field==field)return (int)i;
    return -1;
}
bool VZTxn70OwnerValid(const VZTxn70Ops *o,const VZTxn70Owner *s,VZTxn70Handle h){
    return o&&o->identityVerified&&o->vmProviderABI==13&&o->vcpuProviderABI==13&&
        o->providerEpoch&&o->currentThread&&s&&h.owner==s&&s->owned&&s->idValid&&
        s->id<64&&h.id==s->id&&s->generation&&h.generation==s->generation&&
        s->leaseEpoch&&h.leaseEpoch==s->leaseEpoch&&s->stateEpoch&&s->ownerThread&&
        o->currentThread()==s->ownerThread&&s->neverRun&&!s->quarantined;
}
static bool CallbacksStable(const VZTxn70 *t){
    return t&&t->ops&&t->ops->context&&t->ops->readMemory&&t->ops->currentThread&&
       t->ops->getSIMD&&t->ops->setSIMD&&t->ops->getReg&&t->ops->setReg&&
       t->ops->getSys&&t->ops->setSys&&
       t->ops->context==t->frozenOps.context&&t->ops->readMemory==t->frozenOps.readMemory&&
       t->ops->currentThread==t->frozenOps.currentThread&&
       t->ops->getSIMD==t->frozenOps.getSIMD&&t->ops->setSIMD==t->frozenOps.setSIMD&&
       t->ops->getReg==t->frozenOps.getReg&&t->ops->setReg==t->frozenOps.setReg&&
       t->ops->getSys==t->frozenOps.getSys&&t->ops->setSys==t->frozenOps.setSys;
}
static bool Guard(VZTxn70 *t){
    if(!t||t->magic!=VZ_TXN70_MAGIC||t->state==VZ_TXN_UNBOUND||t->state==VZ_TXN_POISON_STATE||
       !CallbacksStable(t)||
       !VZTxn70OwnerValid(t->ops,t->owner,t->handle)||t->owner->activeLease!=t||
       t->ops->providerEpoch!=t->providerEpoch||t->owner->stateEpoch!=t->ownerStateEpoch)return false;
    const void *current=t->frozenOps.context(t->handle.id);uint64_t version=0;
    return current&&current==t->genuineContext&&
        t->frozenOps.readMemory((const uint8_t*)current+0x4000,8,&version)&&version==VZ_TXN70_NATIVE_VERSION&&
        CallbacksStable(t)&&VZTxn70OwnerValid(t->ops,t->owner,t->handle)&&t->owner->activeLease==t&&
        t->ops->providerEpoch==t->providerEpoch&&t->owner->stateEpoch==t->ownerStateEpoch&&CallbacksStable(t);
}
static void Poison(VZTxn70 *t,VZTxn70Result *r){
    if(!t)return;
    // Only mark the local owner record if it still names this exact lifetime.
    // No native API, owner/epoch reset, or foreign lifetime mutation is allowed.
    if(t->owner&&t->frozenOps.currentThread&&
       t->owner->activeLease==t&&t->owner->id==t->handle.id&&
       t->owner->generation==t->handle.generation&&t->owner->leaseEpoch==t->handle.leaseEpoch&&
       t->frozenOps.currentThread()==t->owner->ownerThread){t->owner->quarantined=true;if(r)r->quarantined=true;}
    t->state=VZ_TXN_POISON_STATE;
}
static VZTxn70Status ReadNative(VZTxn70 *t,unsigned i,VZTxn70Value *out){
    if(i>=70)return VZ_TXN_UNSUPPORTED;
    if(!Guard(t))return VZ_TXN_NOT_READY;
    const VZTxn70Field *f=&VZTxn70Fields[i];VZTxn70Value actual={0},raw={0};hv_return_t rc;
    if(f->kind==VZ_TXN_SIMD)rc=t->ops->getSIMD(t->handle.id,(hv_simd_fp_reg_t)f->field,&actual.simd);
    else if(f->kind==VZ_TXN_REG)rc=t->ops->getReg(t->handle.id,(hv_reg_t)f->field,&actual.scalar);
    else rc=t->ops->getSys(t->handle.id,(hv_sys_reg_t)f->field,&actual.scalar);
    if(rc)return VZ_TXN_NATIVE_ERROR;
    if(!Guard(t))return VZ_TXN_NOT_READY;
    // FPCR/FPSR raw reads are four bytes into an explicitly zeroed uint64 value.
    if(!t->frozenOps.readMemory((const uint8_t*)t->genuineContext+f->offset,f->width,&raw))return VZ_TXN_MISMATCH;
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(!VZTxn70ValueEqual(i,actual,raw))return VZ_TXN_MISMATCH;
    if(out)*out=actual;
    return VZ_TXN_OK;
}
static hv_return_t SetNative(VZTxn70 *t,unsigned i,VZTxn70Value v){
    const VZTxn70Field *f=&VZTxn70Fields[i];
    // Function pointer types retain the real SDK SIMD value-in-q0 convention.
    if(f->kind==VZ_TXN_SIMD)return t->ops->setSIMD(t->handle.id,(hv_simd_fp_reg_t)f->field,v.simd);
    if(f->kind==VZ_TXN_REG)return t->ops->setReg(t->handle.id,(hv_reg_t)f->field,v.scalar);
    return t->ops->setSys(t->handle.id,(hv_sys_reg_t)f->field,v.scalar);
}
static VZTxn70Status ReadDirty(VZTxn70 *t,uint64_t values[3]){
    if(!Guard(t))return VZ_TXN_NOT_READY;
    for(unsigned i=0;i<3;++i){
        if(!Guard(t))return VZ_TXN_NOT_READY;
        if(!t->frozenOps.readMemory((const uint8_t*)t->genuineContext+VZTxn70DirtyOffsets[i],8,&values[i]))return VZ_TXN_MISMATCH;
        if(!Guard(t))return VZ_TXN_NOT_READY;
    }
    return Guard(t)?VZ_TXN_OK:VZ_TXN_NOT_READY;
}
VZTxn70Status VZTxn70Observe(VZTxn70 *t,VZTxn70Value values[70],uint64_t dirty[3]){
    if(!values||!dirty)return VZ_TXN_NOT_READY;
    uint64_t before[3],after[3];VZTxn70Value actual[70];
    VZTxn70Status code=ReadDirty(t,before);if(code!=VZ_TXN_OK)return code;
    for(unsigned i=0;i<70;++i){code=ReadNative(t,i,&actual[i]);if(code!=VZ_TXN_OK)return code;}
    code=ReadDirty(t,after);if(code!=VZ_TXN_OK)return code;
    if(!DirtyEqual(before,after))return VZ_TXN_CONFLICT;
    memcpy(values,actual,sizeof(actual));memcpy(dirty,after,sizeof(after));return VZ_TXN_OK;
}
VZTxn70Status VZTxn70Bind(VZTxn70 *t,const VZTxn70Ops *o,VZTxn70Owner *s,VZTxn70Handle h){
    if(!t)return VZ_TXN_NOT_READY;
    // Rebinding a live transaction would discard its journal and is forbidden.
    // Storage is explicitly zero-initialized by the caller; never read unknown
    // automatic storage or erase a live journal because another owner was given.
    if(t->magic||t->state!=VZ_TXN_UNBOUND)return VZ_TXN_PENDING;
    if(!o||!o->context||!o->readMemory||!o->getSIMD||!o->setSIMD||!o->getReg||!o->setReg||
       !o->getSys||!o->setSys||!VZTxn70OwnerValid(o,s,h))return VZ_TXN_NOT_READY;
    if(s->activeLease)return VZ_TXN_PENDING;
    VZTxn70Ops frozen=*o;const void *context=frozen.context(h.id);
    VZTxn70 check={.ops=o,.frozenOps=frozen};
    if(!context||!CallbacksStable(&check)||!VZTxn70OwnerValid(o,s,h)||s->activeLease)return VZ_TXN_NOT_READY;
    *t=(VZTxn70){.magic=VZ_TXN70_MAGIC,.state=VZ_TXN_BOUND,.ops=o,.frozenOps=frozen,.owner=s,.handle=h,
        .genuineContext=context,.providerEpoch=frozen.providerEpoch,.ownerStateEpoch=s->stateEpoch};
    s->activeLease=t;VZTxn70Status code=ReadNative(t,VZ_TXN70_SCTLR_INDEX,&t->originalSCTLR);
    if(code==VZ_TXN_OK)code=ReadNative(t,VZ_TXN70_CPSR_INDEX,&t->originalCPSR);
    if(code!=VZ_TXN_OK){
        if(s->activeLease==t&&s->generation==h.generation&&s->leaseEpoch==h.leaseEpoch&&
           s->id==h.id&&t->frozenOps.currentThread()==s->ownerThread)s->activeLease=NULL;
        *t=(VZTxn70){0};
    }
    return code;
}
VZTxn70Status VZTxn70Snapshot(VZTxn70 *t){
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(t->state==VZ_TXN_COMMIT_STATE)return VZ_TXN_COMMITTED;
    if(Any(t->pending))return VZ_TXN_PENDING;
    if(t->snapshotSerial==UINT64_MAX)return VZ_TXN_EPOCH_EXHAUSTED;
    VZTxn70Value values[70];uint64_t dirty[3];VZTxn70Status code=VZTxn70Observe(t,values,dirty);
    if(code!=VZ_TXN_OK)return code;
    memcpy(t->baseline,values,sizeof(values));memcpy(t->requested,values,sizeof(values));
    memcpy(t->snapshotDirty,dirty,sizeof(dirty));memset(t->committed,0,sizeof(t->committed));
    memset(t->attempted,0,sizeof(t->attempted));++t->snapshotSerial;t->state=VZ_TXN_SNAPSHOT;
    return VZ_TXN_OK;
}
static VZTxn70Status Stage(VZTxn70 *t,VZTxn70Kind kind,uint32_t field,VZTxn70Value value){
    int index=Index(kind,field);if(index<0)return VZ_TXN_UNSUPPORTED;
    unsigned i=(unsigned)index;
    if(VZTxn70Fields[i].width==4&&value.scalar>UINT32_MAX)return VZ_TXN_UNSUPPORTED;
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(t->state==VZ_TXN_COMMIT_STATE)return VZ_TXN_COMMITTED;
    if(t->state!=VZ_TXN_SNAPSHOT&&t->state!=VZ_TXN_STAGED)return VZ_TXN_NOT_READY;
    if(i==VZ_TXN70_SCTLR_INDEX&&value.scalar!=UINT64_C(0x30800180)&&
       value.scalar!=t->baseline[i].scalar&&value.scalar!=t->originalSCTLR.scalar)return VZ_TXN_UNSUPPORTED;
    if(i==VZ_TXN70_CPSR_INDEX&&value.scalar!=UINT64_C(0x3c5)&&
       value.scalar!=t->baseline[i].scalar&&value.scalar!=t->originalCPSR.scalar)return VZ_TXN_UNSUPPORTED;
    if(!MaskLegal(t->pending))return VZ_TXN_NOT_READY;
    t->requested[i]=value;
    if(VZTxn70ValueEqual(i,value,t->baseline[i]))ClearBit(t->pending,i);else PutBit(t->pending,i);
    t->state=Any(t->pending)?VZ_TXN_STAGED:VZ_TXN_SNAPSHOT;return VZ_TXN_OK;
}
VZTxn70Status VZTxn70StageSIMD(VZTxn70 *t,hv_simd_fp_reg_t f,hv_simd_fp_uchar16_t v){return Stage(t,VZ_TXN_SIMD,(uint32_t)f,(VZTxn70Value){.simd=v});}
VZTxn70Status VZTxn70StageReg(VZTxn70 *t,hv_reg_t f,uint64_t v){return Stage(t,VZ_TXN_REG,(uint32_t)f,(VZTxn70Value){.scalar=v});}
VZTxn70Status VZTxn70StageSys(VZTxn70 *t,hv_sys_reg_t f,uint64_t v){return Stage(t,VZ_TXN_SYS,(uint32_t)f,(VZTxn70Value){.scalar=v});}
VZTxn70Status VZTxn70CancelStaged(VZTxn70 *t){
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(t->state==VZ_TXN_COMMIT_STATE)return VZ_TXN_COMMITTED;
    if(t->state!=VZ_TXN_SNAPSHOT&&t->state!=VZ_TXN_STAGED)return VZ_TXN_NOT_READY;
    memcpy(t->requested,t->baseline,sizeof(t->baseline));memset(t->pending,0,sizeof(t->pending));
    t->state=VZ_TXN_SNAPSHOT;return VZ_TXN_OK;
}
static bool StartResult(VZTxn70 *t,VZTxn70Result *r){
    if(!r)return false;
    *r=(VZTxn70Result){.status=VZ_TXN_NOT_READY,.triggerStatus=VZ_TXN_OK,.failedIndex=-1,
        .setRC=INT_MIN,.restoreRC=INT_MIN};
    if(t&&t->owner){r->ownerEpochBefore=t->ownerStateEpoch;r->ownerEpochAfter=t->owner->stateEpoch;}
    return true;
}
static void ReportDirty(VZTxn70 *t,VZTxn70Result *r,const uint64_t after[3]){
    memcpy(r->dirtyBefore,t->snapshotDirty,sizeof(r->dirtyBefore));
    memcpy(r->dirtyAfter,after,sizeof(r->dirtyAfter));r->dirtyObserved=true;
    r->nativeDirtyExactlyRestored=DirtyEqual(t->snapshotDirty,after);
}
static bool AdvanceEpoch(VZTxn70 *t,VZTxn70Result *r){
    if(!Guard(t)||t->ownerStateEpoch==UINT64_MAX)return false;
    ++t->owner->stateEpoch;t->ownerStateEpoch=t->owner->stateEpoch;r->ownerEpochAfter=t->ownerStateEpoch;
    return true;
}
static VZTxn70Status RestoreAttempted(VZTxn70 *t,VZTxn70Result *r,VZTxn70Status trigger){
    r->triggerStatus=trigger;memcpy(r->attempted,t->attempted,sizeof(r->attempted));
    bool allSettersOkay=true;
    // The failing setter is in attempted before its invocation, even if it
    // returned an error after writing bytes. Restore it, then prior fields.
    for(unsigned cursor=70;cursor>0;--cursor){unsigned i=cursor-1;if(!Bit(t->attempted,i))continue;
        if(!Guard(t)){r->foreignRestoreBlocked=true;Poison(t,r);return r->status=VZ_TXN_RESTORE_FAILED;}
        PutBit(r->restoreAttempted,i);hv_return_t rc=SetNative(t,i,t->baseline[i]);
        if(rc){allSettersOkay=false;r->restoreRC=rc;}else if(r->restoreRC==INT_MIN)r->restoreRC=0;
        if(!Guard(t)){r->foreignRestoreBlocked=true;Poison(t,r);return r->status=VZ_TXN_RESTORE_FAILED;}
        VZTxn70Value value;VZTxn70Status read=ReadNative(t,i,&value);
        if(read!=VZ_TXN_OK||!VZTxn70ValueEqual(i,value,t->baseline[i]))allSettersOkay=false;
        // A native restore error does not skip remaining same-owner originals.
    }
    VZTxn70Value values[70];uint64_t dirty[3];VZTxn70Status observed=VZTxn70Observe(t,values,dirty);
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
static VZTxn70Status Preflight(VZTxn70 *t,const VZTxn70Value expected[70],const uint64_t dirtyExpected[3]){
    VZTxn70Value values[70];uint64_t dirty[3];VZTxn70Status code=VZTxn70Observe(t,values,dirty);
    if(code!=VZ_TXN_OK)return code;
    return ValuesEqual(values,expected)&&DirtyEqual(dirty,dirtyExpected)?VZ_TXN_OK:VZ_TXN_CONFLICT;
}
VZTxn70Status VZTxn70Commit(VZTxn70 *t,VZTxn70Result *r){
    if(!StartResult(t,r))return VZ_TXN_NOT_READY;
    if(!Guard(t))return r->status;
    if(t->state==VZ_TXN_COMMIT_STATE)return r->status=VZ_TXN_COMMITTED;
    if(t->state!=VZ_TXN_STAGED||!Any(t->pending)||!MaskLegal(t->pending))return r->status=VZ_TXN_PENDING;
    if(t->ownerStateEpoch==UINT64_MAX)return r->status=VZ_TXN_EPOCH_EXHAUSTED;
    VZTxn70Status code=Preflight(t,t->baseline,t->snapshotDirty);
    if(code!=VZ_TXN_OK)return r->status=code;
    memset(t->attempted,0,sizeof(t->attempted));
    for(unsigned i=0;i<70;++i){if(!Bit(t->pending,i))continue;
        if(!Guard(t))return RestoreAttempted(t,r,VZ_TXN_NOT_READY);
        PutBit(t->attempted,i);r->setRC=SetNative(t,i,t->requested[i]);
        if(!Guard(t)){r->failedIndex=(int)i;return RestoreAttempted(t,r,VZ_TXN_NOT_READY);}
        VZTxn70Value value;code=ReadNative(t,i,&value);
        if(r->setRC||code!=VZ_TXN_OK||!VZTxn70ValueEqual(i,value,t->requested[i])){
            r->failedIndex=(int)i;
            return RestoreAttempted(t,r,r->setRC?VZ_TXN_NATIVE_ERROR:code==VZ_TXN_OK?VZ_TXN_MISMATCH:code);
        }
    }
    VZTxn70Value values[70];uint64_t dirty[3];code=VZTxn70Observe(t,values,dirty);
    if(code!=VZ_TXN_OK||!ValuesEqual(values,t->requested))return RestoreAttempted(t,r,code==VZ_TXN_OK?VZ_TXN_MISMATCH:code);
    if(!AdvanceEpoch(t,r))return RestoreAttempted(t,r,VZ_TXN_NOT_READY);
    memcpy(t->committed,values,sizeof(values));memcpy(t->committedDirty,dirty,sizeof(dirty));
    memcpy(r->attempted,t->attempted,sizeof(r->attempted));ReportDirty(t,r,dirty);
    t->state=VZ_TXN_COMMIT_STATE;r->valuesCommitted=true;r->fullReadbackVerified=true;
    return r->status=VZ_TXN_OK;
}
VZTxn70Status VZTxn70Verify(VZTxn70 *t,VZTxn70Result *r){
    if(!StartResult(t,r))return VZ_TXN_NOT_READY;
    if(!Guard(t))return r->status;
    if(t->state!=VZ_TXN_COMMIT_STATE)return r->status=VZ_TXN_NOT_READY;
    VZTxn70Status code=Preflight(t,t->committed,t->committedDirty);
    if(code!=VZ_TXN_OK)return r->status=code;
    memcpy(r->attempted,t->attempted,sizeof(r->attempted));ReportDirty(t,r,t->committedDirty);
    r->valuesCommitted=true;r->fullReadbackVerified=true;return r->status=VZ_TXN_OK;
}
VZTxn70Status VZTxn70Restore(VZTxn70 *t,VZTxn70Result *r){
    if(!StartResult(t,r))return VZ_TXN_NOT_READY;
    if(!Guard(t))return r->status;
    if(t->state!=VZ_TXN_COMMIT_STATE||!MaskLegal(t->attempted))return r->status=VZ_TXN_NOT_READY;
    if(t->ownerStateEpoch==UINT64_MAX)return r->status=VZ_TXN_EPOCH_EXHAUSTED;
    VZTxn70Status code=Preflight(t,t->committed,t->committedDirty);
    if(code!=VZ_TXN_OK)return r->status=code;
    return RestoreAttempted(t,r,VZ_TXN_OK);
}
VZTxn70Status VZTxn70Release(VZTxn70 *t){
    if(!Guard(t))return VZ_TXN_NOT_READY;
    if(t->state==VZ_TXN_COMMIT_STATE)return VZ_TXN_COMMITTED;
    if(Any(t->pending))return VZ_TXN_PENDING;
    t->owner->activeLease=NULL;*t=(VZTxn70){0};return VZ_TXN_OK;
}
