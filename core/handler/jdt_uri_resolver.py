import hashlib
import os
import tempfile
from urllib.parse import urlparse, unquote

from core.handler import Handler
from core.utils import *


class JDTUriResolver(Handler):
    name = "jdt_uri_resolver"
    method = "java/classFileContents"
    cancel_on_change = True
    send_document_uri = False

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.external_file_link = None
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
        return dict(uri=uri)

    def process_response(self, response: str):
        if not response:
            eval_in_emacs(self.failure_handler, self.failure_position, *self.failure_args)
            return

        if isinstance(response, str):
            # Save the analysis content to the file.

            external_file_dir = ''
            decompile_dir_name = 'jdt-uri-resolver'

            try:
                # Value for -data: An absolute path to your data directory. eclipse.jdt.ls stores workspace specific information in it. This should be unique per workspace/project.
                index = self.file_action.single_server_info['command'].index('-data')
                data_dir = pathlib.Path(self.file_action.single_server_info['command'][index + 1])
            except:
                md5 = hashlib.md5()
                md5.update(self.file_action.get_lsp_server_project_path())
                project_hash = md5.hexdigest()
                data_dir = pathlib.Path(os.path.join(tempfile.gettempdir(), "lsp-bridge-jdtls", project_hash))

            external_file_dir = data_dir / decompile_dir_name

            url = urlparse(self.external_file_link)
            path = unquote(url.path).replace(".class", ".java")[1:]
            external_file = external_file_dir / path

            external_file.parent.mkdir(exist_ok=True, parents=True)

            if not external_file.exists():
                with open(external_file, 'w') as f:
                    f.write(response)

            external_file = external_file.as_posix()
            self.file_action.create_external_file_action(external_file, self.external_file_link)
            eval_in_emacs(self.define_jump_handler, external_file, get_lsp_file_host(), self.start_pos, *self.define_jump_args)
