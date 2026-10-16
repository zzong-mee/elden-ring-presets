from __future__ import annotations
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path

EMPTY = 0xFFFFFFFF
SLOTS = [(0, '왼손 1'), (1, '오른손 1'), (2, '왼손 2'), (3, '오른손 2'),
         (4, '왼손 3'), (5, '오른손 3'), (12, '머리'), (13, '몸통'),
         (14, '팔'), (15, '다리'), (17, '탈리스만 1'), (18, '탈리스만 2'),
         (19, '탈리스만 3'), (20, '탈리스만 4')]
STAT_OFFSETS = dict(VIGOR=0x3C, MIND=0x40, ENDURANCE=0x44, STRENGTH=0x48,
                    DEXTERITY=0x4C, INTELLIGENCE=0x50, FAITH=0x54, ARCANE=0x58, LEVEL=0x68)

@dataclass(frozen=True)
class Item:
    index: int
    handle: int
    item_id: int
    quantity: int

@dataclass(frozen=True)
class Equipped:
    slot: int
    item_id: int
    handle: int
    index: int


def typed_id(slot, item_id):
    if item_id == EMPTY:
        return EMPTY
    category = 0 if slot <= 5 else 1 if 12 <= slot <= 15 else 2
    return item_id | (category << 28)


def inventory_bias(equipment, inventory):
    by_handle = {x.handle: x for x in inventory if x.quantity > 0}
    deltas = set()
    for equipped in equipment:
        if equipped.item_id == EMPTY:
            continue
        item = by_handle.get(equipped.handle)
        if item is None or item.item_id != typed_id(equipped.slot, equipped.item_id):
            raise ValueError('현재 장비와 소지품의 연결을 검증하지 못했습니다.')
        deltas.add(equipped.index - item.index)
    if len(deltas) != 1:
        raise ValueError('장비와 소지품의 인덱스 연결이 일치하지 않습니다.')
    value = deltas.pop()
    if not 0 <= value <= 0x100000:
        raise ValueError('소지품 인덱스 범위가 잘못되었습니다.')
    return value


def plan_equipment(saved, inventory):
    result = []
    used = set()
    for slot, _ in SLOTS:
        desired = saved[str(slot)]
        item_id, handle = desired['item_id'], desired['handle']
        if item_id == EMPTY:
            result.append((slot, None))
            continue
        # Unarmed slots legitimately share the game's built-in fist item.
        unarmed = slot <= 5 and item_id == 110000
        candidates = [x for x in inventory if x.quantity > 0 and
                      x.item_id == typed_id(slot, item_id) and
                      (unarmed or x.handle not in used)]
        candidates.sort(key=lambda x: (x.handle != handle, x.index))
        if not candidates:
            name = dict(SLOTS)[slot]
            raise ValueError(f'{name}에 필요한 장비가 소지품에 없습니다. 교체를 시작하지 않았습니다.')
        chosen = candidates[0]
        used.add(chosen.handle)
        result.append((slot, chosen))
    return result


def validate_preset(data):
    if data.get('schema') != 1 or not isinstance(data.get('character'), str) or not data['character']:
        raise ValueError('지원하지 않는 프리셋 파일입니다.')
    if set(data.get('gear', {})) != {str(s) for s, _ in SLOTS}:
        raise ValueError('프리셋 장비 슬롯 구성이 잘못되었습니다.')
    for entry in data['gear'].values():
        for key in ('item_id', 'handle'):
            if type(entry.get(key)) is not int or not 0 <= entry[key] <= EMPTY:
                raise ValueError('프리셋 장비 값이 잘못되었습니다.')
    stats = data.get('stats', {})
    if set(stats) != set(STAT_OFFSETS):
        raise ValueError('프리셋 능력치 구성이 잘못되었습니다.')
    for key, value in stats.items():
        if type(value) is not int or not 1 <= value <= (713 if key == 'LEVEL' else 99):
            raise ValueError('프리셋 능력치 범위가 잘못되었습니다.')
    spells = data.get('magic')
    if not isinstance(spells, list) or len(spells) != 12 or any(type(x) is not int or not 0 <= x <= EMPTY for x in spells):
        raise ValueError('프리셋 마법 구성이 잘못되었습니다.')
    return data


class Store:
    def __init__(self, root):
        self.root = Path(root)

    def path(self, character, profile, number):
        if number not in range(1, 5):
            raise ValueError('프리셋 번호는 1~4입니다.')
        identity = hashlib.sha256((character + '\0' + profile).encode('utf-8')).hexdigest()
        return self.root / identity / f'preset-{number}.json'

    def save(self, character, profile, number, data):
        validate_preset(data)
        if data['character'] != character:
            raise ValueError('캐릭터가 일치하지 않습니다.')
        path = self.path(character, profile, number)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix('.tmp')
        with temporary.open('w', encoding='utf-8') as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)

    def load(self, character, profile, number):
        path = self.path(character, profile, number)
        if not path.exists():
            raise ValueError('먼저 해당 프리셋을 저장해 주세요.')
        data = validate_preset(json.loads(path.read_text(encoding='utf-8')))
        if data['character'] != character:
            raise ValueError('다른 캐릭터의 프리셋입니다.')
        return data
