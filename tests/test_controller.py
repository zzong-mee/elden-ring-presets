import unittest
from types import SimpleNamespace
from app.controller import action_for, CombinationEdges, ControllerInput


class ControllerTests(unittest.TestCase):
    def test_original_four_slot_combinations(self):
        for number, direction in enumerate(('dpad_up', 'dpad_right', 'dpad_down', 'dpad_left'), 1):
            self.assertEqual(action_for({'rt', direction}), ('load', number))
            self.assertEqual(action_for({'lt', 'rt', direction}), ('save', number))
            self.assertIsNone(action_for({'lt', direction}))
            self.assertIsNone(action_for({direction}))
        self.assertEqual(action_for({'lt', 'rt', 'rs'}), ('menu', 0))

    def test_save_has_priority_and_release_does_not_load(self):
        edges = CombinationEdges()
        self.assertEqual(edges.update({7: {'lt', 'rt', 'dpad_up'}}), ('save', 1))
        self.assertIsNone(edges.update({7: {'lt', 'rt', 'dpad_up'}}))
        self.assertIsNone(edges.update({7: {'rt', 'dpad_up'}}))
        self.assertIsNone(edges.update({7: {'rt'}}))
        self.assertEqual(edges.update({7: {'rt', 'dpad_up'}}), ('load', 1))

    def test_disabled_and_foreground_transition_does_not_replay_held_chord(self):
        edges = CombinationEdges()
        self.assertIsNone(edges.update({0: {'rt', 'dpad_down'}}, False))
        self.assertIsNone(edges.update({0: {'rt', 'dpad_down'}}, True))
        edges.update({0: set()})
        self.assertEqual(edges.update({0: {'rt', 'dpad_down'}}), ('load', 3))

    def test_multiple_devices_do_not_combine_their_buttons(self):
        edges = CombinationEdges()
        self.assertIsNone(edges.update({1: {'rt'}, 3: {'dpad_up'}}))
        edges.update({1: {'rt'}, 3: set()})
        self.assertEqual(edges.update({1: {'rt'}, 3: {'rt', 'dpad_left'}}), ('load', 4))
        edges.update({})
        self.assertEqual(edges.update({9: {'rt', 'dpad_right'}}), ('load', 2))

    def test_sdl_mapped_trigger_threshold_and_dpad(self):
        names = ('CONTROLLER_BUTTON_DPAD_UP', 'CONTROLLER_BUTTON_DPAD_RIGHT',
                 'CONTROLLER_BUTTON_DPAD_DOWN', 'CONTROLLER_BUTTON_DPAD_LEFT',
                 'CONTROLLER_BUTTON_RIGHTSTICK', 'CONTROLLER_BUTTON_A', 'CONTROLLER_BUTTON_B',
                 'CONTROLLER_AXIS_TRIGGERLEFT', 'CONTROLLER_AXIS_TRIGGERRIGHT')
        pad = ControllerInput.__new__(ControllerInput)
        pad.pygame = SimpleNamespace(**{name: i for i, name in enumerate(names)})
        mapped = SimpleNamespace(get_button=lambda i: i == 1,
                                 get_axis=lambda i: 32767 if i == 8 else 0)
        self.assertEqual(pad.read(None, mapped), {'rt', 'dpad_right'})
        mapped.get_axis = lambda i: 16383
        self.assertEqual(pad.read(None, mapped), {'dpad_right'})

    def test_unmapped_original_axes_and_hat_layout(self):
        pad = ControllerInput.__new__(ControllerInput)
        pad.pygame = SimpleNamespace()
        joystick = SimpleNamespace(get_numbuttons=lambda: 10, get_button=lambda i: i == 9,
                                   get_numaxes=lambda: 6, get_axis=lambda i: 1,
                                   get_numhats=lambda: 1, get_hat=lambda i: (0, 1))
        self.assertEqual(pad.read(joystick, None), {'lt', 'rt', 'rs', 'dpad_up'})
        joystick.get_numaxes = lambda: 5
        self.assertEqual(pad.read(joystick, None), {'rs', 'dpad_up'})

    def test_sdl_initializes_and_polls_without_hardware(self):
        try:
            import pygame
        except ImportError:
            self.skipTest('SDL dependency is installed in the Windows build workflow')
        pad = ControllerInput()
        try:
            self.assertEqual(pad.error, '')
            pad.poll(False)
            self.assertEqual(pad.error, '')
        finally:
            pad.close()
