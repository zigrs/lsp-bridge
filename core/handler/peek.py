from core.handler import Handler
from core.handler.find_define_base import find_define_response
from core.utils import *
from typing import Union
import linecache


class PeekFindDefine(Handler):
    name = "peek_find_definition"
    method = "textDocument/definition"
    # Peek has its own session id, so responses can be rejected explicitly in
    # Emacs without leaving a silently discarded request pending forever.
    cancel_on_change = False

    def process_request(self, position, session_id) -> dict:
        self.pos = position
        self.session_id = session_id
        return dict(position=position)

    def process_response(self, response: Union[dict, list]) -> None:
        find_define_response(
            self,
            response,
            "lsp-bridge-peek-define--return",
            (self.session_id,),
            "lsp-bridge-peek--request-failed",
            (self.session_id, "definition"),
        )

class PeekFindReferences(Handler):
    name = "peek_find_references"
    method = "textDocument/references"

    def process_request(self, position, define_position, session_id, define_filepath) -> dict:
        self.pos = position
        self.define_pos = define_position
        self.session_id = session_id
        self.define_filepath = define_filepath

        return dict(
            position=position,
            context=dict(includeDeclaration=False)
        )

    def process_response(self, response) -> None:
        if response is None:
            eval_in_emacs("lsp-bridge-peek--request-failed", self.pos, self.session_id, "references")
        else:
            response = remove_duplicate_references(response)
            remote_connection_info = get_remote_connection_info()

            references_dict = {}
            for uri_info in response:
                path = remote_connection_info + uri_to_path(uri_info["uri"])
                if path in references_dict:
                    references_dict[path].append(uri_info["range"])
                else:
                    references_dict[path] = [uri_info["range"]]

            references_counter = 0
            references_content = ""
            for i, (path, ranges) in enumerate(references_dict.items()):
                for rg in ranges:
                    line = rg["start"]["line"]
                    start_column = rg["start"]["character"]

                    # Don't return reference postion if it same as d
                    if (path == self.define_filepath
                            and line == self.define_pos["line"]
                            and start_column == self.define_pos["character"]):
                        continue

                    references_content += "{}\n{}\n{}\n".format(
                        line,
                        start_column,
                        "".join([path])
                        )
                    references_counter += 1

            linecache.clearcache()  # clear line cache

            eval_in_emacs("lsp-bridge-peek-references--return", references_content, references_counter, self.session_id)
