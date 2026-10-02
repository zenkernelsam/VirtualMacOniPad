// metal-exec-stress.m — PG exec-channel stress probe (DIAGNOSTIC).
// Floods the exec FIFO with serialized command buffers to reproduce the
// host-side exec-channel stall observed in guest gpuRestart reports
// (submitEvent:INCOMPLETE). Records every committed/completed count and any
// command-buffer errors; does NOT try to hide failures.
//
// Build: clang -fobjc-arc -O2 -framework Foundation -framework Metal \
//        metal-exec-stress.m -o metal-exec-stress
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <signal.h>
#include <time.h>

static volatile sig_atomic_t gStop = 0;
static void onSig(int s) { (void)s; gStop = 1; }

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGINT, onSig);
        signal(SIGTERM, onSig);
        int duration = argc > 1 ? atoi(argv[1]) : 120;
        int parallelism = argc > 2 ? atoi(argv[2]) : 64;

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "STRESS no-metal-device\n"); return 2; }
        fprintf(stderr, "STRESS device=%s\n", dev.name.UTF8String);
        fprintf(stderr, "STRESS maxBufferLength=%llu\n",
                (unsigned long long)dev.maxBufferLength);

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> src = [dev newBufferWithLength:1 << 20
                                             options:MTLResourceStorageModeShared];
        id<MTLBuffer> dst = [dev newBufferWithLength:1 << 20
                                             options:MTLResourceStorageModeShared];
        memset(src.contents, 0x5a, 1 << 20);

        __block unsigned long long completed = 0, errored = 0,
                                  lastErr = 0;
        unsigned long long submitted = 0;
        struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
        dispatch_semaphore_t inFlight =
            dispatch_semaphore_create(parallelism);

        while (!gStop) {
            struct timespec tn; clock_gettime(CLOCK_MONOTONIC, &tn);
            double elapsed = (double)(tn.tv_sec - t0.tv_sec)
                    + (double)(tn.tv_nsec - t0.tv_nsec) / 1e9;
            if (elapsed > duration) break;

            dispatch_semaphore_wait(inFlight, DISPATCH_TIME_FOREVER);
            id<MTLCommandBuffer> cb = [q commandBuffer];
            if (!cb) { errored++; continue; }
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromBuffer:src sourceOffset:0
                        toBuffer:dst destinationOffset:0
                            size:1 << 20];
            [blit synchronizeResource:dst];
            [blit endEncoding];
            unsigned long long tag = ++submitted;
            [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
                if (b.status == MTLCommandBufferStatusError) {
                    __sync_add_and_fetch(&errored, 1);
                    if (b.error.code != lastErr) {
                        lastErr = b.error.code;
                        fprintf(stderr, "STRESS cb-error code=%lld %s\n",
                                (long long)b.error.code,
                                b.error.description.UTF8String);
                    }
                } else {
                    __sync_add_and_fetch(&completed, 1);
                }
                dispatch_semaphore_signal(inFlight);
            }];
            [cb commit];

            if ((submitted % 512) == 0) {
                fprintf(stderr,
                        "STRESS t=%.1fs submitted=%llu completed=%llu "
                        "errored=%llu inFlight=%lld\n",
                        elapsed, submitted, completed, errored,
                        (long long)(submitted - completed - errored));
            }
        }
        // Drain outstanding
        for (long i = 0; i < parallelism; i++)
            dispatch_semaphore_wait(inFlight, DISPATCH_TIME_FOREVER);
        struct timespec tn; clock_gettime(CLOCK_MONOTONIC, &tn);
        fprintf(stderr,
                "STRESS DONE t=%.1fs submitted=%llu completed=%llu "
                "errored=%llu\n",
                (double)(tn.tv_sec - t0.tv_sec)
                    + (double)(tn.tv_nsec - t0.tv_nsec) / 1e9,
                submitted, completed, errored);
        return errored ? 1 : 0;
    }
}
