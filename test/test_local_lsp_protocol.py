import os
import queue
import tempfile
import threading
import types
import unittest
from unittest.mock import Mock, patch

from core.fileaction import FileAction
from core.handler.completion import Completion
from core.handler.diagnostic import Diagnostic
from core.lspserver import LspServer, MultiFileHandler, WORKSPACE_DIAGNOSTICS, WORKSPACE_DIAGNOSTIC_VERSIONS


class DummySender:
    def __init__(self):
        self.notifications = []
        self.requests = []
        self.responses = []
        self.initialized = threading.Event()

    def send_notification(self, method, params, **kwargs):
        self.notifications.append((method, params, kwargs))

    def send_request(self, method, params, request_id, **kwargs):
        self.requests.append((method, params, request_id, kwargs))

    def send_response(self, request_id, result, **kwargs):
        self.responses.append((request_id, result, kwargs))


class DummyTimer:
    def __init__(self, interval, callback):
        self.interval = interval
        self.callback = callback
        self.started = False
        self.cancelled = False

    def start(self):
        self.started = True

    def is_alive(self):
        return self.started and not self.cancelled

    def cancel(self):
        self.cancelled = True


class DummyObserver:
    def __init__(self):
        self.scheduled = []
        self.unscheduled = []

    def schedule(self, handler, target_dir, recursive=False):
        watch = (os.path.abspath(target_dir), recursive, len(self.scheduled))
        self.scheduled.append((os.path.abspath(target_dir), recursive))
        return watch

    def unschedule(self, watch):
        self.unscheduled.append(watch)


def make_diagnostic(line, message):
    return {
        "range": {
            "start": {"line": line, "character": 0},
            "end": {"line": line, "character": 1},
        },
        "message": message,
        "severity": 1,
    }


class LocalLspProtocolTest(unittest.TestCase):
    def setUp(self):
        WORKSPACE_DIAGNOSTICS.clear()
        WORKSPACE_DIAGNOSTIC_VERSIONS.clear()

    def make_server(self, project_path):
        server = object.__new__(LspServer)
        server.project_path = project_path
        server.root_path = project_path
        server.project_name = os.path.basename(project_path.rstrip(os.sep)) or os.path.basename(project_path)
        server.server_info = {
            "name": "pyright",
            "initializationOptions": {"foo": "bar"},
        }
        server.server_name = "test-project#pyright"
        server.initialize_id = 42
        server.enable_diagnostics = True
        server.status = "starting"
        server.sender = DummySender()
        server.request_dict = {}
        server.text_document_sync = 2
        server.open_close_provider = True
        server.save_file_provider = True
        server.save_include_text = False
        server.range_format_provider = False
        server.worksplace_folder = None
        server.workspace_watch_lock = threading.Lock()
        server.workspace_watch_timer = None
        server.workspace_watch_pending = {}
        server.workspace_watch_flush_delay = 0.2
        server.project_file_reload_lock = threading.Lock()
        server.project_file_reload_timer = None
        server.project_file_reload_delay = 0.5
        server.workspace_file_watcher = None
        server.workspace_file_watch_handler = None
        server.files = {}
        return server

    def make_file_action(self, project_path, filepath):
        action = object.__new__(FileAction)
        action.filepath = filepath
        action.diagnostics_versions = {}
        action.diagnostics = {}
        action.diagnostics_ticker = {}
        action.enable_push_diagnostics = False
        action.push_diagnostic_idle = 0
        action.single_server = types.SimpleNamespace(project_path=project_path)
        action.multi_servers = None
        return action

    def test_send_did_save_uses_top_level_text(self):
        server = self.make_server("/tmp/project")
        server.save_file_provider = True
        server.save_include_text = True

        with patch("core.lspserver.get_buffer_content", return_value="print('ok')"):
            server.send_did_save_notification("/tmp/project/app.py", "app.py")

        method, params, _ = server.sender.notifications[0]
        self.assertEqual(method, "textDocument/didSave")
        self.assertEqual(params["textDocument"]["uri"], "file:///tmp/project/app.py")
        self.assertEqual(params["text"], "print('ok')")
        self.assertNotIn("text", params["textDocument"])

    def test_send_did_rename_files_uses_standard_method(self):
        server = self.make_server("/tmp/project")
        server.send_did_rename_files_notification("/tmp/project/a.py", "/tmp/project/b.py")

        method, params, _ = server.sender.notifications[0]
        self.assertEqual(method, "workspace/didRenameFiles")
        self.assertEqual(params["files"][0]["oldUri"], "file:///tmp/project/a.py")
        self.assertEqual(params["files"][0]["newUri"], "file:///tmp/project/b.py")

    def test_sync_status_to_emacs_updates_attached_files(self):
        server = self.make_server("/tmp/project")
        server.files["/tmp/project/a.py"] = types.SimpleNamespace(filepath="/tmp/project/a.py")

        with patch("core.lspserver.eval_in_emacs") as eval_in_emacs:
            server.sync_status_to_emacs("initializing")

        self.assertEqual(server.status, "initializing")
        eval_in_emacs.assert_called_once_with(
            "lsp-bridge-set-server-status",
            "/tmp/project/a.py",
            "",
            "pyright",
            "initializing",
        )

    def test_process_monitor_reports_exited_server(self):
        server = self.make_server("/tmp/project")
        server.files["/tmp/project/a.py"] = types.SimpleNamespace(filepath="/tmp/project/a.py")
        server.message_queue = queue.Queue()
        server.lsp_subprocess = types.SimpleNamespace(wait=lambda: 7)
        server.stop_workspace_watch_files = Mock()

        with patch("core.lspserver.eval_in_emacs") as eval_in_emacs, \
             patch("core.lspserver.message_emacs") as message_emacs:
            server.monitor_lsp_process()

        self.assertEqual(server.status, "exited")
        eval_in_emacs.assert_called_once_with(
            "lsp-bridge-set-server-status",
            "/tmp/project/a.py",
            "",
            "pyright",
            "exited",
        )
        message_emacs.assert_called_once_with("LSP server 'pyright' exited with code 7")
        self.assertEqual(server.message_queue.get_nowait(), {
            "name": "server_process_exit",
            "content": "test-project#pyright",
        })

    def test_record_request_id_tracks_handler(self):
        server = self.make_server("/tmp/project")
        handler = types.SimpleNamespace(method="textDocument/completion")

        server.record_request_id(99, handler)

        self.assertEqual(server.request_dict[99], handler)

    def test_rename_file_notifies_all_multi_servers(self):
        rename_calls = []

        class RenameServer:
            def __init__(self, name):
                self.name = name

            def send_did_rename_files_notification(self, old_filepath, new_filepath):
                rename_calls.append((self.name, old_filepath, new_filepath))

        action = object.__new__(FileAction)
        action.single_server = None
        action.multi_servers = {
            "pyright": RenameServer("pyright"),
            "ruff": RenameServer("ruff"),
        }

        FileAction.rename_file(action, "/tmp/project/a.py", "/tmp/project/b.py")

        self.assertEqual(rename_calls, [
            ("pyright", "/tmp/project/a.py", "/tmp/project/b.py"),
            ("ruff", "/tmp/project/a.py", "/tmp/project/b.py"),
        ])

    def test_initialize_request_includes_workspace_folders(self):
        project_path = "/tmp/project"
        workspace_path = "/tmp/workspaces/shared-java"
        server = self.make_server(project_path)

        with patch("core.lspserver.get_emacs_func_result", return_value=workspace_path):
            server.send_initialize_request()

        method, params, request_id, kwargs = server.sender.requests[0]
        self.assertEqual(method, "initialize")
        self.assertEqual(request_id, 42)
        self.assertTrue(kwargs["init"])
        self.assertEqual(params["initializationOptions"], {"foo": "bar"})
        self.assertEqual(params["workspaceFolders"], [{
            "name": "shared-java",
            "uri": "file:///tmp/workspaces/shared-java",
        }])

    def test_force_text_document_sync_override_wins_over_server_capability(self):
        server = self.make_server("/tmp/project")
        server.server_info["forceTextDocumentSync"] = 1

        server.save_attribute_from_message({
            "result": {
                "capabilities": {
                    "textDocumentSync": {
                        "change": 2,
                    }
                }
            }
        })

        self.assertEqual(server.text_document_sync, 1)

    def test_sync_options_disable_open_close_and_save(self):
        server = self.make_server("/tmp/project")

        server.save_attribute_from_message({
            "result": {
                "capabilities": {
                    "textDocumentSync": {
                        "openClose": False,
                        "change": 0,
                        "save": False,
                    }
                }
            }
        })

        self.assertFalse(server.open_close_provider)
        self.assertFalse(server.save_file_provider)
        self.assertEqual(server.text_document_sync, 0)

        action = types.SimpleNamespace(
            filepath="/tmp/project/a.py",
            external_file_link=None,
            read_file=lambda: "print('ok')",
        )
        server.send_did_open_notification(action)
        server.send_did_close_notification("/tmp/project/a.py")
        server.send_did_save_notification("/tmp/project/a.py", "a.py")

        self.assertEqual(server.sender.notifications, [])

    def test_error_response_clears_pending_request(self):
        server = self.make_server("/tmp/project")
        server.request_dict[99] = types.SimpleNamespace(method="textDocument/completion")

        with patch("core.lspserver.message_emacs"):
            server.handle_recv_message({
                "jsonrpc": "2.0",
                "id": 99,
                "error": {
                    "code": -32801,
                    "message": "Content modified",
                },
            })

        self.assertNotIn(99, server.request_dict)

    def test_workspace_folders_request_gets_response(self):
        server = self.make_server("/tmp/project")

        with patch("core.lspserver.get_emacs_func_result", return_value="/tmp/workspaces/shared"):
            server.send_initialize_request()
        server.handle_recv_message({
            "jsonrpc": "2.0",
            "id": 13,
            "method": "workspace/workspaceFolders",
            "params": {},
        })

        self.assertEqual(server.sender.responses[-1], (
            13,
            [{
                "name": "shared",
                "uri": "file:///tmp/workspaces/shared",
            }],
            {},
        ))

    def test_show_document_request_opens_local_file_and_responds(self):
        server = self.make_server("/tmp/project")

        with patch("core.lspserver.eval_in_emacs") as eval_in_emacs:
            server.handle_recv_message({
                "jsonrpc": "2.0",
                "id": 17,
                "method": "window/showDocument",
                "params": {
                    "uri": "file:///tmp/project/main.go",
                },
            })

        eval_in_emacs.assert_called_once_with("find-file", "/tmp/project/main.go")
        self.assertEqual(server.sender.responses[-1], (17, {"success": True}, {}))

    def test_completion_response_survives_cursor_changes_when_buffer_version_matches(self):
        action = types.SimpleNamespace(
            last_change=(1.0, 1.0),
            version=3,
            completion_match_mode="prefix",
            completion_case_mode="ignore",
            completion_block_kind_list=False,
            enable_auto_import=False,
            display_label_max_length=80,
            completion_items={},
            completion_items_limit=20,
            filepath="/tmp/project/main.ex",
            get_match_lsp_servers=lambda method: [server],
            get_lsp_server_names=lambda: ["expert"],
        )
        server = types.SimpleNamespace(
            server_info={"name": "expert"},
            completion_trigger_characters=[],
        )
        handler = Completion(action)
        handler.latest_request_id = 1
        handler.method_server = server
        handler.method_server_name = "expert"
        handler.position = {"line": 0, "character": 3}
        handler.prefix = "foo"
        handler.version = 3

        action.last_change = (1.0, 2.0)

        with patch("core.handler.completion.eval_in_emacs") as eval_in_emacs:
            handler.handle_response(1, [{"label": "foobar", "kind": 3}])

        eval_in_emacs.assert_called_once()

    def test_completion_response_still_drops_after_file_version_changes(self):
        action = types.SimpleNamespace(
            last_change=(1.0, 1.0),
            version=4,
            completion_match_mode="prefix",
            completion_case_mode="ignore",
            completion_block_kind_list=False,
            enable_auto_import=False,
            display_label_max_length=80,
            completion_items={},
            completion_items_limit=20,
            filepath="/tmp/project/main.ex",
            get_match_lsp_servers=lambda method: [server],
            get_lsp_server_names=lambda: ["expert"],
        )
        server = types.SimpleNamespace(
            server_info={"name": "expert"},
            completion_trigger_characters=[],
        )
        handler = Completion(action)
        handler.latest_request_id = 1
        handler.method_server = server
        handler.method_server_name = "expert"
        handler.position = {"line": 0, "character": 3}
        handler.prefix = "foo"
        handler.version = 3

        with patch("core.handler.completion.eval_in_emacs") as eval_in_emacs:
            handler.handle_response(1, [{"label": "foobar", "kind": 3}])

        eval_in_emacs.assert_not_called()

    def test_completion_workspace_symbol_respects_switch_and_min_length(self):
        action = object.__new__(FileAction)
        action.enable_completion_workspace_symbol = False
        action.completion_workspace_symbol_min_length = 3
        server = types.SimpleNamespace(workspace_symbol_provider=True)

        self.assertFalse(action.should_send_completion_workspace_symbol(server, "abc"))

        action.enable_completion_workspace_symbol = True
        self.assertFalse(action.should_send_completion_workspace_symbol(server, "ab"))
        self.assertTrue(action.should_send_completion_workspace_symbol(server, "abc"))

        server.workspace_symbol_provider = False
        self.assertFalse(action.should_send_completion_workspace_symbol(server, "abc"))

    def test_send_initialize_response_marks_server_ready(self):
        server = self.make_server("/tmp/project")
        server.files["/tmp/project/a.py"] = types.SimpleNamespace(filepath="/tmp/project/a.py")

        with patch("core.lspserver.eval_in_emacs") as eval_in_emacs:
            server.send_initialize_response({})

        self.assertTrue(server.sender.initialized.is_set())
        self.assertEqual(server.status, "ready")
        self.assertEqual(server.sender.notifications[:2], [
            ("initialized", {}, {"init": True}),
            ("workspace/didChangeConfiguration", {"settings": {}}, {"init": True}),
        ])
        self.assertEqual(eval_in_emacs.call_args_list[-1].args, (
            "lsp-bridge-set-server-status",
            "/tmp/project/a.py",
            "",
            "pyright",
            "ready",
        ))

    def test_attach_existing_ready_server_marks_new_file_ready_without_reinitializing(self):
        server = self.make_server("/tmp/project")
        server.status = "ready"
        server.sender.initialized.set()
        server.files["/tmp/project/existing.py"] = types.SimpleNamespace(filepath="/tmp/project/existing.py")
        action = types.SimpleNamespace(filepath="/tmp/project/a.py")

        with patch("core.lspserver.eval_in_emacs") as eval_in_emacs, \
             patch.object(server, "send_initialize_request") as send_initialize_request, \
             patch.object(server, "send_did_open_notification") as send_did_open_notification:
            server.attach(action)

        send_initialize_request.assert_not_called()
        send_did_open_notification.assert_called_once_with(action)
        self.assertEqual(eval_in_emacs.call_args_list[0].args, (
            "lsp-bridge-set-server-status",
            "/tmp/project/a.py",
            "",
            "pyright",
            "ready",
        ))

    def test_unknown_response_id_is_ignored(self):
        server = self.make_server("/tmp/project")
        workspace_messages = []
        server.handle_workspace_message = workspace_messages.append

        server.handle_id_message({
            "id": 999,
            "result": None,
        })

        self.assertEqual(workspace_messages, [])

    def test_pull_diagnostic_response_survives_cursor_changes_and_uses_request_document_version(self):
        action = types.SimpleNamespace(
            last_change=(1.0, 1.0),
            version=5,
            record_diagnostics=Mock(),
        )
        handler = Diagnostic(action)
        handler.latest_request_id = 1
        handler.server_info = {"name": "expert"}

        params = handler.process_request("expert")
        action.last_change = (1.0, 2.0)
        handler.handle_response(1, {"items": [make_diagnostic(1, "error")]})

        self.assertEqual(params["identifier"], "expert")
        action.record_diagnostics.assert_called_once_with(
            [make_diagnostic(1, "error")],
            "expert",
            4,
        )

    def test_pull_diagnostic_response_is_dropped_after_file_version_changes(self):
        action = types.SimpleNamespace(
            last_change=(1.0, 1.0),
            version=5,
            record_diagnostics=Mock(),
        )
        handler = Diagnostic(action)
        handler.latest_request_id = 1
        handler.server_info = {"name": "expert"}

        handler.process_request("expert")
        action.version = 6
        action.last_change = (2.0, 1.0)
        handler.handle_response(1, {"items": [make_diagnostic(1, "error")]})

        action.record_diagnostics.assert_not_called()

    def test_parse_workspace_watch_files_resolves_relative_patterns(self):
        with tempfile.TemporaryDirectory() as project_path:
            os.makedirs(os.path.join(project_path, "src"), exist_ok=True)
            server = self.make_server(project_path)
            params = {
                "registrations": [{
                    "method": "workspace/didChangeWatchedFiles",
                    "registerOptions": {
                        "watchers": [
                            {"globPattern": "**/*.json"},
                            {"globPattern": "*.toml"},
                            {"globPattern": "src/{a,b}.py"},
                        ]
                    }
                }]
            }

            watches = server.parse_workspace_watch_files(params)
            patterns = {(os.path.relpath(w["pattern"], project_path), w["recursive"]) for w in watches}

            self.assertIn(("*.json", True), patterns)
            self.assertIn(("*.toml", False), patterns)
            self.assertIn((os.path.join("src", "a.py"), False), patterns)
            self.assertIn((os.path.join("src", "b.py"), False), patterns)

    def test_workspace_diagnostic_list_includes_open_file_diagnostics(self):
        with tempfile.TemporaryDirectory() as project_path:
            filepath = os.path.join(project_path, "main.py")
            action = self.make_file_action(project_path, filepath)
            diagnostics = [make_diagnostic(1, "current file error")]

            FileAction.record_diagnostics(action, diagnostics, "pyright", version=1)

            with patch("core.fileaction.eval_in_emacs") as eval_in_emacs:
                FileAction.workspace_list_diagnostics(action, None)

            listed = eval_in_emacs.call_args[0][1]
            self.assertEqual(len(listed), 1)
            self.assertEqual(listed[0]["filepath"], filepath)
            self.assertEqual(listed[0]["server-name"], "pyright")
            self.assertEqual(listed[0]["message"], "current file error")

    def test_workspace_diagnostics_drop_outdated_versions_for_unopened_files(self):
        server = self.make_server("/tmp/project")

        server.handle_publish_diagnostics({
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": "file:///tmp/project/main.py",
                "version": 2,
                "diagnostics": [make_diagnostic(2, "new error")],
            },
        })
        server.handle_publish_diagnostics({
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": "file:///tmp/project/main.py",
                "version": 1,
                "diagnostics": [make_diagnostic(1, "old error")],
            },
        })

        self.assertEqual(
            WORKSPACE_DIAGNOSTICS["/tmp/project"]["/tmp/project/main.py"]["pyright"][0]["message"],
            "new error",
        )

    def test_workspace_watch_events_are_batched(self):
        server = self.make_server("/tmp/project")

        with patch("core.lspserver.threading.Timer", DummyTimer):
            server.queue_workspace_did_change_watched_files("/tmp/project/a.json", 2)
            server.queue_workspace_did_change_watched_files("/tmp/project/a.json", 3)
            server.queue_workspace_did_change_watched_files("/tmp/project/b.json", 1)

            self.assertEqual(len(server.sender.notifications), 0)
            server.flush_workspace_did_change_watched_files()

        method, params, _ = server.sender.notifications[0]
        self.assertEqual(method, "workspace/didChangeWatchedFiles")
        self.assertEqual(params["changes"], [
            {"uri": "file:///tmp/project/a.json", "type": 3},
            {"uri": "file:///tmp/project/b.json", "type": 1},
        ])

    def test_project_file_change_triggers_rust_reload_workspace(self):
        server = self.make_server("/tmp/project")
        server.server_info["name"] = "rust-analyzer"
        server.server_info["projectFiles"] = ["Cargo.toml"]
        server.sender.initialized.set()

        with patch("core.lspserver.threading.Timer", DummyTimer), \
             patch("core.lspserver.generate_request_id", return_value=77):
            server.handle_project_file_change("/tmp/project/Cargo.toml", 2)
            server.flush_project_file_reload()

        self.assertEqual(server.sender.requests, [
            ("rust-analyzer/reloadWorkspace", None, 77, {}),
        ])

    def test_monitor_workspace_files_upgrades_existing_watch_to_recursive(self):
        server = self.make_server("/tmp/project")
        observer = DummyObserver()
        server.workspace_file_watcher = observer
        server.workspace_file_watch_handler = MultiFileHandler(server)
        server.start_workspace_watch_files = lambda: None

        server.monitor_workspace_files([{
            "pattern": "/tmp/project/*.toml",
            "recursive": False,
        }])
        server.monitor_workspace_files([{
            "pattern": "/tmp/project/*.json",
            "recursive": True,
        }])

        self.assertEqual(observer.scheduled, [
            ("/tmp/project", False),
            ("/tmp/project", True),
        ])
        self.assertEqual(len(observer.unscheduled), 1)


if __name__ == "__main__":
    unittest.main()
