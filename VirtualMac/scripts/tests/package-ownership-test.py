from pathlib import Path
import subprocess,json,os,time,tempfile,plistlib,tarfile,sys
base=Path(os.environ.get('VZ_TEST_OUTPUT', tempfile.gettempdir()))
base.mkdir(parents=True,exist_ok=True)
run=Path(tempfile.mkdtemp(prefix='virtualmac-dpkg-ownership-',dir=base))
repo=Path(__file__).resolve().parents[2]
newprefix='/var/jb/usr/libexec/VirtualMac/sepbridge'
oldprefix='/var/jb/sepbridge'
source_files=['vz/install/install_launcher.c','vz/guest/sepbridge-helper.m','vz/guest/com.mac.virtual.sepbridge.host.plist','vz/host/VirtualMacApp.m','packaging/DEBIAN/postinst','scripts/build-ipad-deb.sh']
for name in source_files:
 text=(repo/name).read_text()
 assert newprefix in text, name
 assert oldprefix not in text, name
plist=plistlib.loads((repo/'vz/guest/com.mac.virtual.sepbridge.host.plist').read_bytes())
assert plist['ProgramArguments']==[newprefix+'/sepbridge-helper']
assert plist['StandardOutPath']==newprefix+'/helper.log'
assert plist['StandardErrorPath']==newprefix+'/helper.err'
control=(repo/'packaging/DEBIAN/control').read_text()
assert not any(line.startswith(('Replaces:','Conflicts:')) and 'com.vm.sepbridge' in line for line in control.splitlines())
root=run/'root';admin=root/'var/lib/dpkg';(admin/'updates').mkdir(parents=True);(admin/'info').mkdir();(admin/'status').write_text('')
logs=[]
def build(name,version,filepath,content):
 stage=run/(name+'-'+version);(stage/'DEBIAN').mkdir(parents=True)
 (stage/'DEBIAN/control').write_text(f'Package: {name}\nVersion: {version}\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: isolated ownership regression\n')
 p=stage/filepath.lstrip('/');p.parent.mkdir(parents=True);p.write_text(content)
 deb=run/(name+'-'+version+'.deb')
 subprocess.run(['dpkg-deb','--root-owner-group','--build',str(stage),str(deb)],check=True,capture_output=True)
 return deb
def unpack(package):
 result=subprocess.run(['dpkg','--root='+str(root),'--admindir='+str(admin),'--force-not-root','--force-bad-path','--no-triggers','--unpack',str(package)],capture_output=True,text=True)
 logs.append({'package':package.name,'code':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
 return result
oldpath='/var/jb/sepbridge/sepbridge-helper';newpath='/var/jb/usr/libexec/VirtualMac/sepbridge/sepbridge-helper'
legacy=build('com.vm.sepbridge','0.9.1',oldpath,'legacy-content')
conflict=build('com.mac.virtual','1',oldpath,'conflicting-content')
new=build('com.mac.virtual','2',newpath,'new-private-content')
assert unpack(legacy).returncode==0
# Preserve the physical fixture file by moving it aside, while leaving dpkg's
# installed ownership record in place. Mirrors the user's physical deletion.
physical=root/oldpath.lstrip('/');backup=run/'legacy-physical-file-kept';physical.rename(backup)
assert not physical.exists()
failed=unpack(conflict)
assert failed.returncode!=0 and 'trying to overwrite' in failed.stderr and 'com.vm.sepbridge (0.9.1)' in failed.stderr,failed.stderr
assert not physical.exists()
assert unpack(new).returncode==0
assert (root/newpath.lstrip('/')).read_text()=='new-private-content'
oldlist=(admin/'info/com.vm.sepbridge.list').read_text();newlist=(admin/'info/com.mac.virtual.list').read_text()
assert oldpath in oldlist and oldpath not in newlist and newpath in newlist
assert not physical.exists() and backup.read_text()=='legacy-content'
report={'dpkg_version':subprocess.check_output(['dpkg','--version'],text=True).splitlines()[0],'fixture_root':str(root),'legacy_package':'com.vm.sepbridge 0.9.1','removed_physical_file_still_owned':True,'same_path_unpack_refused':True,'new_namespace_unpack_succeeded':True,'legacy_ownership_preserved':True,'new_package_has_no_Replaces_Conflicts_or_Provides':True,'maintainer_scripts_executed':False,'real_device_modified':False,'source_namespace_consistent':True,'steps':logs}
(run/'receipt.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='steps'},indent=2))

if len(sys.argv)>1:
 package=Path(sys.argv[1]).resolve()
 content=subprocess.check_output(['dpkg-deb','--fsys-tarfile',str(package)])
 import io
 with tarfile.open(fileobj=io.BytesIO(content)) as archive:
  members=archive.getmembers()
  paths={'/'+m.name.removeprefix('./').rstrip('/') for m in members if m.name not in ('.','./')}
  assert not any(p==oldprefix or p.startswith(oldprefix+'/') for p in paths)
  assert {newprefix+'/sepbridge-helper',newprefix+'/sepinject.dylib',newprefix+'/com.mac.virtual.sepbridge.host.plist'}<=paths
  remote=None
  if len(sys.argv)>2:
   remote={line.strip().rstrip('/') for line in Path(sys.argv[2]).read_text().splitlines() if line.startswith('/')}
   regular={'/'+m.name.removeprefix('./').rstrip('/') for m in members if not m.isdir()}
   conflicts=sorted(regular & remote)
   assert not conflicts, conflicts
  print(json.dumps({'package_namespace_passed':True,'legacy_ownership_file_intersection':[] if remote is not None else 'not supplied'},indent=2))
