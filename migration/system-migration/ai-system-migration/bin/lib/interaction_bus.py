#!/usr/bin/env python3
"""Non-blocking interaction queue for AI System Migration Skill."""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Dict, Iterable, Optional

SENSITIVE_KEYS = ("password", "passwd", "pwd", "token", "api_key", "secret")


def now_ms() -> int:
    return int(time.time() * 1000)


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if any(s in k.lower() for s in SENSITIVE_KEYS):
                out[k] = "******" if v else ""
            else:
                out[k] = redact(v)
        return out
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


class InteractionBus:
    """Append-only interaction task queue.

    A task can block a specific stage without stopping the whole migration.
    """

    def __init__(self, workspace: str | Path):
        self.workspace = Path(workspace)
        self.state_dir = self.workspace / "state"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.tasks_file = self.state_dir / "interaction_tasks.jsonl"
        self.answers_file = self.state_dir / "interaction_answers.json"

    def add_task(self, task: Dict[str, Any]) -> Dict[str, Any]:
        task = dict(task)
        task.setdefault("created_at_ms", now_ms())
        task.setdefault("status", "pending")
        task.setdefault("blocking_scope", "none")
        task.setdefault("expires_policy", "manual")
        with self.tasks_file.open("a", encoding="utf-8") as f:
            f.write(json.dumps(redact(task), ensure_ascii=False) + "\n")
        return task

    def read_answers(self) -> Dict[str, Any]:
        if not self.answers_file.exists():
            return {}
        try:
            return json.loads(self.answers_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}

    def answer_for(self, task_id: str) -> Optional[Any]:
        return self.read_answers().get(task_id)

    def write_answer(self, task_id: str, answer: Any) -> None:
        data = self.read_answers()
        data[task_id] = answer
        self.answers_file.write_text(json.dumps(redact(data), ensure_ascii=False, indent=2), encoding="utf-8")

    def pending_tasks(self) -> Iterable[Dict[str, Any]]:
        if not self.tasks_file.exists():
            return []
        tasks = []
        with self.tasks_file.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    tasks.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        answers = self.read_answers()
        return [t for t in tasks if t.get("task_id") not in answers]
