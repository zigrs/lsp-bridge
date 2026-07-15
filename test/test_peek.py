import types
import unittest
from unittest.mock import Mock, patch

from core.handler.find_define_base import find_define_response
from core.handler.peek import PeekFindDefine, PeekFindReferences


class PeekSessionCallbacks(unittest.TestCase):
    def test_peek_definition_is_not_silently_cancelled_on_cursor_change(self):
        self.assertFalse(PeekFindDefine.cancel_on_change)

    def test_regular_definition_callback_remains_compatible(self):
        file_action = types.SimpleNamespace(
            filepath="/tmp/source.py",
            create_external_file_action=Mock(),
        )
        handler = types.SimpleNamespace(
            pos={"line": 0, "character": 0},
            file_action=file_action,
        )
        response = {
            "uri": "file:///tmp/definition.py",
            "range": {
                "start": {"line": 4, "character": 5},
                "end": {"line": 4, "character": 9},
            },
        }

        with patch("core.handler.find_define_base.get_lsp_file_host", return_value=""), \
             patch("core.handler.find_define_base.eval_in_emacs") as eval_in_emacs:
            find_define_response(handler, response, "regular-definition-return")

        eval_in_emacs.assert_called_once_with(
            "regular-definition-return",
            "/tmp/definition.py",
            "",
            {"line": 4, "character": 5},
        )

    def test_definition_success_returns_session_id(self):
        file_action = types.SimpleNamespace(
            filepath="/tmp/source.py",
            create_external_file_action=Mock(),
        )
        handler = types.SimpleNamespace(
            pos={"line": 0, "character": 0},
            session_id=13,
            file_action=file_action,
        )
        response = {
            "uri": "file:///tmp/definition.py",
            "range": {
                "start": {"line": 4, "character": 5},
                "end": {"line": 4, "character": 9},
            },
        }

        with patch("core.handler.find_define_base.get_lsp_file_host", return_value=""), \
             patch("core.handler.find_define_base.eval_in_emacs") as eval_in_emacs:
            PeekFindDefine.process_response(handler, response)

        eval_in_emacs.assert_called_once_with(
            "lsp-bridge-peek-define--return",
            "/tmp/definition.py",
            "",
            {"line": 4, "character": 5},
            13,
        )

    def test_definition_failure_returns_session_id(self):
        handler = types.SimpleNamespace(
            pos={"line": 0, "character": 0},
            session_id=17,
            file_action=types.SimpleNamespace(filepath="/tmp/test.py"),
        )

        with patch("core.handler.find_define_base.eval_in_emacs") as eval_in_emacs:
            PeekFindDefine.process_response(handler, None)

        eval_in_emacs.assert_called_once_with(
            "lsp-bridge-peek--request-failed",
            handler.pos,
            17,
            "definition",
        )

    def test_null_references_returns_session_id(self):
        handler = types.SimpleNamespace(
            pos={"line": 0, "character": 0},
            define_pos={"line": 1, "character": 2},
            session_id=23,
            define_filepath="/tmp/test.py",
        )

        with patch("core.handler.peek.eval_in_emacs") as eval_in_emacs:
            PeekFindReferences.process_response(handler, None)

        eval_in_emacs.assert_called_once_with(
            "lsp-bridge-peek--request-failed",
            handler.pos,
            23,
            "references",
        )

    def test_reference_success_returns_session_id(self):
        handler = types.SimpleNamespace(
            define_pos={"line": 2, "character": 3},
            session_id=29,
            define_filepath="/tmp/definition.py",
        )
        response = [{
            "uri": "file:///tmp/test.py",
            "range": {
                "start": {"line": 2, "character": 3},
                "end": {"line": 2, "character": 7},
            },
        }]

        with patch("core.handler.peek.get_remote_connection_info", return_value=""), \
             patch("core.handler.peek.eval_in_emacs") as eval_in_emacs:
            PeekFindReferences.process_response(handler, response)

        eval_in_emacs.assert_called_once_with(
            "lsp-bridge-peek-references--return",
            "2\n3\n/tmp/test.py\n",
            1,
            29,
        )


if __name__ == "__main__":
    unittest.main()
