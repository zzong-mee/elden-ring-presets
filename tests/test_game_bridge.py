import copy
import struct
import unittest
from app.model import EMPTY, Item, SLOTS, typed_id
from app.windows import WindowsGame
from test_app_model import preset, inventory


class SimulatedGame(WindowsGame):
    def __init__(self):
        self.saved=preset();self.saved['exe_sha256']='test-build'
        self.data=copy.deepcopy(self.saved)
        self.data.update(player=0x300000,bias=384,inventory_descriptor=0x400000)
        self.data['inventory']=inventory(self.saved)
        self.digest='test-build';self.base=0x100000;self.rva=0x100;self.equip_function=0x500000
        self.calls=[];self.writes=[];self.changed_inventory=False;self.bad_readback=False;self.hp=100;self.die_after_call=False

    def snapshot(self):return self.data
    def check_process(self):return 1
    def ensure_write(self):return None
    def pointer(self,address):
        return {self.base+self.rva:0x200000,0x200008:self.data['player'],
                self.data['player']+0x5D0:0x400000,0x400010:0x600000}[address]
    def uint(self,address):
        if address==self.data['player']+0x10:return self.hp
        for slot,_ in SLOTS:
            if address==self.data['player']+0x398+slot*4:return self.data['gear'][str(slot)]['item_id']
            if address==self.data['player']+0x340+slot*4:return self.data['gear'][str(slot)]['handle']
        raise AssertionError(hex(address))
    def read(self,address,size):
        index=(address-0x600000)//24
        item=next(x for x in self.data['inventory'] if x.index==index)
        return struct.pack('<III',item.handle+(1 if self.changed_inventory else 0),item.item_id,item.quantity)
    def write(self,address,data):self.writes.append((address,data))
    def invoke(self,function,args,handle_value=EMPTY,payload=None):
        self.calls.append((function,args,handle_value))
        if self.die_after_call:self.hp=0
        if self.bad_readback:return
        slot=args[1]
        if handle_value==EMPTY:self.data['gear'][str(slot)]={'item_id':EMPTY,'handle':0}
        else:
            item=next(x for x in self.data['inventory'] if x.handle==handle_value)
            self.data['gear'][str(slot)]={'item_id':item.item_id&0x0FFFFFFF,'handle':item.handle}


class BridgeTests(unittest.TestCase):
    def test_equipment_uses_game_function_and_fresh_inventory_index(self):
        game=SimulatedGame()
        game.data['gear']['0']={'item_id':9000,'handle':9999}
        message=game.recall(game.saved)
        self.assertIn('완료',message)
        self.assertEqual(len(game.calls),1)
        function,args,handle=game.calls[0]
        self.assertEqual(function,game.equip_function)
        self.assertEqual(args,[0x3002B0,0,'DATA',384,1,1,0])
        self.assertEqual(handle,500)
        self.assertEqual(game.writes,[])  # no direct writes to gear fields

    def test_missing_inventory_item_prevents_all_game_calls(self):
        game=SimulatedGame();game.data['inventory']=game.data['inventory'][1:]
        with self.assertRaises(ValueError):game.recall(game.saved)
        self.assertEqual(game.calls,[])

    def test_changed_inventory_prevents_stale_handle_call(self):
        game=SimulatedGame();game.changed_inventory=True
        game.data['gear']['0']={'item_id':9000,'handle':9999}
        with self.assertRaisesRegex(ValueError,'소지품이 변경'):game.recall(game.saved)
        self.assertEqual(game.calls,[])

    def test_talisman_swap_clears_changed_slots_before_filling(self):
        game=SimulatedGame();target=copy.deepcopy(game.saved)
        target['gear']['17'],target['gear']['18']=target['gear']['18'],target['gear']['17']
        game.recall(target)
        self.assertEqual([(args[1],handle) for _,args,handle in game.calls],
                         [(17,EMPTY),(18,EMPTY),(17,518),(18,517)])
        self.assertEqual(game.data['gear'],target['gear'])

    def test_failed_readback_stops_remaining_calls(self):
        game=SimulatedGame();game.bad_readback=True
        game.data['gear']['0']={'item_id':9000,'handle':9999}
        game.data['gear']['1']={'item_id':9001,'handle':9998}
        with self.assertRaisesRegex(ValueError,'일치하지'):game.recall(game.saved)
        self.assertEqual(len(game.calls),1)

    def test_character_death_stops_remaining_changes(self):
        game=SimulatedGame();game.die_after_call=True
        game.data['gear']['0']={'item_id':9000,'handle':9999}
        game.data['gear']['1']={'item_id':9001,'handle':9998}
        with self.assertRaisesRegex(ValueError,'상태가 변경'):game.recall(game.saved)
        self.assertEqual(len(game.calls),1)

    def test_different_character_and_build_are_rejected(self):
        for field,value in [('character','other'),('exe_sha256','other-build')]:
            game=SimulatedGame();target=copy.deepcopy(game.saved);target[field]=value
            with self.assertRaises(ValueError):game.recall(target)
            self.assertEqual(game.calls,[])


if __name__=='__main__':unittest.main()

class RemoteCallLifetimeTests(unittest.TestCase):
    def make_game(self,wait_result):
        game=WindowsGame.__new__(WindowsGame)
        class Kernel:
            def __init__(self):self.wait_result=wait_result;self.freed=[];self.closed=[];self.allocations=0
            def VirtualAllocEx(self,*args):self.allocations+=1;return 0x800000
            def VirtualProtectEx(self,*args):return True
            def FlushInstructionCache(self,*args):return True
            def CreateRemoteThread(self,*args):return 77
            def WaitForSingleObject(self,*args):return self.wait_result
            def CloseHandle(self,handle):self.closed.append(handle);return True
            def VirtualFreeEx(self,handle,address,*args):self.freed.append(address);return True
        game.k=Kernel();game.handle=99;game.pending=None
        game.write=lambda address,data:None
        game.error=lambda message:RuntimeError(message)
        return game

    def test_completed_remote_call_releases_allocation(self):
        game=self.make_game(0)
        game.invoke(0x500000,[1,2,'DATA',4,1,1,0],123)
        self.assertIsNone(game.pending)
        self.assertEqual(game.k.freed,[0x800000])
        self.assertEqual(game.k.closed,[77])

    def test_timeout_retains_live_code_and_blocks_further_calls(self):
        game=self.make_game(258)
        with self.assertRaises(ValueError):game.invoke(0x500000,[1,2,'DATA',4,1,1,0],123)
        self.assertEqual(game.pending,(77,0x800000))
        self.assertEqual(game.k.freed,[])
        with self.assertRaises(ValueError):game.invoke(0x500000,[1,2,'DATA',4,1,1,0],123)
        self.assertEqual(game.k.allocations,1)
        game.k.wait_result=0;game.reap()
        self.assertIsNone(game.pending)
        self.assertEqual(game.k.freed,[0x800000])
