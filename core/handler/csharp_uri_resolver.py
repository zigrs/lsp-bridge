
from core.handler import Handler
from core.handler.find_define_base import create_decompile_external_file
from core.utils import *


class CSharpUriResolver(Handler):
    name = "csharp_uri_resolver"
    method = "csharp/metadata"
    cancel_on_change = True
    send_document_uri = False

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.external_file_link = ""
        self.start_pos = None

    def process_request(self, uri, start_pos, define_jump_handler, define_jump_args=(),
                        failure_handler="lsp-bridge-find-def-fallback", failure_args=(),
                        failure_position=None) -> dict:
        self.start_pos = start_pos
        self.external_file_link = uri
        self.define_jump_handler = define_jump_handler
        self.define_jump_args = define_jump_args
        self.failure_handler = failure_handler
        self.failure_args = failure_args
        self.failure_position = failure_position or start_pos
        self.cancel_on_change = not define_jump_args
        return dict(textDocument={"uri": uri})

    def process_response(self, response):
        if response is not None:
            external_file = create_decompile_external_file(
                self,
                "lsp-bridge-csharp",
                "csharp-uri-resolver",
                response["source"])

            eval_in_emacs(self.define_jump_handler, external_file, get_lsp_file_host(), self.start_pos, *self.define_jump_args)
        else:
            eval_in_emacs(self.failure_handler, self.failure_position, *self.failure_args)
