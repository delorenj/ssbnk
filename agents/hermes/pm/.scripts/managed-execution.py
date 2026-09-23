#!/usr/bin/env python3
"""Krebs heartbeat: renew dispatched authority, or invoke a supervised PM planner."""
import json
import os
from pathlib import Path
import subprocess
import sys

root=Path(sys.argv[1]).resolve()
manifest=json.loads((root/'.project.json').read_text())
execution=manifest.get('execution',{})
actor=os.environ.get('PILOT_ACTOR_ID') or execution.get('pm_actor')
if not actor: raise SystemExit('managed execution: actor enrollment missing')
def px(*args):
    result=subprocess.run(['px',*args,'--actor',actor,'--json'],cwd=root,capture_output=True,text=True)
    if result.returncode: raise SystemExit('managed execution: controller unavailable or enrollment invalid')
    return json.loads(result.stdout)
status=px('task','status');board=status['board'];attempt=board.get('active')
action='observe'
planning_enabled=os.environ.get('KREBS_PLANNER_ENABLED','true')=='true'
if execution.get('mode')=='managed' and not board.get('pending'):
    if attempt and attempt['actor_id']==actor and not attempt.get('revoked'):
        record=board['tickets'].get(attempt['ticket_id'],{})
        if record.get('dispatched') or (record.get('outcome') or {}).get('outcome')=='success':
            renewed=px('run','heartbeat',attempt['ticket_id'],'--run-id',attempt['run_id'],
               '--generation',str(attempt['generation']),'--revision',str(board['revision']))
            action='renew'
            if planning_enabled and (record.get('outcome') or {}).get('outcome')=='success' and actor==execution.get('pm_actor'):
                px('run','planner','_board','--revision',str(renewed['revision']))
                action='supervised-review-planner'
    elif planning_enabled and not attempt and actor==execution.get('pm_actor'):
        px('run','planner','_board','--revision',str(board['revision']))
        action='supervised-planner'
print(json.dumps({'managed':True,'mode':execution['mode'],'active_run':attempt.get('run_id') if attempt else None,'action':action}))
