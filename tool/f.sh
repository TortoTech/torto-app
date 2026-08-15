#!/usr/bin/env bash
# Wrapper to run the Flutter tool from Git Bash on this machine.
# flutter.bat fails here because cmd.exe inherits a stripped PATH without git;
# invoking flutter_tools.snapshot directly with dart bypasses flutter.bat.
export FLUTTER_ROOT=/d/flutter
exec /d/flutter/bin/cache/dart-sdk/bin/dart /d/flutter/bin/cache/flutter_tools.snapshot "$@"
