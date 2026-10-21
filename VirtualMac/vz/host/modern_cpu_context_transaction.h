// Diagnostic application-private 69-field transaction. No Apple context facade.
#ifndef VZ_CONTEXT_TRANSACTION_V6_H
#define VZ_CONTEXT_TRANSACTION_V6_H
#include <Hypervisor/hv_vcpu.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>

typedef __typeof__(&hv_vcpu_get_simd_fp_reg) VZTxnGetSIMD;
typedef __typeof__(&hv_vcpu_set_simd_fp_reg) VZTxnSetSIMD;
typedef __typeof__(&hv_vcpu_get_reg) VZTxnGetReg;
typedef __typeof__(&hv_vcpu_set_reg) VZTxnSetReg;
typedef __typeof__(&hv_vcpu_get_sys_reg) VZTxnGetSys;
typedef __typeof__(&hv_vcpu_set_sys_reg) VZTxnSetSys;
_Static_assert(sizeof(hv_simd_fp_uchar16_t)==16,"SDK SIMD width");
_Static_assert(__alignof__(hv_simd_fp_uchar16_t)==16,"SDK SIMD q0 ABI");
_Static_assert(HV_SIMD_FP_REG_Q0==0&&HV_SIMD_FP_REG_Q31==31,"SDK SIMD IDs");
_Static_assert(HV_REG_X0==0&&HV_REG_X30==30&&HV_REG_PC==31&&HV_REG_FPCR==32&&HV_REG_FPSR==33&&HV_REG_CPSR==34,"SDK scalar IDs");
_Static_assert(HV_SYS_REG_SCTLR_EL1==0xc080&&HV_SYS_REG_SP_EL0==0xc208&&HV_SYS_REG_SP_EL1==0xe208,"SDK system IDs");

#define VZ_TXN_MAGIC UINT64_C(0x565a54584e363900)
#define VZ_TXN_NATIVE_VERSION UINT64_C(0x206879700000000e)
#define VZ_TXN_FIELD_COUNT 69
#define VZ_TXN_DIRTY_WORD_COUNT 3
#define VZ_TXN_SCTLR_INDEX 32
#define VZ_TXN_X0_INDEX 33
#define VZ_TXN_PC_INDEX 64
#define VZ_TXN_FPCR_INDEX 65
#define VZ_TXN_FPSR_INDEX 66
#define VZ_TXN_SP_EL0_INDEX 67
#define VZ_TXN_SP_EL1_INDEX 68

typedef enum {VZ_TXN_OK=0,VZ_TXN_UNSUPPORTED=1,VZ_TXN_NOT_READY=2,
    VZ_TXN_PENDING=3,VZ_TXN_CONFLICT=4,VZ_TXN_NATIVE_ERROR=5,
    VZ_TXN_MISMATCH=6,VZ_TXN_RESTORE_FAILED=7,VZ_TXN_COMMITTED=8,
    VZ_TXN_POISONED=9,VZ_TXN_EPOCH_EXHAUSTED=10} VZTxnStatus;
typedef enum {VZ_TXN_SIMD=1,VZ_TXN_REG=2,VZ_TXN_SYS=3} VZTxnKind;
typedef enum {VZ_TXN_UNBOUND=0,VZ_TXN_BOUND=1,VZ_TXN_SNAPSHOT=2,
    VZ_TXN_STAGED=3,VZ_TXN_COMMIT_STATE=4,VZ_TXN_RECOVERED=5,
    VZ_TXN_POISON_STATE=6} VZTxnState;
typedef union {hv_simd_fp_uchar16_t simd;uint64_t scalar;} VZTxnValue;
typedef struct {VZTxnKind kind;uint32_t field;size_t offset,width;} VZTxnField;
extern const VZTxnField VZTxnFields[VZ_TXN_FIELD_COUNT];
// These are bounded observations, never writable dirty-field mappings.
extern const size_t VZTxnDirtyOffsets[VZ_TXN_DIRTY_WORD_COUNT];

typedef struct {
    bool identityVerified;uint32_t vmProviderABI,vcpuProviderABI;
    uint64_t providerEpoch;
    void *(*context)(hv_vcpu_t);
    VZTxnGetSIMD getSIMD;VZTxnSetSIMD setSIMD;
    VZTxnGetReg getReg;VZTxnSetReg setReg;
    VZTxnGetSys getSys;VZTxnSetSys setSys;
    bool (*readMemory)(const void*,size_t,void*);
    uint64_t (*currentThread)(void);
} VZTxnOps;
// Ops and callback targets must be immutable for the entire lease. providerEpoch
// supplements the verified image/entry identity; it does not replace it.
// Independent diagnostic owner ABI: callers must serialize every CPU action.
// Each new CPU lifetime gets fresh generation/leaseEpoch; counters never wrap.
// neverRun is an enforced harness contract, not a claimed native-kernel flag.
typedef struct {
    hv_vcpu_t id;uint64_t generation,ownerThread,leaseEpoch,stateEpoch;
    bool owned,idValid,neverRun,quarantined;
    const void *activeLease;
} VZTxnOwner;
typedef struct {
    VZTxnOwner *owner;hv_vcpu_t id;uint64_t generation,leaseEpoch;
} VZTxnHandle;
typedef struct {
    uint64_t magic;VZTxnState state;
    const VZTxnOps *ops;VZTxnOps frozenOps;VZTxnOwner *owner;VZTxnHandle handle;
    const void *genuineContext;uint64_t providerEpoch,ownerStateEpoch;
    uint64_t snapshotSerial;VZTxnValue originalSCTLR;
    VZTxnValue baseline[VZ_TXN_FIELD_COUNT],requested[VZ_TXN_FIELD_COUNT],
        committed[VZ_TXN_FIELD_COUNT];
    uint64_t pending[2],attempted[2],snapshotDirty[VZ_TXN_DIRTY_WORD_COUNT],
        committedDirty[VZ_TXN_DIRTY_WORD_COUNT];
} VZTxn;
typedef struct {
    VZTxnStatus status,triggerStatus;int failedIndex;
    hv_return_t setRC,restoreRC;
    uint64_t attempted[2],restoreAttempted[2],ownerEpochBefore,ownerEpochAfter;
    bool valuesCommitted,fullReadbackVerified,registerValuesExactlyRestored,
        nativeDirtyExactlyRestored,dirtyObserved,restoreCallsSucceeded,
        foreignRestoreBlocked,quarantined;
    // nativeDirtyExactlyRestored compares only these three audited words.
    // It never means the whole native context/kernel transaction was restored.
    uint64_t dirtyBefore[VZ_TXN_DIRTY_WORD_COUNT],dirtyAfter[VZ_TXN_DIRTY_WORD_COUNT];
} VZTxnResult;

bool VZTxnValueEqual(unsigned,VZTxnValue,VZTxnValue);
bool VZTxnOwnerValid(const VZTxnOps*,const VZTxnOwner*,VZTxnHandle);
// Caller must initialize storage as VZTxn txn={0} before its first Bind.
// A live transaction can never be rebound, even to a different owner.
VZTxnStatus VZTxnBind(VZTxn*,const VZTxnOps*,VZTxnOwner*,VZTxnHandle);
VZTxnStatus VZTxnSnapshot(VZTxn*);
VZTxnStatus VZTxnObserve(VZTxn*,VZTxnValue[VZ_TXN_FIELD_COUNT],uint64_t[VZ_TXN_DIRTY_WORD_COUNT]);
VZTxnStatus VZTxnStageSIMD(VZTxn*,hv_simd_fp_reg_t,hv_simd_fp_uchar16_t);
VZTxnStatus VZTxnStageReg(VZTxn*,hv_reg_t,uint64_t);
VZTxnStatus VZTxnStageSys(VZTxn*,hv_sys_reg_t,uint64_t);
VZTxnStatus VZTxnCancelStaged(VZTxn*);
// Success is persistent: values remain set until an explicit Restore.
// Typed setters are sequential, not a native/kernel atomic transaction.
VZTxnStatus VZTxnCommit(VZTxn*,VZTxnResult*);
VZTxnStatus VZTxnVerify(VZTxn*,VZTxnResult*);
// Restore requires the exact committed values/owner epoch before first write.
VZTxnStatus VZTxnRestore(VZTxn*,VZTxnResult*);
// Cannot release a committed or poisoned transaction and silently discard it.
VZTxnStatus VZTxnRelease(VZTxn*);
#endif
