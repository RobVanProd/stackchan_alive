import unittest

from lan_service import natural_research_request
from memory_probe import load_fixture, run_probe


class MemoryProbeTests(unittest.TestCase):
    def test_probe_meets_registered_retrieval_and_timing_gates(self):
        report = run_probe()
        self.assertTrue(all(report["gates"].values()), report)
        self.assertEqual(24, report["seed_counts"]["facts"])
        self.assertEqual(6, report["seed_counts"]["episodes"])

    def test_probe_queries_do_not_route_to_research(self):
        fixture = load_fixture()
        queries = [row["query"] for row in fixture["exact_queries"]]
        queries += [row["query"] for row in fixture["paraphrase_queries"]]
        queries += fixture["unrelated_queries"]
        routed = [query for query in queries if natural_research_request(str(query))[0] is not None]
        self.assertEqual([], routed)


if __name__ == "__main__":
    unittest.main()
