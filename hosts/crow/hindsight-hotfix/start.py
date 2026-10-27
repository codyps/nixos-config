"""Apply the reviewed, hash-pinned repair before starting the stock API."""
import hashlib
import importlib.metadata
import importlib.util
from pathlib import Path
import runpy
import sys

ROOT = Path(__file__).resolve().parent
package = importlib.metadata.distribution('hindsight-api-slim')
if package.version != '0.10.2':
    raise SystemExit(f'Refusing unreviewed Hindsight version {package.version}')
target = Path(next(iter(importlib.util.find_spec('hindsight_api').submodule_search_locations))) / 'engine/reflect/delta_ops.py'
sys.argv = ['reapply.py', 'apply', '--target', str(target)]
runpy.run_path(str(ROOT / 'reapply.py'), run_name='__main__')
print('[crow] verified DeepSeek delta-repair hotfix', flush=True)
sys.argv = ['hindsight-api']
entry = next(iter(importlib.metadata.entry_points(group='console_scripts', name='hindsight-api')))
raise SystemExit(entry.load()())
