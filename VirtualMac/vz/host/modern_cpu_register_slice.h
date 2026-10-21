// Application-private 33-field register slice. Never an Apple-shaped context.
#ifndef VZ_FIELD_SLICE_H
#define VZ_FIELD_SLICE_H
#include <Hypervisor/hv_vcpu.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>

// These types are taken directly from the installed SDK, including vector ABI.
typedef __typeof__(&hv_vcpu_get_simd_fp_reg) VZSliceGetSIMD;
typedef __typeof__(&hv_vcpu_set_simd_fp_reg) VZSliceSetSIMD;
typedef __typeof__(&hv_vcpu_get_sys_reg) VZSliceGetSys;
typedef __typeof__(&hv_vcpu_set_sys_reg) VZSliceSetSys;
_Static_assert(sizeof(hv_simd_fp_uchar16_t)==16,"SDK vector width");
_Static_assert(__alignof__(hv_simd_fp_uchar16_t)==16,"SDK vector alignment");
_Static_assert(HV_SIMD_FP_REG_Q0==0&&HV_SIMD_FP_REG_Q31==31,"SDK Q IDs");
_Static_assert(HV_SYS_REG_SCTLR_EL1==0xc080,"SDK SCTLR logical ID");

#define VZ_SLICE_MAGIC UINT64_C(0x565a534c49434534)
#define VZ_SLICE_NATIVE_VERSION UINT64_C(0x206879700000000e)
typedef enum {VZ_SLICE_OK=0,VZ_SLICE_UNSUPPORTED=1,VZ_SLICE_NOT_READY=2,
    VZ_SLICE_PENDING=3,VZ_SLICE_NATIVE_ERROR=4,VZ_SLICE_MISMATCH=5,
    VZ_SLICE_RESTORE_FAILED=6} VZSliceStatus;
typedef enum {VZ_SLICE_SIMD=1,VZ_SLICE_SYS=2} VZSliceKind;
typedef union {hv_simd_fp_uchar16_t simd;uint64_t sys;} VZSliceValue;
typedef struct {
    bool identityVerified;uint32_t vmProviderABI,vcpuProviderABI;
    void *(*context)(hv_vcpu_t);
    VZSliceGetSIMD getSIMD;VZSliceSetSIMD setSIMD;
    VZSliceGetSys getSys;VZSliceSetSys setSys;
    bool (*readMemory)(const void*,size_t,void*);
    uint64_t (*currentThread)(void);
} VZSliceOps;
typedef struct {hv_vcpu_t id;uint64_t generation,ownerThread;bool owned,idValid;} VZSliceOwner;
typedef struct {const VZSliceOwner *owner;hv_vcpu_t id;uint64_t generation;} VZSliceHandle;
typedef struct {
    uint64_t magic;uint32_t schemaVersion;bool bound,snapshotReady;
    const VZSliceOps *ops;const VZSliceOwner *owner;VZSliceHandle handle;
    const void *genuineContext;uint64_t versionObserved;
    VZSliceValue originalAtBind[33],observed[33],requested[33];uint64_t pendingMask;
} VZSliceShadow;
typedef struct {
    VZSliceStatus status;VZSliceKind kind;uint32_t field;
    hv_return_t saveRC,setRC,checkRC,restoreRC,restoredRC;
    bool saved,setAttempted,writeVerified,restoreAttempted,exactRestored,
        snapshotRefreshed;
    VZSliceValue original,target,publicSet,rawSet,publicRestored,rawRestored;
} VZSliceResult;

bool VZSliceOwnerValid(const VZSliceOps*,const VZSliceOwner*,VZSliceHandle);
bool VZSliceSIMDEqual(hv_simd_fp_uchar16_t,hv_simd_fp_uchar16_t);
VZSliceStatus VZSliceBind(VZSliceShadow*,const VZSliceOps*,const VZSliceOwner*,VZSliceHandle);
VZSliceStatus VZSliceRefresh(VZSliceShadow*);
VZSliceStatus VZSliceReadSIMD(VZSliceShadow*,hv_simd_fp_reg_t,hv_simd_fp_uchar16_t*);
VZSliceStatus VZSliceReadSCTLR(VZSliceShadow*,hv_sys_reg_t,uint64_t*);
VZSliceStatus VZSliceStageSIMD(VZSliceShadow*,hv_simd_fp_reg_t,hv_simd_fp_uchar16_t);
VZSliceStatus VZSliceStageSCTLR(VZSliceShadow*,hv_sys_reg_t,uint64_t);
// Temporarily commit ONE private intent, verify public/raw, restore saved value.
// A native setter error still requires the same genuine restoration attempt.
VZSliceStatus VZSliceRoundTripOne(VZSliceShadow*,VZSliceResult*);
VZSliceStatus VZSliceCancelAndRefresh(VZSliceShadow*);
#endif
