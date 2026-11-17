#!/usr/bin/env python3
"""Offline source checks: local links, private paths and accidental credentials."""
from pathlib import Path
import json
import re
import sys

ROOT=Path(__file__).resolve().parents[1]
EXCLUDE={'.git','.build','dist','__pycache__','.venv'}
TEXT={'.py','.swift','.ino','.json','.md','.yml','.yaml','.html','.css','.svg','.sh','.csv','.plist','.txt'}
PATTERNS=[re.compile(r'/Users/[A-Za-z0-9_.-]+'),re.compile(r'gh[pousr]_[A-Za-z0-9]{20,}'),re.compile(r'sk-[A-Za-z0-9_-]{24,}'),re.compile(r'-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----')]

def check():
    errors=[];files=[]
    for p in ROOT.rglob('*'):
        if not p.is_file() or any(x in EXCLUDE for x in p.relative_to(ROOT).parts):continue
        files.append(p)
        if p.name=='.env' or p.suffix in {'.pem','.key','.sqlite','.jsonl'}:errors.append(f'Private runtime file: {p.relative_to(ROOT)}')
        if p.suffix not in TEXT and p.name not in {'LICENSE','VERSION'}:continue
        value=p.read_text(encoding='utf-8')
        for pattern in PATTERNS:
            if pattern.search(value):errors.append(f'Possible private path/credential in {p.relative_to(ROOT)}')
        links=[]
        if p.suffix=='.md':links+=re.findall(r'!?\[[^\]]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)',value)
        if p.suffix=='.html':links+=re.findall(r'(?:href|src)=["\']([^"\']+)',value)
        for link in links:
            if link.startswith(('http:','https:','mailto:','#','data:')):continue
            target=link.split('#')[0].split('?')[0]
            if target and not (p.parent/target).exists():errors.append(f'Broken local link in {p.relative_to(ROOT)}: {target}')
    for required in ['README.md','README.zh-CN.md','LICENSE','macos/VoiceBridge.swift','hardware/wiring.json','docs/getting-started.md','docs/assets/button-demo.mp4']:
        if not (ROOT/required).is_file():errors.append('Missing '+required)
    plan=json.loads((ROOT/'hardware/wiring.json').read_text())
    if [b['pin'] for b in plan['buttons']]!=[8,9,11,12]:errors.append('Button map differs from firmware')
    if [l['pin'] for l in plan['leds']]!=[2,3,4]:errors.append('LED map differs from firmware')
    if errors:
        print('\n'.join(errors));return 1
    print(f'PASS: {len(files)} public files scanned; local links and source-release checks passed.')
    return 0

if __name__=='__main__':sys.exit(check())
