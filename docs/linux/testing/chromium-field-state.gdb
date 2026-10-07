# Test-only, exact-build Chromium capture. Launch only an owned fictional profile.
# Records primitive field types/flags and identity comparisons; never text or IDs.
set pagination off
set confirm off
set verbose off
set print thread-events off
set print frame-arguments none
set startup-with-shell off
set follow-fork-mode parent
set detach-on-fork on
set follow-exec-mode same
set disable-randomization off
set debuginfod enabled off
python
import gdb, os, json, struct, time
from pathlib import Path
import stat
expected_build_id = bytes.fromhex('93237317ee65885ff6aa81cde20c8233ba56d0d0')
elf = Path('/usr/lib/chromium/chromium').read_bytes()
assert b'GNU\x00'+expected_build_id in elf
expected_profile = os.environ['SNIPPETS_IME_PROFILE']
assert Path(expected_profile).parent.name.startswith('snippets-core-')
rows = 0
previous = None
mask = 0x73ff
class StateCapture(gdb.Breakpoint):
 def stop(self):
  global rows, previous
  if rows >= 128:return False
  try:
   inferior = gdb.selected_inferior()
   old = int(gdb.parse_and_eval('$rcx'))
   new = int(gdb.parse_and_eval('$r12'))
   def u32(addr):return struct.unpack('<I', bytes(inferior.read_memory(addr,4)))[0]
   def boolean(addr):
    value=bytes(inferior.read_memory(addr,1))[0];assert value in (0,1);return bool(value)
   ot,nt=u32(old+4),u32(new+4);om,nm=u32(old+8),u32(new+8)
   of,nf=u32(old+16),u32(new+16);oi,ni=boolean(old+76),boolean(new+76)
   assert 0<=ot<=18 and 0<=nt<=18 and 0<=om<=10 and 0<=nm<=10
   assert of&~mask==0 and nf&~mask==0
   view=int(gdb.parse_and_eval('*(unsigned long long *)($rbp-0x110)'));node=u32(new)
   prior_node_same=previous is not None and previous[0]==node;prior_view_same=previous is not None and previous[1]==view
   previous=(node,view)
   row={'previous_node_same':prior_node_same,'previous_view_same':prior_view_same,'event':'compare_text_input_state','monotonic_us':time.monotonic_ns()//1000,'node_changed':u32(old)!=u32(new),'old_type':ot,'new_type':nt,'old_mode':om,'new_mode':nm,'old_flags':of,'new_flags':nf,'old_inline':oi,'new_inline':ni}
  except Exception:row={'event':'capture_failed'}
  fd=os.open(os.environ['SNIPPETS_IME_STATE_FILE'],os.O_WRONLY|os.O_APPEND|os.O_NOFOLLOW)
  info=os.fstat(fd)
  assert stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and info.st_nlink==1 and info.st_mode&0o777==0o600 and info.st_size<128*1024
  with os.fdopen(fd,'a') as f:f.write(json.dumps(row)+'\n')
  rows+=1
  return False
installed=False
def install():
 global installed
 inferior=gdb.selected_inferior();pid=inferior.pid
 if installed or os.readlink('/proc/'+str(pid)+'/exe')!='/usr/lib/chromium/chromium':return
 args=Path('/proc/'+str(pid)+'/cmdline').read_bytes().split(b'\x00')
 assert ('--user-data-dir='+expected_profile).encode() in args
 lines=Path('/proc/'+str(pid)+'/maps').read_text().splitlines()
 base=next(int(line.split()[0].split('-')[0],16) for line in lines if line.split()[2]=='00000000' and line.endswith('/usr/lib/chromium/chromium'))
 address=base+0x5bb1d3c
 assert bytes(inferior.read_memory(address,2))==b'\xb0\x01'
 StateCapture('*'+hex(address),internal=True)
 installed=True
end
catch exec
commands
silent
python install()
continue
end
run
