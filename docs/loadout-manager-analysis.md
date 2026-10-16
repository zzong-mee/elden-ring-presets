# Loadout Manager 1.3.5 정적 분석

사용자가 제공한 Nexus mod 8423 배포 ZIP의 분할 파일 두 개를 순서대로 결합했다.
ZIP CRC 검사에 오류가 없었으며, 내부 EXE는 실행하지 않았다.
EXE SHA-256: `31a132aceee81a1e2b71fc4ba1d149e074844b36a7c9d029fd1f1d10813727f1`.
이 값은 분석 대상 식별용이며 배포자 서명 검증은 아니다.

## 확인한 구조

- Windows x64 PE, PyInstaller CArchive, Python 3.13 (`python313.dll`).
- `main`, `utils.hotkey_manager`, `utils.memory_interface`, `ui.main_window_redesigned` 등의 Python 바이트코드가 포함되어 있다.
- 원본 소스 전체를 복원한 것은 아니다. 포함된 코드 객체를 역어셈블해 동작을 추적했다.
- 분석 중 EXE 또는 추출된 애플리케이션 코드는 실행하지 않았다.
- 추출물은 `/workspace/analysis/loadout-manager`에 두었고 저장소에 제삼자 실행 파일이나 코드를 복사하지 않았다.

## 단축키 기능

`utils.hotkey_manager.HotkeyManager.load_keyboard_hotkeys`는 현재 작업 디렉터리의
`keyboard_hotkeys.json`을 읽는다. 파일이 있으면 기본값과 병합하지 않고 파일 내용을 사용한다.
키 조합은 문자열 배열이다. `normalize_key`는 `f1`~`f12` 및 숫자키를 처리한다.
`ui.main_window_redesigned.MainWindow.register_hotkeys`는 `save_preset_1`~`save_preset_9`,
`load_preset_1`~`load_preset_9` 콜백을 등록한다.

`get_preset_name_for_slot`는 프리셋 목록의 slot-1 위치를 사용한다. 따라서 프리셋이
존재해야 한다. F1 키만으로 없는 프리셋을 새로 만든다고 보장할 수 없다.
`hotkey_save_preset`는 장비·마법·아이콘을 읽고 UI의 능력치를 포함해 저장한다.
`hotkey_load_and_apply`는 `load_and_apply_preset`를 호출한다.

예제 `examples/loadout-manager/keyboard_hotkeys.json`은 요청한 6개 동작만 지정한다.
다른 기본 단축키는 활성화하지 않아 숫자 단축키와의 겹침을 줄인다.
조합 판정은 키 집합의 포함 여부이므로 Ctrl+1 같은 입력에도 단독 1 바인딩이 작동할 수 있다.
동작별 0.5초 쿨다운이 있으며 누르고 있을 때의 자동 반복을 완전히 차단하는지는
Windows 실사용 확인이 필요하다. 단축키 감지는 pynput 기반 전역 리스너를 사용한다.
게임 창 포커스에서만 작동한다는 보장은 확인하지 못했다.

## 요청한 장비 교체 기능과의 차이

`utils.memory_interface.MemoryInterface.write_gear_slots`는 JSON 포인터 체인을 해석한 뒤
`pymem`의 `write_uint` 또는 `write_ushort`로 값을 직접 쓴다.
이 함수에는 인벤토리 탐색이나 장비 소유 여부 확인 호출이 없다.
이는 게임의 정상 장비 교체 API를 사용하는 방식과 다르다.

`load_and_apply_preset`는 장비 토글을 참고하며 `write_gear_slots` 외에도
`write_character_stats`, `write_magic_slots`, `write_all_icon_slots`를 호출한다.
따라서 단축키 설정만 바꾸어 장비 전용·소지품 검증을 보장할 수 없다.

## 버전 및 검증 범위

사용자 게임은 App/Regulation 1.17.1이다. ZIP의 5개 오프셋 JSON에는 버전 선언이 없다.
`MemoryInterface.__init__`에서 기본 `memory offsets/memory_offsets.json`을 읽는 경로를 확인했다.
숫자 접미사는 게임 버전 번호라고 판단할 근거가 없다. 주소를 임의 교체하지 않는다.

확인 완료: ZIP 무결성, 패키징 형식, 바이트코드 정적 분석, 설정 JSON 문법과 동작 이름.
미확인: Windows 실행, 최신 게임 주소 유효성, DLC 실제 장비, 인벤토리 소유 검증,
실제 저장/불러오기, 포커스/메뉴 중 입력, 장비 전용 동작.

## 기존 모드에서 키 배치만 적용하는 방법

1. Loadout Manager를 종료한다.
2. 기존 `keyboard_hotkeys.json`이 있으면 백업한다.
3. 예제 파일을 원본 모드의 EXE 옆에 `keyboard_hotkeys.json`이라는 이름으로 복사한다.
4. EXE 폴더가 작업 디렉터리가 되도록 실행한다. 바로 가기를 쓰면 '시작 위치'를 EXE 폴더로 지정한다.
5. 프리셋 목록에 사용할 프리셋 3개가 있어야 한다. 키는 목록 순서의 1~3번에 연결된다.

이 절차는 키 배치 설정 안내이다. 1.17.1 호환성 또는 장비 전용 동작을 검증한 설치 패키지가 아니다.
원본 모드 실행 시 능력치·마법 복원이 함께 일어날 수 있으므로 장비 전용 동작으로 오인하지 않는다.
