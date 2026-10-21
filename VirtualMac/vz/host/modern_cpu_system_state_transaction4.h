// Application-private four-SYS transaction. No Apple KernelContext or VIEW facade.
// The owner ABI is shared with 69/70: one activeLease excludes all three modules.
#ifndef VZ_SYSTEM_STATE_TRANSACTION4_H
#define VZ_SYSTEM_STATE_TRANSACTION4_H
#include "modern_cpu_context_transaction.h"
_Static_assert(HV_SYS_REG_TPIDR_EL1==0xc684&&HV_SYS_REG_TPIDR_EL0==0xde82&&
    HV_SYS_REG_TPIDRRO_EL0==0xde83&&HV_SYS_REG_CSSELR_EL1==0xd000,"SDK SYS IDs");
#define VZ_SYS_TXN4_MAGIC UINT64_C(0x565a535953545834)
#define VZ_SYS_TXN4_NATIVE_VERSION UINT64_C(0x206879700000000e)
#define VZ_SYS_TXN4_FIELD_COUNT 4
#define VZ_SYS_TXN4_DIRTY_WORD_COUNT 3
#define VZ_SYS_TXN4_CSSELR_INDEX 3
typedef VZTxnStatus VZSysTxn4Status;
typedef VZTxnKind VZSysTxn4Kind;
typedef VZTxnState VZSysTxn4State;
typedef VZTxnValue VZSysTxn4Value;
typedef VZTxnField VZSysTxn4Field;
typedef VZTxnOps VZSysTxn4Ops;
typedef VZTxnOwner VZSysTxn4Owner;
typedef VZTxnHandle VZSysTxn4Handle;
typedef VZTxnResult VZSysTxn4Result;
extern const VZSysTxn4Field VZSysTxn4Fields[VZ_SYS_TXN4_FIELD_COUNT];
extern const size_t VZSysTxn4DirtyOffsets[VZ_SYS_TXN4_DIRTY_WORD_COUNT];
typedef struct {
    uint64_t magic;VZSysTxn4State state;
    const VZSysTxn4Ops *ops;VZSysTxn4Ops frozenOps;
    VZSysTxn4Owner *owner;VZSysTxn4Handle handle;
    const void *genuineContext;uint64_t providerEpoch,ownerStateEpoch,snapshotSerial;
    VZSysTxn4Value originalCSSELR;
    VZSysTxn4Value baseline[4],requested[4],committed[4];
    uint64_t pending[2],attempted[2],snapshotDirty[3],committedDirty[3];
} VZSysTxn4;
bool VZSysTxn4ValueEqual(unsigned,VZSysTxn4Value,VZSysTxn4Value);
bool VZSysTxn4OwnerValid(const VZSysTxn4Ops*,const VZSysTxn4Owner*,VZSysTxn4Handle);
// Storage must be zero-initialized. Bind/Observe are read-only native operations.
VZSysTxn4Status VZSysTxn4Bind(VZSysTxn4*,const VZSysTxn4Ops*,VZSysTxn4Owner*,VZSysTxn4Handle);
VZSysTxn4Status VZSysTxn4Snapshot(VZSysTxn4*);
VZSysTxn4Status VZSysTxn4Observe(VZSysTxn4*,VZSysTxn4Value[4],uint64_t[3]);
// TLS values retain genuine uint64 typed semantics. CSSELR accepts the exact bind
// or snapshot value, or a bounded diagnostic selector 0..15; no CPU run is allowed.
VZSysTxn4Status VZSysTxn4StageSys(VZSysTxn4*,hv_sys_reg_t,uint64_t);
VZSysTxn4Status VZSysTxn4CancelStaged(VZSysTxn4*);
// Sequential genuine old SDK-typed setters; not a kernel atomic transaction.
VZSysTxn4Status VZSysTxn4Commit(VZSysTxn4*,VZSysTxn4Result*);
VZSysTxn4Status VZSysTxn4Verify(VZSysTxn4*,VZSysTxn4Result*);
VZSysTxn4Status VZSysTxn4Restore(VZSysTxn4*,VZSysTxn4Result*);
VZSysTxn4Status VZSysTxn4Release(VZSysTxn4*);
#endif
