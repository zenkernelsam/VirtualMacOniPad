#!/usr/bin/env python3
"""Build an independent application-private SYS4 library; never deploy or invoke HV."""
import argparse,hashlib,json,re,shutil,struct,subprocess
from pathlib import Path
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--output',required=True,type=Path);args=ap.parse_args()
    project=Path(__file__).resolve().parents[2];out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    source=project/'vz/host/modern_cpu_system_state_transaction4.c';header=source.with_suffix('.h')
    sdk=Path(subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip())
    commands=[]
    def run(label,argv):
        r=subprocess.run(argv,capture_output=True);(out/(label+'.stdout')).write_bytes(r.stdout);(out/(label+'.stderr')).write_bytes(r.stderr)
        commands.append({'argv':argv,'exit':r.returncode})
        if r.returncode:raise RuntimeError(label+': '+r.stderr.decode(errors='replace'))
        return r
    unsigned=out/'VM27CPUSystemStateTransaction4.dylib.unsigned';library=out/'VM27CPUSystemStateTransaction4.dylib'
    run('compile',['xcrun','--sdk','iphoneos','clang','-arch','arm64e','-miphoneos-version-min=14.5','-std=c11','-Wall','-Wextra','-Werror','-dynamiclib',
                   '-Xclang','-iframework','-Xclang',str(sdk/'System/Library/Frameworks'),'-Wl,-no_adhoc_codesign',
                   '-install_name','@rpath/VM27CPUSystemStateTransaction4.dylib',str(source),'-o',str(unsigned)])
    data=bytearray(unsigned.read_bytes());magic,cpu,subtype=struct.unpack_from('<III',data)
    assert magic==0xfeedfacf and cpu==0x100000c and subtype==0x80000002
    n,size=struct.unpack_from('<II',data,16);at=32;builds=[]
    for _ in range(n):
        command,length=struct.unpack_from('<II',data,at)
        assert length>=8 and length%8==0 and at+length<=32+size
        if command==0x32:builds.append(at)
        at+=length
    assert at==32+size and len(builds)==1
    # Declared minimum only. Do not alter instructions or arm64e CPU subtype.
    struct.pack_into('<3I',data,builds[0]+8,2,0xe0500,0xe0500);unsigned.write_bytes(data);shutil.copyfile(unsigned,library)
    run('sign',['codesign','--force','--sign','-','--timestamp=none','--identifier','com.virtualmac.cpu-system-state-transaction4',str(library)])
    run('strict',['codesign','--verify','--strict',str(library)])
    run('dyld',['xcrun','dyld_info','-validate_only',str(library)])
    signed=run('signature',['codesign','-dvvv',str(library)]);cdhash=re.search(rb'CDHash=([0-9a-f]{40})',signed.stderr)[1].decode()
    undefined=run('undefined',['xcrun','nm','-u',str(library)]).stdout
    assert not re.search(rb' _(?:_?hv_|h3_|MTL|VTDecompression)',undefined)
    exports=run('exports',['xcrun','nm','-gU',str(library)]).stdout
    names=re.findall(rb' _([^\s]+)',exports)
    assert len(names)==13 and all(n.startswith(b'VZSysTxn4') for n in names)
    meta={'source':[{'path':str(p),'sha256':sha(p)} for p in [source,header,project/'vz/host/modern_cpu_context_transaction.h']],
          'library':{'path':str(library),'bytes':library.stat().st_size,'sha256':sha(library),'cdhash':cdhash},
          'SDKHeadersOnly':str(sdk/'System/Library/Frameworks/Hypervisor.framework/Headers'),
          'fields':['TPIDR_EL1','TPIDR_EL0','TPIDRRO_EL0','CSSELR_EL1'],'fieldCount':4,'valueBytes':32,
          'readOnlyOldNativeOffsets':['0x358','0x360','0x368','0x388'],
          'readOnlyOldDirtyWords':['0x670','0x678','0x748'],'oldTypedSetterDirtyMask':0,
          'operation':'private typed snapshot, persistent commit, verify, explicit original-value restoration',
          'nativeProviderABI':13,'realVCPURunMaximum':0,'requiresOwnedNeverRunCPU':True,
          'nativeKernelAtomicTransaction':False,'whole27ContextImplemented':False,'modernStateVIEWImplemented':False,
          'original27VMMConsumerConnected':False,'installedOrTrustedOnDevice':False,'realNativeProbePassed':False,
          'signedExports':[n.decode() for n in names],'commands':commands}
    (out/'manifest.json').write_text(json.dumps(meta,indent=2)+'\n');print(json.dumps({'library':meta['library'],'nativeExecution':False},indent=2))
if __name__=='__main__':main()
