"""Lifecycle regressions against the same reducer called by the installed hook."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("state_hook", Path(__file__).with_name("codex_agent_state_hook.py"))
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


def event(name, session="A", turn="1", **fields):
    return dict(hook_event_name=name, session_id=session, turn_id=turn, **fields)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.state = hook.reduce_state(None, event("UserPromptSubmit"))

    def apply(self, name, **fields):
        self.state = hook.reduce_state(self.state, event(name, **fields))

    def test_submit_work_finish(self):
        self.assertEqual(self.state["state"], "RUNNING")
        self.apply("PreToolUse", tool_name="Bash", tool_use_id="run")
        self.apply("PostToolUse", tool_name="Bash", tool_use_id="run")
        self.apply("Stop")
        self.assertEqual(self.state["state"], "DONE")

    def test_async_question_stays_red_during_independent_work_and_stop(self):
        self.apply("PreToolUse", tool_name="functions.request_user_input_async", tool_use_id="q")
        self.apply("PostToolUse", tool_name="functions.request_user_input_async", tool_use_id="q", tool_response={"accepted": True})
        self.apply("PreToolUse", tool_name="Bash", tool_use_id="other")
        self.apply("Stop")
        self.assertEqual((self.state["state"], self.state["wait_kind"]), ("WAITING", "question"))
        self.apply("UserPromptSubmit", turn="2")
        self.assertEqual(self.state["state"], "RUNNING")

    def test_sync_question_resumes_on_actual_tool_completion(self):
        self.apply("PreToolUse", tool_name="request_user_input", tool_use_id="q")
        self.apply("PostToolUse", tool_name="request_user_input", tool_use_id="q")
        self.assertEqual(self.state["state"], "RUNNING")

    def test_permission_only_matching_tool_completion_clears(self):
        self.apply("PermissionRequest", tool_name="Bash", tool_input={"command": "specific"})
        self.apply("PostToolUse", tool_name="Bash", tool_input={"command": "unrelated"})
        self.assertEqual(self.state["state"], "WAITING")
        self.apply("PostToolUse", tool_name="Bash", tool_input={"command": "specific"})
        self.assertEqual(self.state["state"], "RUNNING")

    def test_old_thread_and_old_turn_cannot_override_new_selection(self):
        self.apply("UserPromptSubmit", session="B", turn="2")
        self.apply("Stop", session="A", turn="1")
        self.apply("Stop", session="B", turn="1")
        self.assertEqual((self.state["thread_id"], self.state["state"]), ("B", "RUNNING"))

    def test_subagent_does_not_select(self):
        ignored = hook.reduce_state(self.state, event("UserPromptSubmit", session="child"), main=False)
        self.assertEqual(ignored, self.state)

    def test_interrupt_is_idle_not_success(self):
        self.apply("Interrupt")
        self.assertEqual(self.state["state"], "IDLE")

    def test_metadata_only_atomic_writer_and_no_stdout(self):
        old_dir, old_main = hook.STATE_DIR, hook.is_main
        try:
            with tempfile.TemporaryDirectory() as temp:
                hook.STATE_DIR = Path(temp)
                hook.is_main = lambda e: True
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    hook.observe(event("UserPromptSubmit", prompt="PRIVATE_SENTINEL"))
                    hook.observe(event("PreToolUse", tool_name="request_user_input_async", tool_use_id="q",
                                       tool_input={"question": "PRIVATE_SENTINEL"}))
                self.assertEqual(output.getvalue(), "")
                snapshot = json.loads((Path(temp) / "agent-state.json").read_text())
                self.assertEqual(snapshot["state"], "WAITING")
                self.assertEqual((Path(temp) / "agent-state.json").stat().st_mode & 0o777, 0o600)
                for file in Path(temp).iterdir():
                    self.assertNotIn("PRIVATE_SENTINEL", file.read_text())
        finally:
            hook.STATE_DIR, hook.is_main = old_dir, old_main

    def test_installer_preserves_existing_sound_hooks_and_is_idempotent(self):
        installer_spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("install_agent_hooks.py"))
        installer = importlib.util.module_from_spec(installer_spec)
        installer_spec.loader.exec_module(installer)
        original = {"description": "keep", "hooks": {"PreToolUse": [{"matcher": "question", "hooks": [{"command": "existing-sound"}]}]}}
        merged, added = installer.merged_config(original)
        self.assertEqual(merged["hooks"]["PreToolUse"][0], original["hooks"]["PreToolUse"][0])
        self.assertEqual(len(added), 7)
        second, added_again = installer.merged_config(merged)
        self.assertEqual(second, merged)
        self.assertEqual(added_again, [])


if __name__ == "__main__":
    unittest.main()
