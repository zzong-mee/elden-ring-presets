import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest
from app.model import Item, Equipped, SLOTS, STAT_OFFSETS, Store, EMPTY, inventory_bias, plan_equipment, typed_id, validate_preset
from app.windows import call_code


def preset():
    return dict(schema=1,character='test-character',gear={str(slot):dict(item_id=1000+slot,handle=500+slot) for slot,_ in SLOTS},
                stats={k:100 if k=='LEVEL' else 20 for k in STAT_OFFSETS},magic=[EMPTY]*12)


def inventory(data):
    return [Item(i,entry['handle'],typed_id(int(slot),entry['item_id']),1) for i,(slot,entry) in enumerate(data['gear'].items())]


class AppModelTests(unittest.TestCase):
    def test_four_presets_survive_restart_and_overwrite(self):
        data=preset()
        with tempfile.TemporaryDirectory() as directory:
            store=Store(directory)
            for n in range(1,5):store.save(data['character'],'main',n,data)
            restarted=Store(directory)
            for n in range(1,5):self.assertEqual(restarted.load(data['character'],'main',n),data)
            changed=copy.deepcopy(data); changed['gear']['0']['item_id']=2000
            store.save(data['character'],'main',4,changed)
            self.assertEqual(restarted.load(data['character'],'main',4),changed)
            self.assertEqual(restarted.load(data['character'],'main',1),data)
            for number in (0,5):
                with self.assertRaises(ValueError):store.save(data['character'],'main',number,data)
            with self.assertRaises(ValueError):store.load('different-character','main',1)
            with self.assertRaises(ValueError):store.load(data['character'],'different-profile',1)

    def test_re_resolves_index_but_prefers_exact_copy(self):
        data=preset(); items=inventory(data)
        items=[Item(x.index+50,x.handle,x.item_id,x.quantity) for x in items]
        items.insert(0,Item(0,123,items[0].item_id,1))
        plan=plan_equipment(data['gear'],items)
        self.assertEqual(plan[0][1].handle,500)
        self.assertEqual(plan[0][1].index,50)

    def test_missing_or_zero_quantity_rejects_whole_plan(self):
        data=preset();items=inventory(data)
        for missing in (items[:-1],[Item(x.index,x.handle,x.item_id,0) for x in items]):
            with self.assertRaises(ValueError):plan_equipment(data['gear'],missing)

    def test_same_weapon_needs_two_copies(self):
        data=preset();data['gear']['1']=data['gear']['0'].copy();items=inventory(data)
        items=[x for x in items if x.index!=1]
        with self.assertRaises(ValueError):plan_equipment(data['gear'],items)
        items.append(Item(100,900,typed_id(1,data['gear']['1']['item_id']),1))
        result=plan_equipment(data['gear'],items)
        self.assertNotEqual(result[0][1].handle,result[1][1].handle)

    def test_bare_hands_can_share_game_item(self):
        data=preset()
        for slot in range(6):data['gear'][str(slot)]={'item_id':110000,'handle':999}
        items=inventory(data);items=[x for x in items if x.index>=6]+[Item(1,999,110000,1)]
        plan=plan_equipment(data['gear'],items)
        self.assertTrue(all(item.handle==999 for _,item in plan[:6]))

    def test_empty_accessory_is_explicit_unequip(self):
        data=preset();data['gear']['17']={'item_id':EMPTY,'handle':0}
        result=dict(plan_equipment(data['gear'],inventory(data)))
        self.assertIsNone(result[17])

    def test_inventory_bias_requires_all_links_to_agree(self):
        data=preset();items=inventory(data)
        equipped=[Equipped(slot,data['gear'][str(slot)]['item_id'],items[i].handle,i+384) for i,(slot,_) in enumerate(SLOTS)]
        self.assertEqual(inventory_bias(equipped,items),384)
        equipped[0]=Equipped(0,equipped[0].item_id,equipped[0].handle,999)
        with self.assertRaises(ValueError):inventory_bias(equipped,items)

    def test_affinity_and_upgrade_variants_remain_distinct(self):
        data=preset();items=inventory(data)
        first=items[0];items[0]=Item(first.index,first.handle,first.item_id+1,1)
        with self.assertRaises(ValueError):plan_equipment(data['gear'],items)

    def test_corrupt_preset_is_rejected(self):
        original=preset()
        for mutate in (lambda d:d['gear'].pop('0'), lambda d:d['stats'].update(LEVEL=9999),
                       lambda d:d.update(magic=[1]), lambda d:d['gear']['0'].update(handle=-1)):
            data=copy.deepcopy(original);mutate(data)
            with self.assertRaises(ValueError):validate_preset(data)

    def test_game_call_uses_x64_argument_locations(self):
        args=[0x123456789,20,0x234567890,1771,1,1,0]
        code=call_code(0x345678901,args)
        self.assertEqual(code[:4],bytes.fromhex('48 83 ec 38'))
        for i,value in enumerate(args[:4]):self.assertEqual(struct.unpack_from('<Q',code,6+i*10)[0],value)
        for i,value in enumerate(args[4:]):
            self.assertEqual(code[44+i*9:49+i*9],bytes.fromhex('48 c7 44 24')+bytes([0x20+i*8]))
            self.assertEqual(struct.unpack_from('<I',code,49+i*9)[0],value)
        self.assertEqual(code[-7:],bytes.fromhex('ff d0 48 83 c4 38 c3'))


if __name__=='__main__':unittest.main()
