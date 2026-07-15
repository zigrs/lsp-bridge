import unittest
from unittest.mock import Mock, patch

from core.handler import Handler
from core.handler.find_implementation import FindImplementation


class FakeFileAction:
    def __init__(self):
        self.last_change = (1.0, 1.0)


class CursorSensitiveHandler(Handler):
    cancel_on_change = True

    def process_response(self, response):
        pass


class FindImplementationCancellation(unittest.TestCase):
    def make_handler(self):
        file_action = FakeFileAction()
        handler = FindImplementation(file_action)
        handler.latest_request_id = 10
        handler.process_response = Mock()
        return file_action, handler

    def test_cursor_change_does_not_discard_response(self):
        file_action, handler = self.make_handler()
        file_action.last_change = (1.0, 2.0)

        handler.handle_response(10, ["result"])

        handler.process_response.assert_called_once_with(["result"])

    def test_file_change_discards_response(self):
        file_action, handler = self.make_handler()
        file_action.last_change = (2.0, 1.0)

        handler.handle_response(10, ["result"])

        handler.process_response.assert_not_called()

    def test_newer_request_discards_response(self):
        _, handler = self.make_handler()
        handler.latest_request_id = 11

        handler.handle_response(10, ["result"])

        handler.process_response.assert_not_called()

    def test_other_handlers_remain_cursor_sensitive(self):
        file_action = FakeFileAction()
        handler = CursorSensitiveHandler(file_action)
        handler.latest_request_id = 10
        handler.process_response = Mock()
        file_action.last_change = (1.0, 2.0)

        handler.handle_response(10, ["result"])

        handler.process_response.assert_not_called()


class FindImplementationResponse(unittest.TestCase):
    def setUp(self):
        self.handler = FindImplementation(FakeFileAction())
        self.handler.pos = {"line": 1, "character": 2}

    def test_none_and_empty_list_report_no_implementation(self):
        with patch("core.handler.find_implementation.message_emacs") as message, \
             patch("core.handler.find_implementation.eval_in_emacs") as eval_in_emacs:
            self.handler.process_response(None)
            self.handler.process_response([])

        self.assertEqual(message.call_count, 2)
        eval_in_emacs.assert_not_called()

    def test_single_location_object_jumps_directly(self):
        location = {
            "uri": "file:///tmp/implementation.go",
            "range": {
                "start": {"line": 3, "character": 4},
                "end": {"line": 3, "character": 8},
            },
        }
        with patch("core.handler.find_implementation.get_lsp_file_host", return_value="host"), \
             patch("core.handler.find_implementation.eval_in_emacs") as eval_in_emacs:
            self.handler.process_response(location)

        eval_in_emacs.assert_called_once_with(
            "lsp-bridge-define--jump",
            "/tmp/implementation.go",
            "host",
            location["range"]["start"],
        )

    def test_multiple_locations_and_location_links_open_result_list(self):
        locations = [
            {
                "uri": "file:///tmp/implementation-a.go",
                "range": {
                    "start": {"line": 3, "character": 4},
                    "end": {"line": 3, "character": 8},
                },
            },
            {
                "targetUri": "file:///tmp/implementation-b.go",
                "targetRange": {
                    "start": {"line": 5, "character": 2},
                    "end": {"line": 5, "character": 6},
                },
            },
        ]
        with patch("core.handler.find_implementation.eval_in_emacs") as eval_in_emacs:
            self.handler.process_response(locations)

        args = eval_in_emacs.call_args.args
        self.assertEqual(args[0], "lsp-bridge-references--popup")
        self.assertIn("/tmp/implementation-a.go", args[1])
        self.assertIn("/tmp/implementation-b.go", args[1])
        self.assertEqual(args[2], 2)
        self.assertEqual(args[3], self.handler.pos)


if __name__ == "__main__":
    unittest.main()
