from core.handler import Handler
from core.utils import *
import sexpdata


def preserve_json_false(obj):
    """Preserve JSON false when forwarding code actions to Emacs.

    sexpdata serializes Python False as nil, which is ambiguous in Emacs
    lists/plists and loses the value when command arguments are sent back to
    the language server.  Use a non-keyword sentinel so a JSON array starting
    with false is not mistaken for an Emacs plist; core.utils.epc_arg_transformer
    converts it back.
    """
    if obj is False:
        return sexpdata.Symbol("lsp-bridge-json-false")
    if isinstance(obj, dict):
        return {k: preserve_json_false(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [preserve_json_false(item) for item in obj]
    return obj


class CodeAction(Handler):
    name = "code_action"
    method = "textDocument/codeAction"
    cancel_on_change = True
    cancel_on_cursor_change = False
    provider = "code_action_provider"
    provider_message = "Current server not support code action."

    def process_request(self, lsp_server_name, diagnostics, range_start, range_end, action_kind) -> dict:
        self.action_kind = action_kind
        self.lsp_server_name = lsp_server_name

        range = {
            "start": range_start,
            "end": range_end
        }

        if isinstance(action_kind, str):
            context = {
                "diagnostics": diagnostics,
                "only": [action_kind]
            }
        else:
            context = {
                "diagnostics": diagnostics
            }

        return dict(range=range, context=context)

    def process_response(self, response) -> None:
        if response is None:
            response = []

        remote_connection_info = get_remote_connection_info()
        if remote_connection_info != "":
            for item in response:
                if "edit" in item:
                    convert_workspace_edit_path_to_tramped_path(item["edit"], remote_connection_info)
        self.file_action.push_code_actions(preserve_json_false(response), self.lsp_server_name, self.action_kind)
