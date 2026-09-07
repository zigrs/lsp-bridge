"""Isolated unit tests for Helm-only definition ordering."""
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from core.handler.find_define import FindDefine, prefer_helm_values_definition


class HelmDefinitionPriority(unittest.TestCase):
    def setUp(self):
        self.root = Path("/tmp/helm project/charts/app")
        self.base = {"uri": (self.root / "values.yaml").as_uri()}
        self.first = {"uri": (self.root / "../../override-values/app-01/values.yaml").as_uri()}
        self.second = {"uri": (self.root / "../../override-values/app-02/values.yaml").as_uri()}
        self.values = {"lintOverlayValuesFile": "../../override-values/app-01/values.yaml"}
        self.server = SimpleNamespace(project_path=str(self.root), server_info={
            "name": "helm-ls", "settings": {"helm-ls": {"valuesFiles": self.values}}})

    def test_selected_environment_wins_without_mutating_response(self):
        response = [self.base, self.second, self.first]
        self.assertIs(prefer_helm_values_definition(response, self.server)[0], self.first)
        self.values["lintOverlayValuesFile"] = "../../override-values/app-02/values.yaml"
        self.assertIs(prefer_helm_values_definition(response, self.server)[0], self.second)
        self.assertIs(response[0], self.base)

    def test_fallback_to_base_and_location_links(self):
        helper = {"uri": (self.root / "templates/_helpers.tpl").as_uri()}
        self.assertIs(prefer_helm_values_definition([helper, self.base], self.server)[0], self.base)
        link = {"targetUri": self.first["uri"]}
        self.assertIs(prefer_helm_values_definition([self.base, link], self.server)[0], link)
        self.assertEqual(prefer_helm_values_definition([helper, {"uri": "jdt://foo"}], self.server),
                         [helper, {"uri": "jdt://foo"}])

    def test_non_helm_and_single_results_are_unchanged(self):
        for response in (None, [], self.base, [self.base]):
            self.assertIs(prefer_helm_values_definition(response, self.server), response)
        response = [self.base, self.first]
        self.assertIs(prefer_helm_values_definition(response, None), response)
        for name in ("gopls", "yaml-language-server", "pyright"):
            self.server.server_info["name"] = name
            self.assertIs(prefer_helm_values_definition(response, self.server), response)

    def test_handler_passes_priority_to_existing_jump_path(self):
        handler = SimpleNamespace(file_action=SimpleNamespace(single_server=self.server))
        with patch("core.handler.find_define.find_define_response") as jump:
            FindDefine.process_response(handler, [self.base, self.first])
            self.assertIs(jump.call_args.args[1][0], self.first)
            self.assertEqual(jump.call_args.args[2], "lsp-bridge-define--jump")
            FindDefine.process_response(handler, None)
            self.assertIsNone(jump.call_args.args[1])


if __name__ == "__main__":
    unittest.main()
