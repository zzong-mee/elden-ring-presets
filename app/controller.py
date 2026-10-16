"""SDL input with Loadout Manager's default controller combinations.

SDL's mapped controller API normalizes Xbox/PlayStation buttons and triggers.
Unmapped joysticks use the original mod's raw button/axis/hat layout.
All SDL calls run on the Tk main thread, including the event pump.
"""
import logging
import os

DIRECTIONS = ('dpad_up', 'dpad_right', 'dpad_down', 'dpad_left')


def action_for(buttons):
    if {'lt', 'rt', 'rs'} <= buttons:
        return ('menu', 0)
    if 'rt' in buttons:
        for number, direction in enumerate(DIRECTIONS, 1):
            if direction in buttons:
                return ('save' if 'lt' in buttons else 'load', number)
    return None


class CombinationEdges:
    """One action per direction press; modifier changes cannot cause a recall.

    In particular releasing LT from a held save chord must never load a preset.
    Re-arm after releasing the direction (or RS for the menu).
    """
    def __init__(self):
        self.previous = {}

    def update(self, states, enabled=True):
        result = None
        next_previous = {}
        for identity, buttons in states.items():
            before = self.previous.get(identity, set())
            next_previous[identity] = set(buttons)
            action = action_for(buttons)
            controls = set(DIRECTIONS) | {'rs'}
            if enabled and action and (not (before & controls) or action_for(before) is None) and result is None:
                result = action
        self.previous = next_previous
        return result


class ControllerInput:
    def __init__(self):
        self.devices = {}
        self.edges = CombinationEdges()
        self.error = ''
        self.pygame = None
        self.names = []
        self.pressed = set()
        # The game has focus while this app receives controller input.
        os.environ['SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS'] = '1'
        os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = '1'
        try:
            import pygame
            from pygame._sdl2 import controller
            self.pygame = pygame
            self.api = controller
            pygame.display.init()
            pygame.joystick.init()
            controller.init()
            self.refresh()
        except Exception as exc:
            self.error = str(exc)
            logging.exception('Controller initialization failed')

    def refresh(self):
        pygame = self.pygame
        present = set()
        for index in range(pygame.joystick.get_count()):
            joystick = pygame.joystick.Joystick(index)
            identity = joystick.get_instance_id()
            present.add(identity)
            if identity not in self.devices:
                mapped = self.api.Controller(index) if self.api.is_controller(index) else None
                self.devices[identity] = (joystick, mapped)
                logging.info('Controller connected: %s; SDL mapped=%s', joystick.get_name(), mapped is not None)
        for identity in set(self.devices) - present:
            joystick, mapped = self.devices.pop(identity)
            if mapped is not None:
                mapped.quit()
            joystick.quit()
            logging.info('Controller disconnected: %s', identity)

    def read(self, joystick, mapped):
        pygame = self.pygame
        buttons = set()
        if mapped is not None:
            for name, constant in (
                ('dpad_up', 'CONTROLLER_BUTTON_DPAD_UP'),
                ('dpad_right', 'CONTROLLER_BUTTON_DPAD_RIGHT'),
                ('dpad_down', 'CONTROLLER_BUTTON_DPAD_DOWN'),
                ('dpad_left', 'CONTROLLER_BUTTON_DPAD_LEFT'),
                ('rs', 'CONTROLLER_BUTTON_RIGHTSTICK'),
                ('a', 'CONTROLLER_BUTTON_A'), ('b', 'CONTROLLER_BUTTON_B')):
                if mapped.get_button(getattr(pygame, constant)):
                    buttons.add(name)
            for name, constant in (('lt', 'CONTROLLER_AXIS_TRIGGERLEFT'), ('rt', 'CONTROLLER_AXIS_TRIGGERRIGHT')):
                if mapped.get_axis(getattr(pygame, constant)) > 16383:
                    buttons.add(name)
        else:
            # Same raw layout as the reference mod; mapped SDL is preferred.
            for index, name in ((0, 'a'), (1, 'b'), (9, 'rs')):
                if index < joystick.get_numbuttons() and joystick.get_button(index):
                    buttons.add(name)
            if joystick.get_numaxes() >= 6:
                for index, name in ((4, 'lt'), (5, 'rt')):
                    if joystick.get_axis(index) > 0.5:
                        buttons.add(name)
            for index in range(joystick.get_numhats()):
                x, y = joystick.get_hat(index)
                buttons.update(name for flag, name in ((y > 0, 'dpad_up'), (x > 0, 'dpad_right'),
                                                       (y < 0, 'dpad_down'), (x < 0, 'dpad_left')) if flag)
        return buttons

    def poll(self, enabled=True):
        if self.pygame is None:
            return None
        try:
            # Drain events as well as pumping so the background queue cannot fill.
            self.pygame.event.get()
            self.refresh()
            states = {identity: self.read(*device) for identity, device in self.devices.items()}
            self.names = [joystick.get_name() for joystick, _ in self.devices.values()]
            self.pressed = set().union(*states.values()) if states else set()
            self.error = ''
            return self.edges.update(states, enabled)
        except Exception as exc:
            if self.error != str(exc):
                logging.exception('Controller polling failed')
            self.error = str(exc)
            self.edges.update({}, False)
            return None

    def describe(self):
        if self.error:
            return '패드 오류: ' + self.error
        if not self.names:
            return '패드 연결 대기 중 · USB/Bluetooth 연결 후 자동 감지합니다.'
        labels = {'lt': 'LT/L2', 'rt': 'RT/R2', 'rs': 'RS/R3',
                  'dpad_up': '↑', 'dpad_right': '→', 'dpad_down': '↓', 'dpad_left': '←'}
        pressed = ' + '.join(labels.get(name, name.upper()) for name in sorted(self.pressed)) or '없음'
        return '패드: ' + ', '.join(self.names) + ' · 입력: ' + pressed

    def close(self):
        if self.pygame is not None:
            for joystick, mapped in self.devices.values():
                if mapped is not None:
                    mapped.quit()
                joystick.quit()
            self.devices.clear()
            self.api.quit()
            self.pygame.quit()
            self.pygame = None
