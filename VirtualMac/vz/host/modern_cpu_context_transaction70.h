// Independent 70-field transaction. CPSR is the real old typed/native lane, not a modern VIEW.
// Ops, Owner, Handle and Result share the existing private lifecycle ABI so one
// activeLease excludes both 69- and 70-field transactions for the same owner.
#ifndef VZ_CONTEXT_TRANSACTION70_H
#define VZ_CONTEXT_TRANSACTION70_H
#include "modern_cpu_context_transaction.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>

typedef __typeof__(&hv_vcpu_get_simd_fp_reg) VZTxn70GetSIMD;
typedef __typeof__(&hv_vcpu_set_simd_fp_reg) VZTxn70SetSIMD;
typedef __typeof__(&hv_vcpu_get_reg) VZTxn70GetReg;
typedef __typeof__(&hv_vcpu_set_reg) VZTxn70SetReg;
typedef __typeof__(&hv_vcpu_get_sys_reg) VZTxn70GetSys;
typedef __typeof__(&hv_vcpu_set_sys_reg) VZTxn70SetSys;
_Static_assert(sizeof(hv_simd_fp_uchar16_t)==16,"SDK SIMD width");
_Static_assert(__alignof__(hv_simd_fp_uchar16_t)==16,"SDK SIMD q0 ABI");
_Static_assert(HV_SIMD_FP_REG_Q0==0&&HV_SIMD_FP_REG_Q31==31,"SDK SIMD IDs");
_Static_assert(HV_REG_X0==0&&HV_REG_X30==30&&HV_REG_PC==31&&HV_REG_FPCR==32&&HV_REG_FPSR==33&&HV_REG_CPSR==34,"SDK scalar IDs");
_Static_assert(HV_SYS_REG_SCTLR_EL1==0xc080&&HV_SYS_REG_SP_EL0==0xc208&&HV_SYS_REG_SP_EL1==0xe208,"SDK system IDs");

#define VZ_TXN70_MAGIC UINT64_C(0x565a54584e373000)
#define VZ_TXN70_NATIVE_VERSION UINT64_C(0x206879700000000e)
#define VZ_TXN70_FIELD_COUNT 70
#define VZ_TXN70_CPSR_INDEX 69
#define VZ_TXN70_DIRTY_WORD_COUNT 3
#define VZ_TXN70_SCTLR_INDEX 32
#define VZ_TXN70_X0_INDEX 33
#define VZ_TXN70_PC_INDEX 64
#define VZ_TXN70_FPCR_INDEX 65
#define VZ_TXN70_FPSR_INDEX 66
#define VZ_TXN70_SP_EL0_INDEX 67
#define VZ_TXN70_SP_EL1_INDEX 68

typedef VZTxnStatus VZTxn70Status;
typedef VZTxnKind VZTxn70Kind;
typedef VZTxnState VZTxn70State;
typedef VZTxnValue VZTxn70Value;
typedef VZTxnField VZTxn70Field;
typedef VZTxnOps VZTxn70Ops;
typedef VZTxnOwner VZTxn70Owner;
typedef VZTxnHandle VZTxn70Handle;
typedef VZTxnResult VZTxn70Result;
extern const VZTxn70Field VZTxn70Fields[VZ_TXN70_FIELD_COUNT];
extern const size_t VZTxn70DirtyOffsets[VZ_TXN70_DIRTY_WORD_COUNT];

typedef struct {
    uint64_t magic;VZTxn70State state;
    const VZTxn70Ops *ops;VZTxn70Ops frozenOps;VZTxn70Owner *owner;VZTxn70Handle handle;
    const void *genuineContext;uint64_t providerEpoch,ownerStateEpoch;
    uint64_t snapshotSerial;VZTxn70Value originalSCTLR,originalCPSR;
    VZTxn70Value baseline[VZ_TXN70_FIELD_COUNT],requested[VZ_TXN70_FIELD_COUNT],
        committed[VZ_TXN70_FIELD_COUNT];
    uint64_t pending[2],attempted[2],snapshotDirty[VZ_TXN70_DIRTY_WORD_COUNT],
        committedDirty[VZ_TXN70_DIRTY_WORD_COUNT];
} VZTxn70;
bool VZTxn70ValueEqual(unsigned,VZTxn70Value,VZTxn70Value);
bool VZTxn70OwnerValid(const VZTxn70Ops*,const VZTxn70Owner*,VZTxn70Handle);
// Caller must initialize storage as VZTxn70 txn={0} before its first Bind.
// CPSR targets: exact bind value, exact snapshot value, or 0x3c5; no run is allowed.
// A live transaction can never be rebound, even to a different owner.
VZTxn70Status VZTxn70Bind(VZTxn70*,const VZTxn70Ops*,VZTxn70Owner*,VZTxn70Handle);
VZTxn70Status VZTxn70Snapshot(VZTxn70*);
VZTxn70Status VZTxn70Observe(VZTxn70*,VZTxn70Value[VZ_TXN70_FIELD_COUNT],uint64_t[VZ_TXN70_DIRTY_WORD_COUNT]);
VZTxn70Status VZTxn70StageSIMD(VZTxn70*,hv_simd_fp_reg_t,hv_simd_fp_uchar16_t);
VZTxn70Status VZTxn70StageReg(VZTxn70*,hv_reg_t,uint64_t);
VZTxn70Status VZTxn70StageSys(VZTxn70*,hv_sys_reg_t,uint64_t);
VZTxn70Status VZTxn70CancelStaged(VZTxn70*);
// Success is persistent: values remain set until an explicit Restore.
// Typed setters are sequential, not a native/kernel atomic transaction.
VZTxn70Status VZTxn70Commit(VZTxn70*,VZTxn70Result*);
VZTxn70Status VZTxn70Verify(VZTxn70*,VZTxn70Result*);
// Restore requires the exact committed values/owner epoch before first write.
VZTxn70Status VZTxn70Restore(VZTxn70*,VZTxn70Result*);
// Cannot release a committed or poisoned transaction and silently discard it.
VZTxn70Status VZTxn70Release(VZTxn70*);
#endif
