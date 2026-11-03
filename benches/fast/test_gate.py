import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate  # noqa: E402


def line(status="ok", **ir):
    return {"status": status, "ir": ir}


class Gate(unittest.TestCase):
    def test_within_limit_passes(self):
        _, failed = gate.compare(line(json=1000), line(json=1010))
        self.assertFalse(failed)

    def test_over_limit_fails(self):
        md, failed = gate.compare(line(json=1000, baseline=10), line(json=1011, baseline=10))
        self.assertTrue(failed)
        self.assertIn("+1.10% ❌", md)

    def test_new_scenario_is_not_a_regression(self):
        md, failed = gate.compare(line(json=1000), line(json=1000, plain=5))
        self.assertFalse(failed)
        self.assertIn("| plain | – | 5 | new |", md)

    def test_head_that_does_not_build_fails(self):
        _, failed = gate.compare(line(json=1), {"status": "build_failed"})
        self.assertTrue(failed)

    def test_broken_base_does_not_fail_the_pr(self):
        _, failed = gate.compare({"status": "run_failed"}, line(json=1))
        self.assertFalse(failed)


if __name__ == "__main__":
    unittest.main()
