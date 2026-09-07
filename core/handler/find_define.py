from core.handler import Handler
from core.handler.find_define_base import find_define_response
from core.utils import *
from typing import Union
import os


def prefer_helm_values_definition(response, server):
    """Prefer Helm's active overlay, then base values, among returned targets."""
    if not isinstance(response, list) or len(response) < 2 or server is None:
        return response
    if server.server_info.get("name") != "helm-ls":
        return response
    values = server.server_info.get("settings", {}).get("helm-ls", {}).get("valuesFiles", {})
    paths = [values.get("lintOverlayValuesFile", "values.lint.yaml"),
             values.get("mainValuesFile", "values.yaml")]
    preferred = [os.path.realpath(os.path.join(server.project_path, path))
                 for path in paths if isinstance(path, str) and path]

    def rank(location):
        uri = location.get("uri", location.get("targetUri", ""))
        if not uri.startswith("file:"):
            return len(preferred)
        path = os.path.realpath(uri_to_path(uri))
        return preferred.index(path) if path in preferred else len(preferred)

    return sorted(response, key=rank)


class FindDefine(Handler):
    name = "find_define"
    method = "textDocument/definition"
    cancel_on_change = True

    def process_request(self, position) -> dict:
        self.pos = position
        return dict(position=position)

    def process_response(self, response: Union[dict, list]) -> None:
        response = prefer_helm_values_definition(
            response, getattr(self.file_action, "single_server", None))
        find_define_response(self, response, "lsp-bridge-define--jump")
