// Application-private cached scalar input. Not an Apple CPU or kernel context.
#ifndef VZ27_SCALAR_READ_BRIDGE_H
#define VZ27_SCALAR_READ_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define VZ27_SCALAR_CACHE_BYTES 0x350u
#define VZ27_SCALAR_READ_COUNT 34u
// Caller verifies complete original provider SHA/UUID/build metadata and the
// exact bounded helper bytes before binding. Verification must stay immutable.
typedef struct {
    bool identityVerified;
    uint32_t providerABI;
    uint64_t providerEpoch,thread;
    void *signedEntry;
    uint64_t (*currentThread)(void);
    bool (*verifyEntry)(void *);
} VZ27ScalarReadOps;
// Input is exclusively owned, valid readable private storage of at least 0x350
// bytes. It is copied into local storage. No pointer to native CPU state or to
// this input is returned to a VMM. Output must not overlap input. IDs 0..33 only; CPSR 34 is always rejected.
bool VZ27ScalarReadCache(const VZ27ScalarReadOps*,const void*,size_t,
                        uint32_t,uint64_t*);
#endif
