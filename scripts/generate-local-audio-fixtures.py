#!/usr/bin/env python3
"""Create personal local speech fixtures using already-installed macOS voices.

Never run in CI or publish the generated audio. Apple macOS Tahoe SLA 2F limits
System Voices output to personal, noncommercial use and excludes public sharing:
https://www.apple.com/legal/sla/docs/macOSTahoe.pdf
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import wave


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New local directory outside public source paths')
    args = parser.parse_args()
    if os.environ.get('MACAPY_GENERATE_LOCAL_AUDIO') != '1':
        parser.error('Explicit personal-local opt-in required: MACAPY_GENERATE_LOCAL_AUDIO=1')
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    if output.exists():
        parser.error('Output must be a new directory; existing fixtures are never overwritten')
    if output.is_relative_to(root):
        ignored = subprocess.run(['git', 'check-ignore', '-q', str(output)], cwd=root).returncode == 0
        if not ignored:
            parser.error('Generated audio must remain outside public source paths (use ignored docs/fixtures-local/generated)')
    available = subprocess.check_output(['/usr/bin/say', '-v', '?'], text=True)
    for voice in ('Samantha', 'Daniel'):
        if not re.search(r'^' + voice + r'\s', available, re.M):
            parser.error(f'{voice} must already be installed; this script does not install voices')
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='macapy-local-speech-') as temporary:
        scratch = Path(temporary)
        def synthesize(name, voice, text):
            aiff = scratch / (name + '.aiff')
            wav = scratch / (name + '.wav')
            subprocess.run(['/usr/bin/say', '-v', voice, '-r', '160', '-o', str(aiff), text], check=True)
            subprocess.run(['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)], check=True)
            return wav
        phrases = {
            'fox': 'The quick brown fox jumps over the lazy dog. This meeting is being transcribed locally on the device.',
            'train': 'The train departs from central station tomorrow morning. Passengers should arrive early at the platform.',
            'long-meeting': ' '.join(f'In discussion number {i}, the team reviewed a synthetic project update and agreed to check the next milestone during the following review.' for i in range(1,31)),
        }
        for name, text in phrases.items():
            (output / (name + '.wav')).write_bytes(synthesize(name, 'Samantha', text).read_bytes())
        turns = [
            'We reviewed the synthetic project schedule and agreed that the next demonstration should explain local transcription clearly.',
            'The demonstration should also show a searchable history entry and an action item that remains a draft until approved.',
            'Our next review will use synthetic notes so that no private meeting or personal information enters the public example.',
            'A failed optional request should leave capture running, and the interface should describe the failure without exposing content.',
            'The source list should show the exact evidence used for an answer and should remove references after the source is deleted.',
        ]
        schedule, frames = [], []
        position = 0
        for index in range(10):
            voice, speaker = ('Daniel', 'A') if index % 2 == 0 else ('Samantha', 'B')
            with wave.open(str(synthesize(f'turn-{index}', voice, turns[index // 2])), 'rb') as audio:
                assert audio.getframerate() == 16_000 and audio.getsampwidth() == 2 and audio.getnchannels() == 1
                count = audio.getnframes(); payload = audio.readframes(count)
            schedule.append({'speaker': speaker, 'tStart': position / 16_000, 'tEnd': (position + count) / 16_000})
            frames.append(payload); position += count
            if index < 9:
                frames.append(b'\0' * (11_200 * 2)); position += 11_200
        with wave.open(str(output / 'two-voices.wav'), 'wb') as audio:
            audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16_000)
            for payload in frames: audio.writeframesraw(payload)
        (output / 'schedule.json').write_text(json.dumps(schedule, indent=2) + '\n')
    manifest = {'scope': 'personal-local-only; do not publish generated audio',
                'terms': 'https://www.apple.com/legal/sla/docs/macOSTahoe.pdf',
                'voices': ['Daniel','Samantha'], 'rate_words_per_minute': 160,
                'files': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in output.iterdir() if p.is_file()}}
    (output / 'local-provenance.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print('Local fixtures created. Model tests require a separate explicit opt-in; do not publish this audio.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
