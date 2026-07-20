import unittest
from unittest.mock import Mock

from core.handler.code_action import CodeAction


class FakeFileAction:
    def __init__(self):
        self.last_change = (1.0, 1.0)


class CodeActionCancellation(unittest.TestCase):
    def make_handler(self):
        file_action = FakeFileAction()
        handler = CodeAction(file_action)
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


if __name__ == "__main__":
    unittest.main()
