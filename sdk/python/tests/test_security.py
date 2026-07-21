from __future__ import annotations

import unittest

from operon.providers.openai_compatible import OpenAICompatibleProvider


class ProviderPrivacyTests(unittest.TestCase):
    def test_loopback_hosts_are_local(self) -> None:
        for url in (
            "http://127.0.0.1:11434/v1",
            "http://localhost:8080/v1",
            "http://[::1]:8080/v1",
        ):
            with self.subTest(url=url):
                provider = OpenAICompatibleProvider("model", base_url=url)
                self.assertEqual(provider.capabilities.privacy, "local")

    def test_localhost_text_does_not_make_remote_host_local(self) -> None:
        provider = OpenAICompatibleProvider(
            "model", base_url="https://example.com/v1?redirect=localhost"
        )
        self.assertEqual(provider.capabilities.privacy, "remote")


if __name__ == "__main__":
    unittest.main()
