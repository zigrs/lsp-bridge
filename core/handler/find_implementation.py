from core.handler import Handler
from core.utils import *
import linecache

REFERENCE_PATH = '\033[95m'
REFERENCE_TEXT = '\033[94m'
REFERENCE_ENDC = '\033[0m'


def _parse_location(location):
    file_uri = location["uri"] if "uri" in location else location["targetUri"]
    location_range = location["range"] if "range" in location else location["targetRange"]
    return uri_to_path(file_uri), location_range


class FindImplementation(Handler):
    name = "find_implementation"
    method = "textDocument/implementation"
    cancel_on_change = True
    cancel_on_cursor_change = False

    def process_request(self, position) -> dict:
        self.pos = position
        return dict(position=position)

    def process_response(self, response) -> None:
        if not response:
            message_emacs("No implementation found")
            return

        locations = response if isinstance(response, list) else [response]
        if len(locations) == 1:
            filepath, location_range = _parse_location(locations[0])
            startpos = location_range["start"]
            eval_in_emacs("lsp-bridge-define--jump", filepath, get_lsp_file_host(), startpos)
        else:
            references_dict = {}
            for location in locations:
                path, location_range = _parse_location(location)
                if path in references_dict:
                    references_dict[path].append(location_range)
                else:
                    references_dict[path] = [location_range]

            references_counter = 0
            references_content = ""
            for i, (path, ranges) in enumerate(references_dict.items()):
                references_content += "".join(["\n", REFERENCE_PATH, path, REFERENCE_ENDC, "\n"])

                for rg in ranges:
                    line = rg["start"]["line"]
                    start_column = rg["start"]["character"]
                    end_column = rg["end"]["character"]
                    line_content = linecache.getline(path, rg["start"]["line"] + 1)

                    references_content += "{}:{}:{}".format(
                        line + 1,
                        start_column,
                        "".join([line_content[:start_column], REFERENCE_TEXT, line_content[start_column:end_column], REFERENCE_ENDC, line_content[end_column:]])
                        )
                    references_counter += 1

            linecache.clearcache()  # clear line cache
            references_content += "\n"

            eval_in_emacs("lsp-bridge-references--popup", references_content, references_counter, self.pos)
