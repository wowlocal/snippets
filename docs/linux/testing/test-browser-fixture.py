"""Regression checks for observations delivered out of browser event order."""
import unittest
from browser_fixture import State


class ObservationTests(unittest.TestCase):
    def setUp(self):
        self.state = State()
        self.seq = self.state.advance()

    def value(self, event, expanded=False, **changes):
        return dict(dict(seq=self.seq, event=event, bytes=45 if expanded else 0,
                         first=expanded, second=False, literal=False,
                         composing=False), **changes)

    def test_delayed_empty_snapshot_cannot_replace_expansion(self):
        self.assertTrue(self.state.accept(self.value(8, expanded=True)))
        self.assertFalse(self.state.accept(self.value(7)))
        self.assertTrue(self.state.observation()['first'])

    def test_new_case_rejects_previous_case_success(self):
        self.state.advance()
        self.assertFalse(self.state.accept(self.value(100, expanded=True)))
        self.assertEqual(self.state.observation(), {})

    def test_later_failure_is_not_hidden_by_old_success(self):
        self.state.accept(self.value(8, expanded=True))
        self.assertTrue(self.state.accept(self.value(9)))
        self.assertFalse(self.state.observation()['first'])

    def test_schema_cannot_accept_text_or_boolean_sequence(self):
        self.assertFalse(self.state.accept(self.value(1, body='private')))
        self.assertFalse(self.state.accept(self.value(1, seq=True)))
        self.assertFalse(self.state.accept(self.value(1, first=1)))
        self.assertEqual(self.state.observation(), {})


if __name__ == '__main__':
    unittest.main()
