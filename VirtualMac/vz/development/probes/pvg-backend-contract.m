#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <ptrauth.h>

// Metadata only: no VM, memory mapping, GPU device, or GPU service creation.
static void DumpMethods(Class cls, const char *kind) {
    unsigned count=0;
    Method *methods=class_copyMethodList(cls,&count);
    for (unsigned i=0;i<count;++i) {
        Dl_info image={0};
        IMP implementation=method_getImplementation(methods[i]);
        void *code=ptrauth_strip((void *)implementation,ptrauth_key_function_pointer);
        dladdr(code,&image);
        printf("%s\t%s\t%s\t0x%llx\n",kind,
            sel_getName(method_getName(methods[i])),method_getTypeEncoding(methods[i]),
            (unsigned long long)((uintptr_t)code-(uintptr_t)image.dli_fbase));
    }
    free(methods);
}

static void DumpClass(Class cls) {
    printf("CLASS\t%s\tsize=%zu\timage=%s\n",class_getName(cls),
        class_getInstanceSize(cls),class_getImageName(cls));
    DumpMethods(cls,"METHOD");
    DumpMethods(object_getClass(cls),"CLASS_METHOD");
    unsigned count=0;
    Ivar *ivars=class_copyIvarList(cls,&count);
    for (unsigned i=0;i<count;++i)
        printf("IVAR\t%s\t%s\t%td\n",ivar_getName(ivars[i]),
            ivar_getTypeEncoding(ivars[i]),ivar_getOffset(ivars[i]));
    free(ivars);
    objc_property_t *properties=class_copyPropertyList(cls,&count);
    for (unsigned i=0;i<count;++i)
        printf("PROPERTY\t%s\t%s\n",property_getName(properties[i]),
            property_getAttributes(properties[i]));
    free(properties);
}

int main(int argc,char **argv) {
    setvbuf(stdout,NULL,_IONBF,0);
    @autoreleasepool {
        const char *selected=NULL;
        for (int i=1;i<argc;++i) {
            if (!strcmp(argv[i],"--class") && i+1<argc) { selected=argv[++i]; continue; }
            if (!dlopen(argv[i],RTLD_NOW|RTLD_GLOBAL)) {
                fprintf(stderr,"dlopen %s: %s\n",argv[i],dlerror()); return 2;
            }
        }
        if (selected) {
            Class cls=objc_getClass(selected);
            if (!cls) { fprintf(stderr,"missing class %s\n",selected); return 3; }
            DumpClass(cls);
        } else {
            unsigned count=0;
            Class *classes=objc_copyClassList(&count);
            for (unsigned i=0;i<count;++i) {
                const char *name=class_getName(classes[i]);
                if (!strncmp(name,"PG",2) || !strncmp(name,"_PG",3)) DumpClass(classes[i]);
            }
            free(classes);
        }
    }
    return 0;
}
