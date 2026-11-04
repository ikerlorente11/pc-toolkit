# chat.py - "jarvis chat --voice" de OpenJarvis con las voces locales de Jarvis registradas
# (backend "pctoolkit_local"). Lo lanza chat.ps1 con el entorno ya preparado.
#   python chat.py <carpeta de datos>

import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import local_voices  # noqa: E402

local_voices.register_openjarvis_backend(Path(sys.argv[1]) / "voices")

from openjarvis.cli import main  # noqa: E402

sys.argv = ["jarvis", "chat", "--voice"]
sys.exit(main())
