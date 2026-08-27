from __future__ import annotations

import shlex
import subprocess
from dataclasses import dataclass
from typing import Iterable


@dataclass
class CommandResult:
    argv: list[str]
    stdout: str
    stderr: str
    returncode: int


class CommandError(RuntimeError):
    def __init__(self, result: CommandResult):
        rendered = " ".join(shlex.quote(x) for x in result.argv)
        super().__init__(
            f"command failed ({result.returncode}): {rendered}\n"
            f"stdout: {result.stdout.strip()}\n"
            f"stderr: {result.stderr.strip()}"
        )
        self.result = result


def run(argv: Iterable[str], *, check: bool = True, timeout: int | None = None) -> CommandResult:
    args = [str(x) for x in argv]
    proc = subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    result = CommandResult(args, proc.stdout, proc.stderr, proc.returncode)
    if check and proc.returncode != 0:
        raise CommandError(result)
    return result
