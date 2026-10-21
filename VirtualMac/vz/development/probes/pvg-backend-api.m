#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

// Inspect the backend's Objective-C contract without creating a VM, mapping
// guest memory, starting its GPU task service, or submitting GPU commands.
static void InspectClass(const char *name) {
    Class cls=objc_getClass(name);
    printf("class=%s present=%d\n",name,cls!=Nil);
    if (!cls) return;
    printf("  classImage=%s\n",class_getImageName(cls));
    unsigned count=0;
    Method *methods=class_copyMethodList(cls,&count);
    for (unsigned i=0;i<count;++i) {
        const char *selector=sel_getName(method_getName(methods[i]));
        if (strstr(selector,"Task") || strstr(selector,"Memory") ||
            strstr(selector,"memory") || strstr(selector,"trace") ||
            strstr(selector,"Trace") || strstr(selector,"Feature") ||
            strstr(selector,"feature") || strstr(selector,"Info") ||
            strstr(selector,"info") || strstr(selector,"Delegate") ||
            strstr(selector,"delegate") || strstr(selector,"Deserializer"))
            printf("  %s %s\n",selector,method_getTypeEncoding(methods[i]));
    }
    free(methods);
}

int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IONBF,0);
    @autoreleasepool {
        const char *paths[]={
            "/System/Library/Frameworks/ParavirtualizedGraphics.framework/Versions/A/ParavirtualizedGraphics",
            "/System/Library/PrivateFrameworks/MetalSerializer.framework/Versions/A/MetalSerializer"
        };
        if (argc!=1 && argc!=3) { fputs("usage: probe [PVG MetalSerializer]\n",stderr); return 2; }
        for (unsigned i=0;i<2;++i) {
            const char *path=argc==3 ? argv[i+1] : paths[i];
            void *handle=dlopen(path,RTLD_NOW|RTLD_LOCAL);
            printf("image=%s loaded=%d\n",path,handle!=NULL);
            if (!handle) { fprintf(stderr,"%s\n",dlerror()); return 3; }
        }
        if (argc==3) {
            const char *owners[]={"PGDeviceDescriptor","MTLDeserializerBlitDecoder"};
            for (unsigned i=0;i<2;++i) {
                Class cls=objc_getClass(owners[i]);
                const char *path=cls ? class_getImageName(cls) : NULL;
                char *actual=path ? realpath(path,NULL) : NULL;
                char *expected=realpath(argv[i+1],NULL);
                BOOL matches=actual && expected && strcmp(actual,expected)==0;
                free(actual); free(expected);
                if (!matches) {
                    fprintf(stderr,"%s did not come from the candidate image\n",owners[i]);
                    return 4;
                }
            }
        }
        InspectClass("PGDeviceDescriptor");
        InspectClass("_PGDevice");
        InspectClass("PGTask");
        InspectClass("PGGPUTask");
        InspectClass("MTLDeserializerBlitDecoder");
        InspectClass("MTLDeserializerInfoDecoder");
        InspectClass("_MTLDeserializer");
        Class descriptor=objc_getClass("PGDeviceDescriptor");
        id object=descriptor ? [descriptor new] : nil;
        const char *legacy[]={"setCreateTask:","setDestroyTask:","setMapMemory:",
                              "setUnmapMemory:","setReadMemory:","setAddTraceRange:",
                              "setRemoveTraceRange:"};
        for (unsigned i=0;i<sizeof(legacy)/sizeof(legacy[0]);++i)
            printf("legacyDescriptorSelector=%s supported=%d\n",legacy[i],
                   [object respondsToSelector:sel_registerName(legacy[i])]);
    }
    return 0;
}
