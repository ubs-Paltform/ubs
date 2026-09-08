#!/usr/bin/env python3
"""Dependency-free local MCP stdio server for Universal Build Script.

The server intentionally exposes read-only tools by default. Set
UBS_MCP_ALLOW_BUILD=true and pass confirm=true to permit a non-dry-run build.
All protocol output goes to stdout; diagnostics stay on stderr.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, IO, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from i18n import t


RUNTIME_ROOT = Path(__file__).resolve().parent.parent
BUILD_SCRIPT = RUNTIME_ROOT / "build.sh"
PROTOCOL_VERSION = "2025-11-25"
SERVER_VERSION = (RUNTIME_ROOT / "VERSION").read_text(encoding="utf-8").strip()
SERVER_ROOT = Path(os.environ.get("UBS_MCP_ROOT", Path.cwd())).expanduser().resolve()
ALLOW_BUILD = os.environ.get("UBS_MCP_ALLOW_BUILD", "false") == "true"
READ_ONLY_TIMEOUT_SECONDS = 120
BUILD_TIMEOUT_SECONDS = 3600
MAX_OUTPUT_BYTES = 1024 * 1024
TERMINATION_GRACE_SECONDS = 2
_REQUEST_LOCK = threading.Lock()
_OUTPUT_LOCK = threading.Lock()
_ACTIVE_REQUESTS: set[str] = set()
_ACTIVE_PROCESSES: Dict[str, subprocess.Popen[bytes]] = {}
_CANCELLED_REQUESTS: set[str] = set()


def tool_schema(
    name: str, title: str, description: str, properties: Optional[dict] = None,
) -> dict:
    return {
        "name": name,
        "title": title,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties or {},
            "additionalProperties": False,
        },
    }


PATH_PROPERTY = {
    "type": "string",
    "description": "Path relative to UBS_MCP_ROOT. Defaults to the root itself.",
}
COMMON_PROPERTIES = {
    "path": PATH_PROPERTY,
    "all": {"type": "boolean", "default": False},
    "type": {"type": "string"},
}


def available_tools() -> List[dict]:
    tools = [
        tool_schema("ubs_detect", "Detect build projects", "Detect supported projects without changing files.", {
            "path": PATH_PROPERTY,
        }),
        tool_schema("ubs_audit", "Audit build optimization", "Audit optimization and obfuscation settings.", COMMON_PROPERTIES),
        tool_schema("ubs_plan", "Plan builds", "Return the resolved, read-only build plan.", {
            **COMMON_PROPERTIES,
            "jobs": {"type": "integer", "minimum": 1, "default": 1},
            "flutter_outputs": {"type": "string", "default": "auto"},
        }),
        tool_schema("ubs_graph", "Inspect dependency graph", "Return inferred dependencies and topological build layers.", COMMON_PROPERTIES),
        tool_schema("ubs_update_check", "Check runtime update", "Check for a runtime update without modifying files."),
    ]
    if ALLOW_BUILD:
        tools.append(tool_schema("ubs_build", "Build projects", "Run a dry-run or an explicitly confirmed local build.", {
            **COMMON_PROPERTIES,
            "project": PATH_PROPERTY,
            "jobs": {"type": "integer", "minimum": 1, "default": 1},
            "dry_run": {"type": "boolean", "default": True},
            "confirm": {"type": "boolean", "default": False},
        }))
    return tools


def resolve_scoped_path(value: object = ".") -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError("path must be a non-empty string")
    candidate = Path(value).expanduser()
    resolved = (SERVER_ROOT / candidate).resolve() if not candidate.is_absolute() else candidate.resolve()
    try:
        resolved.relative_to(SERVER_ROOT)
    except ValueError as error:
        raise ValueError(f"path escapes UBS_MCP_ROOT: {value}") from error
    if not resolved.is_dir():
        raise ValueError(f"directory does not exist: {value}")
    return resolved


def common_arguments(arguments: dict) -> tuple[Path, List[str]]:
    path = resolve_scoped_path(arguments.get("path", "."))
    command: List[str] = []
    all_flag = arguments.get("all", False)
    if not isinstance(all_flag, bool):
        raise ValueError("all must be a boolean")
    if all_flag:
        command.append("--all")
    project_type = arguments.get("type")
    if project_type is not None:
        if not isinstance(project_type, str) or not project_type:
            raise ValueError("type must be a non-empty string")
        command.extend(["--type", project_type])
    return path, command


def request_key(identifier: object) -> str:
    return json.dumps(identifier, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def register_request(identifier: object) -> None:
    with _REQUEST_LOCK:
        _ACTIVE_REQUESTS.add(request_key(identifier))


def finish_request(identifier: object) -> None:
    key = request_key(identifier)
    with _REQUEST_LOCK:
        _ACTIVE_REQUESTS.discard(key)
        _ACTIVE_PROCESSES.pop(key, None)
        _CANCELLED_REQUESTS.discard(key)


def terminate_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
        process.wait(timeout=TERMINATION_GRACE_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        if process.poll() is None:
            try:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
            except OSError:
                pass


def cancel_request(identifier: object) -> bool:
    key = request_key(identifier)
    with _REQUEST_LOCK:
        if key not in _ACTIVE_REQUESTS:
            return False
        _CANCELLED_REQUESTS.add(key)
        process = _ACTIVE_PROCESSES.get(key)
    if process is not None:
        terminate_process(process)
    return True


def read_bounded(stream: IO[bytes]) -> tuple[str, bool]:
    chunks: List[bytes] = []
    retained = 0
    truncated = False
    while True:
        chunk = stream.read(65536)
        if not chunk:
            break
        remaining = MAX_OUTPUT_BYTES - retained
        if remaining > 0:
            kept = chunk[:remaining]
            chunks.append(kept)
            retained += len(kept)
        if len(chunk) > remaining:
            truncated = True
    text = b"".join(chunks).decode("utf-8", errors="replace")
    if truncated:
        text += "\n[output truncated]"
    return text, truncated


def run_ubs(
    arguments: List[str], identifier: object = None,
    timeout_seconds: int = READ_ONLY_TIMEOUT_SECONDS,
) -> tuple[int, str, str]:
    process = subprocess.Popen(
        ["bash", str(BUILD_SCRIPT), *arguments], cwd=SERVER_ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=os.name == "posix",
    )
    key = request_key(identifier)
    with _REQUEST_LOCK:
        _ACTIVE_PROCESSES[key] = process
        cancelled = key in _CANCELLED_REQUESTS
    if cancelled:
        terminate_process(process)

    assert process.stdout is not None and process.stderr is not None
    outputs: Dict[str, tuple[str, bool]] = {}
    readers = [
        threading.Thread(target=lambda: outputs.__setitem__("stdout", read_bounded(process.stdout))),
        threading.Thread(target=lambda: outputs.__setitem__("stderr", read_bounded(process.stderr))),
    ]
    for reader in readers:
        reader.start()
    timed_out = False
    try:
        process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_process(process)
    for reader in readers:
        reader.join()
    process.stdout.close()
    process.stderr.close()

    stdout = outputs.get("stdout", ("", False))[0]
    stderr = outputs.get("stderr", ("", False))[0]
    with _REQUEST_LOCK:
        cancelled = key in _CANCELLED_REQUESTS
        _ACTIVE_PROCESSES.pop(key, None)
    if cancelled:
        return 130, stdout, f"{stderr}\nrequest cancelled".strip()
    if timed_out:
        return 124, stdout, f"{stderr}\nrequest timed out after {timeout_seconds} seconds".strip()
    return process.returncode, stdout, stderr


def tool_result(status: int, stdout: str, stderr: str, structured: object = None) -> dict:
    text = stdout.strip()
    if stderr.strip():
        text = f"{text}\n{stderr.strip()}".strip()
    result = {
        "content": [{"type": "text", "text": text or f"exit status {status}"}],
        "isError": status != 0,
    }
    if structured is not None and status == 0:
        result["structuredContent"] = structured
    return result


def call_tool(name: str, arguments: object, identifier: object = None) -> dict:
    if not isinstance(arguments, dict):
        raise ValueError("arguments must be an object")
    if name in {"ubs_detect", "ubs_audit", "ubs_plan", "ubs_graph"}:
        path, common = common_arguments(arguments)
        if name == "ubs_detect" and any(key in arguments for key in ("all", "type")):
            raise ValueError("ubs_detect accepts only path")
        command_name = name.removeprefix("ubs_")
        command = [command_name, "--json", *common]
        if name == "ubs_plan":
            jobs = arguments.get("jobs", 1)
            if not isinstance(jobs, int) or isinstance(jobs, bool) or jobs < 1:
                raise ValueError("jobs must be an integer greater than zero")
            outputs = arguments.get("flutter_outputs", "auto")
            if not isinstance(outputs, str):
                raise ValueError("flutter_outputs must be a string")
            command.extend(["--jobs", str(jobs), "--flutter-outputs", outputs])
        command.append(str(path))
        status, stdout, stderr = run_ubs(command, identifier)
        structured = None
        if status == 0:
            try:
                structured = json.loads(stdout)
            except json.JSONDecodeError:
                status = 1
                stderr = f"{stderr}\nUBS returned invalid JSON".strip()
        return tool_result(status, stdout, stderr, structured)
    if name == "ubs_update_check":
        if arguments:
            raise ValueError("ubs_update_check does not accept arguments")
        status, stdout, stderr = run_ubs(["update", "--check", "--json"], identifier)
        structured = None
        if status == 0 and stdout.strip():
            try:
                structured = json.loads(stdout)
            except json.JSONDecodeError:
                status = 1
                stderr = f"{stderr}\nUBS returned invalid JSON".strip()
        return tool_result(status, stdout, stderr, structured)
    if name == "ubs_build" and ALLOW_BUILD:
        path, common = common_arguments(arguments)
        dry_run = arguments.get("dry_run", True)
        confirm = arguments.get("confirm", False)
        if not isinstance(dry_run, bool) or not isinstance(confirm, bool):
            raise ValueError("dry_run and confirm must be booleans")
        if not dry_run and not confirm:
            raise ValueError("non-dry-run builds require confirm=true")
        jobs = arguments.get("jobs", 1)
        if not isinstance(jobs, int) or isinstance(jobs, bool) or jobs < 1:
            raise ValueError("jobs must be an integer greater than zero")
        command = ["build", *common, "--jobs", str(jobs)]
        project = arguments.get("project")
        if project is not None:
            command.extend(["--project", str(resolve_scoped_path(project))])
        if dry_run:
            command.append("--dry-run")
        command.append(str(path))
        status, stdout, stderr = run_ubs(command, identifier, BUILD_TIMEOUT_SECONDS)
        return tool_result(status, stdout, stderr)
    raise KeyError(name)


def response(identifier: object, result: object = None, error: object = None) -> dict:
    value = {"jsonrpc": "2.0", "id": identifier}
    if error is not None:
        value["error"] = error
    else:
        value["result"] = result
    return value


def handle_message(message: object) -> Optional[dict]:
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return response(None, error={"code": -32600, "message": "Invalid Request"})
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        return response(identifier, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "universal-build", "version": SERVER_VERSION},
            "instructions": "Use read-only detect, audit, plan, and graph tools before requesting builds.",
        })
    if method == "notifications/cancelled":
        params = message.get("params")
        if isinstance(params, dict) and "requestId" in params:
            cancel_request(params["requestId"])
        return None
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return response(identifier, {})
    if method == "tools/list":
        return response(identifier, {"tools": available_tools()})
    if method == "tools/call":
        params = message.get("params")
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            return response(identifier, error={"code": -32602, "message": "Invalid tool parameters"})
        try:
            result = call_tool(params["name"], params.get("arguments", {}), identifier)
            return response(identifier, result)
        except KeyError:
            return response(identifier, error={"code": -32601, "message": "Unknown tool"})
        except (OSError, ValueError, json.JSONDecodeError) as error:
            return response(identifier, {
                "content": [{"type": "text", "text": str(error)}],
                "isError": True,
            })
    if identifier is None:
        return None
    return response(identifier, error={"code": -32601, "message": "Method not found"})


def serve() -> int:
    def emit(result: dict) -> None:
        with _OUTPUT_LOCK:
            sys.stdout.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")
            sys.stdout.flush()

    def run_tool(message: dict) -> None:
        identifier = message.get("id")
        try:
            result = handle_message(message)
        except Exception as error:  # keep the stdio session alive on unexpected tool errors
            print(t("MCP_SERVER_ERROR", error=error), file=sys.stderr)
            result = response(identifier, error={"code": -32603, "message": "Internal error"})
        finally:
            finish_request(identifier)
        if result is not None:
            emit(result)

    with ThreadPoolExecutor(max_workers=1, thread_name_prefix="ubs-mcp") as executor:
        for raw in sys.stdin:
            try:
                message = json.loads(raw)
                if isinstance(message, dict) and message.get("method") == "tools/call":
                    register_request(message.get("id"))
                    executor.submit(run_tool, message)
                    continue
                result = handle_message(message)
            except json.JSONDecodeError as error:
                result = response(None, error={"code": -32700, "message": f"Parse error: {error.msg}"})
            except Exception as error:  # keep the stdio session alive on unexpected tool errors
                print(t("MCP_SERVER_ERROR", error=error), file=sys.stderr)
                result = response(None, error={"code": -32603, "message": "Internal error"})
            if result is not None:
                emit(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(serve())
