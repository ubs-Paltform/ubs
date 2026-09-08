#!/usr/bin/env python3
"""Protocol and safety tests for the optional stdio MCP server."""

import json
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "scripts/ubs_mcp.py"
SPEC = importlib.util.spec_from_file_location("ubs_mcp_test", SERVER)
assert SPEC and SPEC.loader
mcp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mcp)


class McpServerTests(unittest.TestCase):
    def run_server(self, workspace: Path, messages: list, allow_build: bool = False) -> list:
        environment = {
            **os.environ,
            "UBS_MCP_ROOT": str(workspace),
            "UBS_MCP_ALLOW_BUILD": str(allow_build).lower(),
        }
        payload = "".join(json.dumps(message, separators=(",", ":")) + "\n" for message in messages)
        result = subprocess.run(
            [sys.executable, str(SERVER)], input=payload, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
            cwd=workspace, check=True,
        )
        self.assertEqual(result.stderr, "")
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_initialize_list_detect_and_scope_guard(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary).resolve()
            app = workspace / "app"
            app.mkdir()
            (app / "package.json").write_text(
                '{"name":"demo","scripts":{"build":"node build.js"}}', encoding="utf-8",
            )
            messages = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                    "protocolVersion": "2025-11-25", "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"},
                }},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                    "name": "ubs_detect", "arguments": {"path": "."},
                }},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
                    "name": "ubs_graph", "arguments": {"path": ".", "all": True},
                }},
                {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {
                    "name": "ubs_detect", "arguments": {"path": "../"},
                }},
            ]
            responses = self.run_server(workspace, messages)
            self.assertEqual(len(responses), 5)
            self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-11-25")
            names = [item["name"] for item in responses[1]["result"]["tools"]]
            self.assertEqual(names, sorted(names, key=[
                "ubs_detect", "ubs_audit", "ubs_plan", "ubs_graph", "ubs_update_check"
            ].index))
            self.assertNotIn("ubs_build", names)
            detected = responses[2]["result"]["structuredContent"]
            self.assertEqual(detected[0]["type"], "node")
            self.assertEqual(len(responses[3]["result"]["structuredContent"]["nodes"]), 1)
            self.assertTrue(responses[4]["result"]["isError"])

    def test_build_tool_is_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            responses = self.run_server(
                Path(temporary),
                [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}],
                allow_build=True,
            )
            names = [item["name"] for item in responses[0]["result"]["tools"]]
            self.assertIn("ubs_build", names)

    def test_run_ubs_times_out_and_bounds_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary).resolve()
            script = workspace / "fixture.sh"
            script.write_text(
                '#!/usr/bin/env bash\n'
                'if [ "${1:-}" = timeout ]; then sleep 5; fi\n'
                'python3 -c "print(\'x\' * 256)"\n',
                encoding="utf-8",
            )
            with mock.patch.object(mcp, "BUILD_SCRIPT", script), \
                    mock.patch.object(mcp, "SERVER_ROOT", workspace), \
                    mock.patch.object(mcp, "MAX_OUTPUT_BYTES", 32):
                status, stdout, _ = mcp.run_ubs([])
                self.assertEqual(status, 0)
                self.assertLessEqual(len(stdout), 64)
                self.assertIn("[output truncated]", stdout)
                started = time.monotonic()
                status, _, stderr = mcp.run_ubs(["timeout"], timeout_seconds=0.05)
                self.assertEqual(status, 124)
                self.assertIn("timed out", stderr)
                self.assertLess(time.monotonic() - started, 2)

    def test_cancel_notification_terminates_active_tool(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary).resolve()
            fake_bin = workspace / "bin"
            fake_bin.mkdir()
            fake_bash = fake_bin / "bash"
            fake_bash.write_text("#!/bin/sh\nsleep 10\n", encoding="utf-8")
            fake_bash.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "UBS_MCP_ROOT": str(workspace),
            }
            process = subprocess.Popen(
                [sys.executable, str(SERVER)], cwd=workspace, env=environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True,
            )
            assert process.stdin is not None
            process.stdin.write(json.dumps({
                "jsonrpc": "2.0", "id": 7, "method": "tools/call",
                "params": {"name": "ubs_detect", "arguments": {"path": "."}},
            }) + "\n")
            process.stdin.flush()
            process.stdin.write(json.dumps({
                "jsonrpc": "2.0", "method": "notifications/cancelled",
                "params": {"requestId": 7, "reason": "test"},
            }) + "\n")
            process.stdin.close()
            process.wait(timeout=3)
            assert process.stdout is not None and process.stderr is not None
            responses = [json.loads(line) for line in process.stdout.read().splitlines()]
            self.assertEqual(process.stderr.read(), "")
            process.stdout.close()
            process.stderr.close()
            self.assertEqual(len(responses), 1)
            self.assertTrue(responses[0]["result"]["isError"])
            self.assertIn("request cancelled", responses[0]["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
