#!/usr/bin/env python3
"""Build separate genuine CPU ABI backports; never overwrite the production runtime."""
from pathlib import Path
import hashlib,json,subprocess,re,struct,sys
ROOT=Path(__file__).resolve().parents[2];SOURCE=ROOT/'vz/host/modern_cpu_runtime_compat.cpp'
EXPORTS=['_malloc_type_calloc','__ZNSt3__113__hash_memoryEPKvm','__ZNKSt3__119bad_expected_accessIvE4whatEv','__ZTINSt3__119bad_expected_accessIvEE','__ZNSt3__123__atomic_monitor_globalEPKv','__ZNSt3__126__atomic_wait_global_tableEPKvx','__ZNSt3__132__atomic_notify_all_global_tableEPKv','__ZNSt13exception_ptr31__from_native_exception_pointerEPv']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main(path):
 out=Path(path).resolve();out.mkdir(mode=0o700,exist_ok=False);originalSHA=sha(SOURCE);rows=[]
 def run(label,args):
  r=subprocess.run(args,capture_output=True,timeout=30);(out/(label+'.stdout')).write_bytes(r.stdout);(out/(label+'.stderr')).write_bytes(r.stderr);(out/(label+'.command.json')).write_text(json.dumps(args,indent=2)+'\n')
  if r.returncode:raise RuntimeError(label)
  return r
 for role,sdk,target,extra in [('ios','iphoneos','arm64e-apple-ios16.1',[]),('macos','macosx','arm64e-apple-macos13.0',['-Wl,-no_mac_public_arm64e'])]:
  name='ModernCPURuntimeCompat'+(''if role=='ios'else'.mac')+'.dylib';p=out/name
  command=['xcrun','--sdk',sdk,'clang++','-target',target,'-std=c++23','-O2','-fno-typed-cxx-new-delete','-D_LIBCPP_BUILDING_LIBRARY','-D_LIBCPP_DISABLE_AVAILABILITY','-fptrauth-abi-version=0','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations','-Wl,-no_adhoc_codesign']+extra+['-dynamiclib','-install_name','@rpath/'+name,str(SOURCE),'-o',str(p)]
  run(role+'-compile',command)
  b=bytearray(p.read_bytes());assert struct.unpack_from('<II',b)[0]==0xfeedfacf and struct.unpack_from('<I',b,8)[0]==0x80000002;at=32;uuid=[];build=[]
  for i in range(struct.unpack_from('<I',b,16)[0]):
   cmd,size=struct.unpack_from('<II',b,at);assert size>=8 and size%8==0
   if cmd==0x1b:uuid.append(bytes(b[at+8:at+24]).hex())
   if cmd==0x32:build.append(at)
   at+=size
  assert len(uuid)==len(build)==1
  if role=='ios':struct.pack_into('<3I',b,build[0]+8,2,0x100100,0x100100);p.write_bytes(b)
  run(role+'-sign',['codesign','--force','--sign','-','--timestamp=none','--identifier','local.VirtualMac.modern-cpu-runtime.'+role,str(p)]);run(role+'-strict',['codesign','--verify','--strict',str(p)]);run(role+'-dyld',['xcrun','dyld_info','-validate_only',str(p)])
  cd=re.search(rb'CDHash=([0-9a-f]{40})',run(role+'-signature',['codesign','-dvvv',str(p)]).stderr)[1].decode();defined={x.split()[-1]for x in run(role+'-exports',['nm','-gU',str(p)]).stdout.decode().splitlines()if x.split()};assert set(EXPORTS)<=defined;assert not run(role+'-entitlements',['codesign','-d','--entitlements',':-',str(p)]).stdout
  rows.append({'role':role,'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p),'CDHash':cd,'UUID':uuid[0],'exports':EXPORTS,'trueArm64eABI0':True,'target':target,'emptyEntitlements':True})
 assert sha(SOURCE)==originalSHA
 result={'scope':'eight genuine app-private CPU ABI definitions only','sourcePath':str(SOURCE),'sourceSHA256':originalSHA,'libraries':rows,'deviceExecution':False,'productionPackageModified':False,'complete27ClosureProved':False};(out/'build-manifest.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':
 if len(sys.argv)!=2:raise SystemExit('Usage: build-modern-cpu-runtime.py NEW_OUTPUT_DIRECTORY')
 main(sys.argv[1])
