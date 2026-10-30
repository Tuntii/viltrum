import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import results  # noqa: E402

LOG = [
    ("a", "2026-10-29T10:00:00+03:00", "Merge pull request #109 from Tuntii/docs/readme-oss"),
    ("b", "2026-10-30T10:00:00+03:00", "Merge pull request #110 from Tuntii/feat/jsonenc-types"),
    ("c", "2026-10-30T10:05:00+03:00", "chore(release): 1.14.0 [skip ci]"),
]


def ok(h, setup, base=100):
    return {"hash": h, "setup": setup, "status": "ok", "ir": {"baseline": base}, "rps": {"baseline": 1}}


class ResultsTest(unittest.TestCase):
    def test_release_commits_dropped_and_version_attached(self):
        commits = results.select_commits(LOG)
        self.assertEqual([c["hash"] for c in commits], ["a", "b"])
        self.assertEqual(commits[1]["version"], "v1.14.0")
        self.assertNotIn("version", commits[0])

    def test_pending_skips_same_setup_only(self):
        commits = results.select_commits(LOG)
        have = [ok("a", "1")]
        self.assertEqual(results.pending(commits, have, "1"), ["b"])
        self.assertEqual(results.pending(commits, have, "2"), ["a", "b"])

    def test_publish_prefers_complete_newer_setup(self):
        commits = results.select_commits(LOG)
        have = [ok("a", "1"), ok("b", "1"), ok("a", "2", 90), ok("b", "2", 80)]
        out = results.publish(commits, have)
        self.assertEqual(out["setup"], "2")
        self.assertEqual([c["hash"] for c in out["commits"]], ["b", "a"])
        self.assertEqual(out["commits"][0]["ir"]["baseline"], 80)
        self.assertEqual(out["commits"][0]["version"], "v1.14.0")

    def test_publish_falls_back_while_new_setup_incomplete(self):
        commits = results.select_commits(LOG)
        have = [ok("a", "1"), ok("b", "1"), ok("a", "2")]
        self.assertEqual(results.publish(commits, have)["setup"], "1")

    def test_publish_none_when_no_setup_complete(self):
        commits = results.select_commits(LOG)
        self.assertIsNone(results.publish(commits, [ok("a", "1")]))

    def test_publish_compares_setups_as_numbers(self):
        commits = results.select_commits(LOG)[:1]
        have = [ok("a", "9"), ok("a", "10", 5)]
        self.assertEqual(results.publish(commits, have)["setup"], "10")

    def test_publish_drops_commits_not_on_main(self):
        commits = results.select_commits(LOG)
        have = [ok("a", "1"), ok("b", "1"), ok("gone", "1")]
        hashes = [c["hash"] for c in results.publish(commits, have)["commits"]]
        self.assertNotIn("gone", hashes)

    def test_failed_commit_published_with_status(self):
        commits = results.select_commits(LOG)
        have = [ok("a", "1"), {"hash": "b", "setup": "1", "status": "build_failed"}]
        out = results.publish(commits, have)
        self.assertEqual(out["commits"][0]["status"], "build_failed")
        self.assertNotIn("ir", out["commits"][0])

    def test_add_replaces_same_hash_and_setup(self):
        have = [ok("a", "1", 100), ok("a", "2", 100)]
        have = results.add(have, ok("a", "1", 50))
        self.assertEqual(len(have), 2)
        self.assertEqual([r["ir"]["baseline"] for r in have if r["setup"] == "1"], [50])

    def test_write_json_atomic_leaves_no_temp(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "results.json")
            results.write_json_atomic(p, {"x": 1})
            self.assertEqual(os.listdir(d), ["results.json"])
            with open(p) as f:
                self.assertEqual(json.load(f), {"x": 1})


if __name__ == "__main__":
    unittest.main()
