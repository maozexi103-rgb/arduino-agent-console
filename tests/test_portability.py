import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

class PortabilityTests(unittest.TestCase):
    def test_hook_preview_install_and_owned_uninstall(self):
        script=ROOT/'tools/install_agent_hooks.py'
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder);path=folder/'hooks.json'
            original={'description':'keep','hooks':{'PreToolUse':[{'hooks':[{'type':'command','command':'original-sound'}]}]}}
            path.write_text(json.dumps(original));before=path.read_bytes()
            def run(*args):
                return subprocess.run([sys.executable,str(script),'--config-dir',str(folder),*args],check=True,capture_output=True,text=True)
            run();self.assertEqual(path.read_bytes(),before)
            run('--install');installed=json.loads(path.read_text())
            self.assertEqual(installed['hooks']['PreToolUse'][0],original['hooks']['PreToolUse'][0])
            self.assertEqual(len(list(folder.glob('hooks.before-*.json'))),1)
            first_backup=next(folder.glob('hooks.before-*.json'))
            backup_bytes=first_backup.read_bytes()
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
            again=path.read_bytes();run('--install');self.assertEqual(path.read_bytes(),again)
            run('--uninstall');removed=json.loads(path.read_text())
            self.assertEqual(first_backup.read_bytes(),backup_bytes)
            self.assertEqual(len(list(folder.glob('hooks.before-*.json'))),2)
            self.assertEqual(removed['hooks']['PreToolUse'],original['hooks']['PreToolUse'])
            self.assertEqual(removed['description'],'keep')
            self.assertTrue(all(not groups for key,groups in removed['hooks'].items() if key!='PreToolUse'))

    def test_read_only_metadata_filter_and_schema_failure(self):
        hook=load('public_hook',ROOT/'tools/codex_agent_state_hook.py')
        with tempfile.TemporaryDirectory() as folder:
            hook.CODEX_HOME=Path(folder)
            # Ignore non-numeric filenames rather than failing on int conversion.
            (Path(folder)/'state_notes.sqlite').write_text('not a database')
            path=Path(folder)/'state_5.sqlite'
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE threads (id TEXT, source TEXT, thread_source TEXT, agent_path TEXT)')
                db.executemany('INSERT INTO threads VALUES (?,?,?,?)',[('main','desktop','local','/root'),('child','desktop','subagent','/root/child')])
            before=path.read_bytes()
            self.assertTrue(hook.is_main({'session_id':'main'}))
            self.assertFalse(hook.is_main({'session_id':'child'}))
            self.assertFalse(hook.is_main({'session_id':'main','agent_id':'child'}))
            self.assertFalse(hook.is_main({'session_id':'missing'}))
            self.assertEqual(path.read_bytes(),before)
            with sqlite3.connect(path) as db:db.execute('DROP TABLE threads')
            self.assertFalse(hook.is_main({'session_id':'main'}))

if __name__=='__main__':unittest.main()
