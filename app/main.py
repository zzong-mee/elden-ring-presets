from __future__ import annotations
import ctypes as C
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import ttk
from app.controller import ControllerInput
from app.model import Store
from app.windows import WindowsGame


class App:
    def __init__(self, root, directory):
        self.root=root; self.directory=directory; self.store=Store(directory/'presets')
        self.game=WindowsGame(); self.jobs=queue.Queue(maxsize=1); self.results=queue.Queue()
        self.busy=False; self.stopping=False; self.previous=[False]*8; self.radial_previous=False
        self.current=None; self.radial_window=None; self.radial_selected=1; self.menu_previous=set()
        settings={}
        try: settings=json.loads((directory/'settings.json').read_text(encoding='utf-8'))
        except (OSError,ValueError): pass
        self.profile=tk.StringVar(value=str(settings.get('profile','기본')))
        self.stats=tk.BooleanVar(value=bool(settings.get('stats',False)))
        self.magic=tk.BooleanVar(value=bool(settings.get('magic',False)))
        self.enabled=tk.BooleanVar(value=True); self.controller=tk.BooleanVar(value=bool(settings.get('controller',True)))
        self.status=tk.StringVar(value='오프라인 게임에서 캐릭터를 불러온 뒤 연결하세요.')
        self.character=tk.StringVar(value='연결 대기 중')
        root.title('Elden Ring Presets · 테스트 빌드'); root.geometry('720x680'); root.minsize(680,650)
        frame=ttk.Frame(root,padding=20); frame.pack(fill='both',expand=True)
        ttk.Label(frame,text='엘든링 장비 프리셋',font=('',18,'bold')).pack(anchor='w')
        ttk.Label(frame,text='게임 1.17.1 대상 · 실제 교체 동작 확인이 필요한 테스트 빌드').pack(anchor='w',pady=(5,12))
        ttk.Label(frame,textvariable=self.character,font=('',11,'bold')).pack(anchor='w')
        top=ttk.Frame(frame);top.pack(fill='x',pady=10)
        ttk.Button(top,text='게임 연결 / 새로 읽기',command=lambda:self.submit('connect')).pack(side='left')
        ttk.Checkbutton(top,text='단축키 활성화',variable=self.enabled).pack(side='right')
        profile=ttk.Frame(frame);profile.pack(fill='x',pady=5)
        ttk.Label(profile,text='프로필 이름').pack(side='left')
        ttk.Entry(profile,textvariable=self.profile,width=22).pack(side='left',padx=10)
        ttk.Label(frame,text='같은 이름의 캐릭터가 둘이면 서로 다른 프로필 이름을 지정하세요.').pack(anchor='w')
        self.rows=[]
        for number in range(1,5):
            row=ttk.Frame(frame,padding=(0,9));row.pack(fill='x')
            ttk.Label(row,text=f'프리셋 {number}',width=12).pack(side='left')
            label=ttk.Label(row,text='미확인',width=12); label.pack(side='left');self.rows.append(label)
            ttk.Button(row,text=f'F{number} · 저장',command=lambda n=number:self.submit('save',n)).pack(side='left',padx=5)
            ttk.Button(row,text=f'{number} · 불러오기',command=lambda n=number:self.submit('load',n)).pack(side='left')
        options=ttk.LabelFrame(frame,text='불러올 내용',padding=8);options.pack(fill='x',pady=8)
        ttk.Label(options,text='무기·방어구·탈리스만은 항상 포함됩니다.').pack(anchor='w')
        ttk.Checkbutton(options,text='능력치와 레벨도 복원',variable=self.stats).pack(anchor='w')
        ttk.Checkbutton(options,text='기억한 마법도 복원',variable=self.magic).pack(anchor='w')
        ttk.Label(frame,text='메뉴·텍스트 입력 중에는 단축키를 꺼 주세요. 숫자키의 기존 기능을 차단하지 않습니다.').pack(anchor='w')
        ttk.Label(frame,text='Ctrl+F: 프리셋 선택 메뉴 · 게임 창에 포커스가 있을 때 단축키 작동').pack(anchor='w',pady=5)
        ttk.Checkbutton(frame,text='패드 활성화 · RT/R2+십자키 불러오기 · LT/L2+RT/R2+십자키 저장',variable=self.controller).pack(anchor='w')
        ttk.Label(frame,text='↑ 1 · → 2 · ↓ 3 · ← 4 / LT+RT+RS (L2+R2+R3): 선택 메뉴').pack(anchor='w')
        self.controller_status=tk.StringVar(value='패드 초기화 중…')
        ttk.Label(frame,textvariable=self.controller_status,wraplength=650).pack(anchor='w',pady=5)
        ttk.Label(frame,textvariable=self.status,wraplength=590,foreground='#24547a').pack(fill='x',pady=12)
        ttk.Button(frame,text='데이터 폴더 열기',command=lambda:os.startfile(str(directory))).pack(anchor='w')
        root.protocol('WM_DELETE_WINDOW',self.close)
        self.pad=ControllerInput()
        self.worker=threading.Thread(target=self.work,daemon=True);self.worker.start()
        root.after(50,self.tick)
        self.submit('connect')

    def settings(self):
        return dict(profile=self.profile.get().strip() or '기본',stats=self.stats.get(),magic=self.magic.get(),controller=self.controller.get())

    def submit(self,action,number=1):
        if self.busy or self.stopping: return
        settings=self.settings()
        self.busy=True;self.status.set('처리 중…')
        self.jobs.put_nowait((action,number,settings))

    def work(self):
        while True:
            if self.stopping:
                self.game.close();return
            try: job=self.jobs.get(timeout=0.1)
            except queue.Empty: continue
            action,number,settings=job
            try:
                snapshot=self.game.snapshot()
                if action=='save':
                    data={k:snapshot[k] for k in ('schema','character','gear','stats','magic','exe_sha256')}
                    data['saved_at']=datetime.now(timezone.utc).isoformat()
                    self.store.save(snapshot['character'],settings['profile'],number,data)
                    message=f'프리셋 {number} 저장 완료'
                elif action=='load':
                    data=self.store.load(snapshot['character'],settings['profile'],number)
                    message=self.game.recall(data,settings['stats'],settings['magic'])
                    snapshot=self.game.snapshot()
                else:
                    message='게임 데이터 연결 완료 · 장비 교체 동작은 별도 확인이 필요합니다.'
                temporary=self.directory/'settings.tmp'
                temporary.write_text(json.dumps(settings,ensure_ascii=False),encoding='utf-8')
                temporary.replace(self.directory/'settings.json')
                self.results.put((True,message,snapshot,settings['profile']))
            except Exception as exc:
                logging.exception('Operation failed: %s',action)
                self.results.put((False,str(exc),None,settings['profile']))

    def tick(self):
        try:
            while True:
                ok,message,snapshot,profile=self.results.get_nowait()
                self.busy=False; self.status.set(message)
                if snapshot:
                    self.current=snapshot
                    self.character.set(f"{snapshot['character']} · 레벨 {snapshot['stats']['LEVEL']}")
                    for i,label in enumerate(self.rows,1):
                        label.config(text='저장됨' if self.store.path(snapshot['character'],profile,i).exists() else '비어 있음')
        except queue.Empty: pass
        if self.stopping:
            if not self.worker.is_alive(): self.root.destroy();return
            self.root.after(50,self.tick);return
        down=self.game.keys(); active=self.enabled.get() and self.game.foreground()
        actions=[i for i in range(8) if down[i] and not self.previous[i]]
        self.previous=down
        if active and actions:
            index=actions[0]; self.submit('save' if index<4 else 'load',index%4+1)
        radial=bool(self.game.u.GetAsyncKeyState(0x11)&0x8000 and self.game.u.GetAsyncKeyState(0x46)&0x8000)
        if radial and not self.radial_previous and active: self.show_radial()
        self.radial_previous=radial
        menu_open=bool(self.radial_window and self.radial_window.winfo_exists())
        action=self.pad.poll(active and self.controller.get())
        self.controller_status.set(self.pad.describe())
        if action:
            kind,number=action
            if kind=='menu': self.show_radial()
            else: self.submit(kind,number)
        # The selection window has focus, so handle its pad controls separately.
        if menu_open and self.enabled.get() and self.controller.get():
            pressed=self.pad.pressed
            fresh=pressed-self.menu_previous
            for number,direction in enumerate(('dpad_up','dpad_right','dpad_down','dpad_left'),1):
                if direction in fresh:
                    self.radial_selected=number
                    self.radial_window.title(f'프리셋 {number} 선택 · A/× 확인 · B/○ 취소')
            if 'b' in fresh: self.radial_window.destroy()
            elif 'a' in fresh:
                self.radial_window.destroy();self.submit('load',self.radial_selected)
        self.menu_previous=set(self.pad.pressed)
        self.root.after(50,self.tick)

    def show_radial(self):
        if self.radial_window and self.radial_window.winfo_exists(): return
        window=tk.Toplevel(self.root); self.radial_window=window
        self.radial_selected=1
        window.title('프리셋 1 선택 · 십자키 선택 · A/× 확인 · B/○ 취소');window.attributes('-topmost',True)
        window.geometry(f'300x240+{self.root.winfo_screenwidth()//2-150}+{self.root.winfo_screenheight()//2-120}')
        positions=[(1,0),(2,1),(1,2),(0,1)]
        for number,(column,row) in enumerate(positions,1):
            def choose(n=number): window.destroy();self.submit('load',n)
            ttk.Button(window,text=f'프리셋 {number}',command=choose).grid(column=column,row=row,padx=5,pady=15)
        window.bind('<Escape>',lambda _:window.destroy())

    def close(self):
        if self.stopping:return
        self.pad.close()
        self.stopping=True;self.enabled.set(False);self.status.set('진행 중인 요청을 마친 뒤 종료합니다…')


def main():
    if os.name!='nt': raise SystemExit('Windows x64에서 실행해 주세요.')
    directory=Path(os.environ.get('LOCALAPPDATA',str(Path.home()))) / 'EldenRingPresets'
    directory.mkdir(parents=True,exist_ok=True)
    logging.basicConfig(filename=directory/'app.log',level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    kernel=C.WinDLL('kernel32',use_last_error=True)
    kernel.CreateMutexW.argtypes=[C.c_void_p,C.c_bool,C.c_wchar_p]
    kernel.CreateMutexW.restype=C.c_void_p
    kernel.CloseHandle.argtypes=[C.c_void_p];kernel.CloseHandle.restype=C.c_bool
    mutex=kernel.CreateMutexW(None,False,'Local\\EldenRingPresets-FourPresets')
    already_running=C.get_last_error()==183
    root=tk.Tk()
    try:
        if not mutex or already_running:
            from tkinter import messagebox
            messagebox.showerror('실행 안내','프리셋 앱이 이미 실행 중이거나 실행 잠금을 얻지 못했습니다.')
            root.destroy();return
        App(root,directory);root.mainloop()
    except Exception:
        logging.exception('Application startup failed')
        from tkinter import messagebox
        messagebox.showerror('실행 오류',f'앱을 실행하지 못했습니다. 로그: {directory / "app.log"}')
        raise
    finally:
        if mutex: kernel.CloseHandle(mutex)

if __name__=='__main__':main()
