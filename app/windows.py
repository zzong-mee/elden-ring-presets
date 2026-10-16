"""Windows offline bridge. The game owns equipment changes; no item creation."""
from __future__ import annotations
import ctypes as C
from ctypes import wintypes as W
import hashlib
import os
from pathlib import Path
import re
import struct
from app.model import SLOTS, STAT_OFFSETS, EMPTY, Item, Equipped, inventory_bias, plan_equipment
from tools.diagnose_1171 import scan_pe

# Equipment entry signature and 7-argument calling convention are documented by
# TGA equipItem_code.cea, commit 7926205c5a2ed236dd31278c4f5579c964ceec35.
EQUIP_PATTERN = re.compile(rb'.\x8b\xf1.\x8b\xd8.\x63\xea.\x8b\xf9', re.DOTALL)
MAGIC_PATTERN = re.compile(rb'.\x89\x5c...\x89\x74..\x57.\x83\xec..\x8b\xc2\x8b\xf9.\x8b\xc8', re.DOTALL)


def text_sections(data):
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    count = struct.unpack_from('<H', data, pe+6)[0]
    table = pe+24+struct.unpack_from('<H', data, pe+20)[0]
    for i in range(count):
        at = table+40*i
        name = data[at:at+8].rstrip(b'\0')
        virtual_size, rva, size, offset = struct.unpack_from('<IIII', data, at+8)
        if name == b'.text':
            yield rva, offset, size


def function_rva(data, pattern, adjustment=0):
    matches = []
    for rva, offset, size in text_sections(data):
        for match in pattern.finditer(data, offset, offset+size):
            target = match.start()-offset+adjustment
            if target < 0 or target >= size:
                raise ValueError('게임 함수 시작 주소가 코드 범위를 벗어났습니다.')
            matches.append(rva+target)
    if len(matches) != 1:
        raise ValueError(f'게임 함수 패턴이 유일하지 않습니다: {len(matches)}개. 교체하지 않았습니다.')
    return matches[0]


def call_code(function, arguments):
    """x64 Windows ABI: shadow space, aligned stack, four registers + three stack args."""
    if len(arguments) > 7:
        raise ValueError('At most seven arguments')
    args = list(arguments)+[0]*(7-len(arguments))
    code = bytearray(b'\x48\x83\xec\x38')
    for opcode, value in zip((b'\x48\xb9', b'\x48\xba', b'\x49\xb8', b'\x49\xb9'), args):
        code += opcode+struct.pack('<Q', value & 0xFFFFFFFFFFFFFFFF)
    for offset, value in zip((0x20, 0x28, 0x30), args[4:]):
        code += b'\x48\xc7\x44\x24'+bytes([offset])+struct.pack('<I', value & EMPTY)
    code += b'\x48\xb8'+struct.pack('<Q', function)+b'\xff\xd0\x48\x83\xc4\x38\xc3'
    return bytes(code)


class PROCESS(C.Structure):
    _fields_ = [('size', W.DWORD), ('usage', W.DWORD), ('pid', W.DWORD), ('heap', C.c_size_t),
                ('module', W.DWORD), ('threads', W.DWORD), ('parent', W.DWORD),
                ('priority', W.LONG), ('flags', W.DWORD), ('name', W.WCHAR*260)]

class MODULE(C.Structure):
    _fields_ = [('size', W.DWORD), ('id', W.DWORD), ('pid', W.DWORD), ('global_usage', W.DWORD),
                ('process_usage', W.DWORD), ('base', C.c_void_p), ('length', W.DWORD),
                ('handle', W.HMODULE), ('name', W.WCHAR*256), ('path', W.WCHAR*260)]


class WindowsGame:
    def __init__(self):
        if os.name != 'nt' or C.sizeof(C.c_void_p) != 8:
            raise RuntimeError('Windows x64 전용 앱입니다.')
        self.k = C.WinDLL('kernel32', use_last_error=True)
        self.u = C.WinDLL('user32', use_last_error=True)
        definitions = {
            'CreateToolhelp32Snapshot': ([W.DWORD,W.DWORD],W.HANDLE),
            'Process32FirstW': ([W.HANDLE,C.POINTER(PROCESS)],W.BOOL),
            'Process32NextW': ([W.HANDLE,C.POINTER(PROCESS)],W.BOOL),
            'Module32FirstW': ([W.HANDLE,C.POINTER(MODULE)],W.BOOL),
            'OpenProcess': ([W.DWORD,W.BOOL,W.DWORD],W.HANDLE),
            'CloseHandle': ([W.HANDLE],W.BOOL),
            'ReadProcessMemory': ([W.HANDLE,C.c_void_p,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)],W.BOOL),
            'WriteProcessMemory': ([W.HANDLE,C.c_void_p,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t)],W.BOOL),
            'VirtualAllocEx': ([W.HANDLE,C.c_void_p,C.c_size_t,W.DWORD,W.DWORD],C.c_void_p),
            'VirtualFreeEx': ([W.HANDLE,C.c_void_p,C.c_size_t,W.DWORD],W.BOOL),
            'VirtualProtectEx': ([W.HANDLE,C.c_void_p,C.c_size_t,W.DWORD,C.POINTER(W.DWORD)],W.BOOL),
            'FlushInstructionCache': ([W.HANDLE,C.c_void_p,C.c_size_t],W.BOOL),
            'CreateRemoteThread': ([W.HANDLE,C.c_void_p,C.c_size_t,C.c_void_p,C.c_void_p,W.DWORD,C.c_void_p],W.HANDLE),
            'WaitForSingleObject': ([W.HANDLE,W.DWORD],W.DWORD),
        }
        for name, (args, result) in definitions.items():
            fn = getattr(self.k, name); fn.argtypes=args; fn.restype=result
        self.u.GetForegroundWindow.restype = W.HWND
        self.u.GetWindowThreadProcessId.argtypes=[W.HWND,C.POINTER(W.DWORD)]
        self.u.GetWindowThreadProcessId.restype=W.DWORD
        self.u.GetAsyncKeyState.argtypes=[C.c_int]; self.u.GetAsyncKeyState.restype=C.c_short
        self.handle = None
        self.pending = None
        self.pid = None
        self.magic_function = None
        self.equip_function = None
        self.write_access = False

    def error(self, message):
        return RuntimeError(message+f' (Windows 오류 {C.get_last_error()})')

    def processes(self):
        snapshot = self.k.CreateToolhelp32Snapshot(2,0)
        if snapshot == C.c_void_p(-1).value:
            raise self.error('프로세스 목록을 읽지 못했습니다.')
        found = []
        try:
            entry=PROCESS(); entry.size=C.sizeof(entry)
            ok=self.k.Process32FirstW(snapshot,C.byref(entry))
            while ok:
                found.append((entry.pid,entry.name.lower()))
                ok=self.k.Process32NextW(snapshot,C.byref(entry))
        finally:
            self.k.CloseHandle(snapshot)
        return found

    def check_process(self):
        processes=self.processes()
        if any(name=='loadout manager.exe' for _,name in processes):
            raise ValueError('원본 Loadout Manager를 종료한 뒤 사용해 주세요.')
        if any(name.startswith('easyanticheat') for _,name in processes):
            raise ValueError('Easy Anti-Cheat 실행이 감지됐습니다. 오프라인 전용 실행 상태를 확인해 주세요.')
        games=[pid for pid,name in processes if name=='eldenring.exe']
        if len(games)!=1:
            raise ValueError('오프라인 엘든링에서 캐릭터를 불러와 주세요.')
        if self.pid is not None and games[0]!=self.pid:
            raise ValueError('게임이 다시 실행됐습니다. 앱도 다시 실행해 주세요.')
        return games[0]

    def connect(self):
        if self.handle:
            return
        self.pid=self.check_process()
        snapshot=self.k.CreateToolhelp32Snapshot(0x18,self.pid)
        if snapshot==C.c_void_p(-1).value:
            raise self.error('게임 모듈 목록을 읽지 못했습니다.')
        try:
            module=MODULE(); module.size=C.sizeof(module)
            if not self.k.Module32FirstW(snapshot,C.byref(module)) or module.name.lower()!='eldenring.exe':
                raise self.error('게임 모듈을 읽지 못했습니다.')
            self.base=module.base; self.image=Path(module.path).read_bytes()
        finally:
            self.k.CloseHandle(snapshot)
        self.rva=scan_pe(self.image)
        self.digest=hashlib.sha256(self.image).hexdigest()
        self.handle=self.k.OpenProcess(0x410,False,self.pid)
        if not self.handle:
            self.handle=None
            raise self.error('게임에 연결하지 못했습니다. 앱과 게임의 실행 권한을 맞춰 주세요.')

    def ensure_write(self):
        self.check_process(); self.reap()
        if self.equip_function is None:
            function=function_rva(self.image,EQUIP_PATTERN,-0x17)+self.base
            if EQUIP_PATTERN.fullmatch(self.read(function+0x17,12)) is None:
                raise ValueError('실행 중인 게임의 장비 함수가 파일과 일치하지 않습니다.')
            self.equip_function=function
        if not self.write_access:
            handle=self.k.OpenProcess(0x43A,False,self.pid)
            if not handle:
                raise self.error('장비 교체 권한을 얻지 못했습니다. 앱과 게임의 실행 권한을 맞춰 주세요.')
            self.k.CloseHandle(self.handle); self.handle=handle; self.write_access=True

    def foreground(self):
        value=W.DWORD()
        self.u.GetWindowThreadProcessId(self.u.GetForegroundWindow(),C.byref(value))
        return self.pid is not None and value.value==self.pid

    def keys(self):
        return [bool(self.u.GetAsyncKeyState(k)&0x8000) for k in (0x70,0x71,0x72,0x73,0x31,0x32,0x33,0x34)]

    def read(self,address,size):
        buffer=C.create_string_buffer(size); count=C.c_size_t()
        if not self.k.ReadProcessMemory(self.handle,address,buffer,size,C.byref(count)) or count.value!=size:
            raise self.error('게임 데이터 읽기 실패')
        return buffer.raw

    def uint(self,address):
        return struct.unpack('<I',self.read(address,4))[0]

    def pointer(self,address):
        value=struct.unpack('<Q',self.read(address,8))[0]
        if not 0x10000<=value<0x800000000000:
            raise ValueError('캐릭터를 불러온 상태인지 확인해 주세요.')
        return value

    def write(self,address,data):
        count=C.c_size_t(); buffer=C.create_string_buffer(data)
        if not self.k.WriteProcessMemory(self.handle,address,buffer,len(data),C.byref(count)) or count.value!=len(data):
            raise self.error('게임 데이터 쓰기 실패')

    def reap(self):
        if self.pending:
            thread,memory=self.pending
            state=self.k.WaitForSingleObject(thread,0)
            if state!=0:
                raise ValueError('이전 장비 교체 요청이 아직 진행 중입니다. 앱을 종료하지 말고 기다려 주세요.')
            self.k.CloseHandle(thread)
            self.k.VirtualFreeEx(self.handle,memory,0,0x8000)
            self.pending=None

    def snapshot(self):
        self.connect(); self.check_process(); self.reap()
        manager=self.pointer(self.base+self.rva); player=self.pointer(manager+8)
        stats={name:self.uint(player+offset) for name,offset in STAT_OFFSETS.items()}
        if not 1<=stats['LEVEL']<=713 or any(not 1<=v<=99 for k,v in stats.items() if k!='LEVEL'):
            raise ValueError('캐릭터 데이터 검증에 실패했습니다.')
        if self.uint(player+0x10)==0:
            raise ValueError('캐릭터가 살아 있는 상태에서 사용해 주세요.')
        character=self.read(player+0x9C,32).decode('utf-16le',errors='strict').split('\0',1)[0]
        if not character:
            raise ValueError('캐릭터 이름을 읽지 못했습니다.')
        descriptor=self.pointer(player+0x5D0)
        listing=self.pointer(descriptor+0x10); count=self.uint(descriptor+0x18)
        if count>2688:
            raise ValueError('소지품 구조를 검증하지 못했습니다.')
        inventory=[]; seen=0
        for i in range(2688):
            if seen>=count: break
            handle,item_id,quantity=struct.unpack('<III',self.read(listing+i*24,12))
            if item_id!=EMPTY:
                seen+=1; inventory.append(Item(i,handle,item_id,quantity))
        if seen!=count:
            raise ValueError('소지품 읽기가 완료되지 않았습니다.')
        equipment=[Equipped(slot,self.uint(player+0x398+slot*4),self.uint(player+0x340+slot*4),
                            self.uint(player+0x2B8+slot*4)) for slot,_ in SLOTS]
        bias=inventory_bias(equipment,inventory)
        magic_pointer=self.pointer(player+0x530)
        magic=[self.uint(magic_pointer+0x10+i*8) for i in range(12)]
        if (self.pointer(self.base+self.rva)!=manager or self.pointer(manager+8)!=player or
            self.pointer(player+0x5D0)!=descriptor or self.pointer(descriptor+0x10)!=listing or
            self.uint(descriptor+0x18)!=count):
            raise ValueError('캐릭터나 소지품이 변경됐습니다. 다시 시도해 주세요.')
        return dict(schema=1,character=character,stats=stats,magic=magic,
                    gear={str(x.slot):dict(item_id=x.item_id,handle=x.handle) for x in equipment},
                    player=player,inventory=inventory,bias=bias,inventory_descriptor=descriptor,exe_sha256=self.digest)

    def invoke(self,function,args,handle_value=EMPTY,payload=None):
        self.reap()
        memory=self.k.VirtualAllocEx(self.handle,None,8192,0x3000,0x04)
        if not memory:
            raise self.error('장비 호출 메모리를 준비하지 못했습니다.')
        thread=None
        try:
            data=memory+4096
            self.write(data,struct.pack('<I',handle_value) if payload is None else payload)
            code=call_code(function,[data if x=='DATA' else x for x in args])
            self.write(memory,code)
            old=W.DWORD()
            if not self.k.VirtualProtectEx(self.handle,memory,4096,0x20,C.byref(old)):
                raise self.error('장비 호출 코드를 준비하지 못했습니다.')
            if not self.k.FlushInstructionCache(self.handle,memory,len(code)):
                raise self.error('장비 호출 캐시 갱신 실패')
            thread=self.k.CreateRemoteThread(self.handle,None,0,memory,None,0,None)
            if not thread:
                raise self.error('게임 장비 함수를 호출하지 못했습니다.')
            self.pending=(thread,memory)
            state=self.k.WaitForSingleObject(thread,5000)
            if state!=0:
                raise ValueError('게임 함수 응답이 지연됐습니다. 추가 교체를 중단했습니다.')
            self.reap(); thread=None; memory=None
        finally:
            # Never free code still being executed by the game.
            if self.pending is None:
                if thread: self.k.CloseHandle(thread)
                if memory: self.k.VirtualFreeEx(self.handle,memory,0,0x8000)

    def recall(self,saved,include_stats=False,include_magic=False):
        current=self.snapshot()
        if saved['character']!=current['character']:
            raise ValueError('다른 캐릭터의 프리셋입니다.')
        if saved.get('exe_sha256')!=self.digest:
            raise ValueError('다른 게임 실행 파일에서 저장한 프리셋입니다. 현재 버전에서 다시 저장해 주세요.')
        plan=plan_equipment(saved['gear'],current['inventory'])
        # Preflight optional features before the first equipment change.
        if include_magic:
            if self.magic_function is None:
                self.magic_function=self.base+function_rva(self.image,MAGIC_PATTERN)
            owned={x.item_id for x in current['inventory'] if x.quantity>0}
            if any(x!=EMPTY and (x|0x40000000) not in owned for x in saved['magic']):
                raise ValueError('프리셋 마법 중 소지하지 않은 마법이 있습니다.')
            if len([x for x in saved['magic'] if x!=EMPTY])!=len(set(x for x in saved['magic'] if x!=EMPTY)):
                raise ValueError('중복 마법 프리셋은 지원하지 않습니다.')
            magic_slots=self.uint(current['player']+0xA74)
            if not 1<=magic_slots<=14:
                raise ValueError('마법 슬롯 수를 검증하지 못했습니다.')
            if any(x!=EMPTY for x in saved['magic'][magic_slots:]):
                raise ValueError('현재 마법 슬롯 수로 프리셋을 사용할 수 없습니다.')
            magic_tail=self.uint(current['inventory_descriptor']+0x1C)
            if magic_tail-1!=current['bias']:
                raise ValueError('마법 소지품 인덱스를 검증하지 못했습니다.')
        self.ensure_write()
        player=current['player']; modified=0
        try:
            # Clear changing talismans before swaps, avoiding transient duplicate restrictions.
            for slot,item in plan:
                if slot<17: continue
                expected=saved['gear'][str(slot)]['item_id']
                actual_id=self.uint(player+0x398+slot*4)
                actual_handle=self.uint(player+0x340+slot*4)
                if actual_id!=EMPTY and (actual_id!=expected or (item is not None and actual_handle!=item.handle)):
                    self.check_process()
                    if self.pointer(self.pointer(self.base+self.rva)+8)!=player or self.uint(player+0x10)==0:
                        raise ValueError('캐릭터 상태가 변경됐습니다.')
                    self.invoke(self.equip_function,[player+0x2B0,slot,'DATA',EMPTY,1,1,0])
                    modified+=1
                    if self.uint(player+0x398+slot*4)!=EMPTY:
                        raise ValueError('탈리스만 교체 준비에 실패했습니다.')
            for slot,item in plan:
                self.check_process()
                if self.pointer(self.pointer(self.base+self.rva)+8)!=player or self.uint(player+0x10)==0:
                    raise ValueError('캐릭터 상태가 변경됐습니다.')
                if item is not None:
                    descriptor=self.pointer(player+0x5D0)
                    listing=self.pointer(descriptor+0x10)
                    observed=struct.unpack('<III',self.read(listing+item.index*24,12))
                    if observed[0]!=item.handle or observed[1]!=item.item_id or observed[2]==0:
                        raise ValueError('소지품이 변경됐습니다. 다시 시도해 주세요.')
                expected=saved['gear'][str(slot)]['item_id']
                if self.uint(player+0x398+slot*4)==expected and (item is None or self.uint(player+0x340+slot*4)==item.handle):
                    continue
                index=EMPTY if item is None else item.index+current['bias']
                handle=EMPTY if item is None else item.handle
                self.invoke(self.equip_function,[player+0x2B0,slot,'DATA',index,1,1,0],handle)
                modified+=1
                if self.uint(player+0x398+slot*4)!=expected:
                    raise ValueError(f'{dict(SLOTS)[slot]} 교체 결과가 일치하지 않습니다.')
                if item is not None and self.uint(player+0x340+slot*4)!=item.handle:
                    raise ValueError('장비 개체 교체 결과가 일치하지 않습니다.')
            if include_magic and saved['magic']!=current['magic']:
                # Clear first: the engine rejects attuning a spell already present elsewhere.
                for i in range(min(12,magic_slots)):
                    self.check_process()
                    if self.pointer(self.pointer(self.base+self.rva)+8)!=player or self.uint(player+0x10)==0:
                        raise ValueError('캐릭터 상태가 변경됐습니다.')
                    if self.uint(self.pointer(player+0x530)+0x10+i*8)!=EMPTY:
                        self.change_magic(i,None,current['bias'])
                for i,spell in enumerate(saved['magic'][:magic_slots]):
                    if spell==EMPTY: continue
                    item=next(x for x in current['inventory'] if x.item_id==(spell|0x40000000) and x.quantity>0)
                    self.check_process()
                    if self.pointer(self.pointer(self.base+self.rva)+8)!=player or self.uint(player+0x10)==0:
                        raise ValueError('캐릭터 상태가 변경됐습니다.')
                    self.change_magic(i,item,current['bias'])
                actual=[self.uint(self.pointer(player+0x530)+0x10+i*8) for i in range(12)]
                if actual!=saved['magic']:
                    raise ValueError('마법 교체 결과가 일치하지 않습니다.')
            if include_stats:
                for name,offset in STAT_OFFSETS.items():
                    self.check_process()
                    if self.pointer(self.pointer(self.base+self.rva)+8)!=player or self.uint(player+0x10)==0:
                        raise ValueError('캐릭터 상태가 변경됐습니다.')
                    self.write(player+offset,struct.pack('<I',saved['stats'][name]))
                    if self.uint(player+offset)!=saved['stats'][name]:
                        raise ValueError('능력치 쓰기 결과가 일치하지 않습니다.')
            return f'프리셋 불러오기 완료 · {modified}개 슬롯 교체'
        except Exception as exc:
            raise ValueError(f'{exc} 장비·능력치·마법이 일부 변경됐을 수 있습니다. 현재 상태를 확인해 주세요.') from exc

    def change_magic(self,slot,item,bias):
        data=bytearray(128)
        struct.pack_into('<I',data,8,slot)
        if item is None:
            struct.pack_into('<III',data,0x48,EMPTY,0x4FFFFFFF,0xBFFFFFFF)
        else:
            spell=item.item_id & 0x0FFFFFFF
            struct.pack_into('<III',data,0x48,item.index+bias,item.item_id,spell+0xB0000000)
        self.invoke(self.magic_function,[slot,'DATA'],payload=bytes(data))

    def close(self):
        if self.handle:
            try: self.reap()
            except ValueError: pass
            # A timed-out thread retains its allocation until process exit; do not free it.
            if self.pending: self.k.CloseHandle(self.pending[0])
            self.k.CloseHandle(self.handle); self.handle=None
