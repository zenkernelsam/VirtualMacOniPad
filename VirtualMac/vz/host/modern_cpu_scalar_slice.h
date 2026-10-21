// Application-private logical register slice; never an Apple context pointer.
#ifndef VZ_SCALAR_SLICE_H
#define VZ_SCALAR_SLICE_H
#include <Hypervisor/hv_vcpu.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
typedef __typeof__(&hv_vcpu_get_reg) VZScalarGetReg;
typedef __typeof__(&hv_vcpu_set_reg) VZScalarSetReg;
typedef __typeof__(&hv_vcpu_get_sys_reg) VZScalarGetSys;
typedef __typeof__(&hv_vcpu_set_sys_reg) VZScalarSetSys;
_Static_assert(HV_REG_X0==0&&HV_REG_X28==28&&HV_REG_X29==29&&HV_REG_X30==30,"SDK X IDs");
_Static_assert(HV_REG_PC==31&&HV_REG_FPCR==32&&HV_REG_FPSR==33&&HV_REG_CPSR==34,"SDK scalar IDs");
_Static_assert(HV_SYS_REG_SP_EL0==0xc208&&HV_SYS_REG_SP_EL1==0xe208,"SDK SP logical IDs");
#define VZ_SCALAR_MAGIC UINT64_C(0x565a5343414c5235)
#define VZ_SCALAR_NATIVE_VERSION UINT64_C(0x206879700000000e)
#define VZ_SCALAR_FIELD_COUNT 36
typedef enum {VZ_SCALAR_OK=0,VZ_SCALAR_UNSUPPORTED=1,VZ_SCALAR_NOT_READY=2,
    VZ_SCALAR_PENDING=3,VZ_SCALAR_NATIVE_ERROR=4,VZ_SCALAR_MISMATCH=5,
    VZ_SCALAR_RESTORE_FAILED=6} VZScalarStatus;
typedef enum {VZ_SCALAR_REG=1,VZ_SCALAR_SYS=2} VZScalarKind;
typedef struct {VZScalarKind kind;uint32_t field;size_t offset,width;} VZScalarField;
extern const VZScalarField VZScalarFields[VZ_SCALAR_FIELD_COUNT];
typedef struct {
    bool identityVerified;uint32_t vmProviderABI,vcpuProviderABI;
    void *(*context)(hv_vcpu_t);
    VZScalarGetReg getReg;VZScalarSetReg setReg;
    VZScalarGetSys getSys;VZScalarSetSys setSys;
    bool (*readMemory)(const void*,size_t,void*);
    uint64_t (*currentThread)(void);
} VZScalarOps;
typedef struct {hv_vcpu_t id;uint64_t generation,ownerThread;bool owned,idValid;} VZScalarOwner;
typedef struct {const VZScalarOwner *owner;hv_vcpu_t id;uint64_t generation;} VZScalarHandle;
typedef struct {
    uint64_t magic;uint32_t schemaVersion;bool bound,snapshotReady;
    const VZScalarOps *ops;const VZScalarOwner *owner;VZScalarHandle handle;
    const void *genuineContext;uint64_t versionObserved;
    uint64_t originalAtBind[VZ_SCALAR_FIELD_COUNT],observed[VZ_SCALAR_FIELD_COUNT],requested[VZ_SCALAR_FIELD_COUNT],pendingMask;
} VZScalarShadow;
typedef struct {
    VZScalarStatus status;VZScalarKind kind;uint32_t field;
    hv_return_t saveRC,setRC,checkRC,restoreRC,restoredRC;
    bool saved,setAttempted,writeVerified,restoreAttempted,exactRestored,snapshotRefreshed;
    uint64_t original,target,publicSet,rawSet,publicRestored,rawRestored;
} VZScalarResult;
bool VZScalarOwnerValid(const VZScalarOps*,const VZScalarOwner*,VZScalarHandle);
VZScalarStatus VZScalarBind(VZScalarShadow*,const VZScalarOps*,const VZScalarOwner*,VZScalarHandle);
VZScalarStatus VZScalarRefresh(VZScalarShadow*);
VZScalarStatus VZScalarReadReg(VZScalarShadow*,hv_reg_t,uint64_t*);
VZScalarStatus VZScalarReadSP(VZScalarShadow*,hv_sys_reg_t,uint64_t*);
VZScalarStatus VZScalarStageReg(VZScalarShadow*,hv_reg_t,uint64_t);
VZScalarStatus VZScalarStageSP(VZScalarShadow*,hv_sys_reg_t,uint64_t);
// Temporary single-field write + public/raw readback + exact saved restoration.
// This is a reversible diagnostic operation, not a persistent CPU commit.
VZScalarStatus VZScalarRoundTripOne(VZScalarShadow*,VZScalarResult*);
VZScalarStatus VZScalarCancelAndRefresh(VZScalarShadow*);
#endif
