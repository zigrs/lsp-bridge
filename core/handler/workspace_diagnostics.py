from core.handler import Handler
from core.utils import *
from core.lspserver import record_workspace_diagnostics

class WorkspaceDiagnostics(Handler):
    name = "workspace_diagnostics"
    method = "workspace/diagnostic"
    cancel_on_change = False
    send_document_uri = False

    def process_request(self) -> dict:
        # Request full workspace diagnostics; servers may stream partials.
        return dict(previousResultIds=[])

    def process_response(self, response: dict) -> None:
        # LSP 3.17: WorkspaceDiagnosticReport has 'items': [{uri, version? , items? or resultId}]
        if not response:
            return
        items = response.get("items", [])
        server_name = self.server_info["name"] if self.server_info else ""
        project_path = self.file_action.single_server.project_path if self.file_action and self.file_action.single_server else None
        if project_path is None and self.file_action and self.file_action.multi_servers:
            # Pick the first server's project path
            for s in self.file_action.multi_servers.values():
                project_path = getattr(s, 'project_path', None)
                if project_path:
                    break
        if project_path is None:
            return

        for it in items:
            uri = it.get("uri")
            if not uri:
                continue
            filepath = uri_to_path(uri)
            diags = it.get("items", [])
            record_workspace_diagnostics(project_path, filepath, diags, server_name)
