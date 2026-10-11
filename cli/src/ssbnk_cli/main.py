from __future__ import annotations

import json
import sys
from typing import Annotated, Optional

import typer
from rich.console import Console
from rich.table import Table

from .clipboard import copy_to_wl_clipboard
from .config import get_config_map, load_all_config
from .get import get_most_recent_screenshot

app = typer.Typer(
    name="ssbnk",
    help="ssbnk - self-hosted screenshot hosting CLI.",
    no_args_is_help=True,
    add_completion=False,
)

console = Console()
err_console = Console(stderr=True)


@app.command("get")
def get(
    copy: Annotated[
        bool,
        typer.Option(
            "--copy/--no-copy",
            help="Put screenshot path in wl-copy clipboard (default: enabled).",
        ),
    ] = True,
    quiet: Annotated[
        bool,
        typer.Option(
            "--quiet",
            "-q",
            help="Suppress non-fatal clipboard warnings.",
        ),
    ] = False,
) -> None:
    """Print the path of the most recent screenshot and copy it to wl-clipboard."""
    config = get_config_map()
    screenshot_path = get_most_recent_screenshot(config)

    if not screenshot_path:
        err_console.print("[red]Error:[/red] No recent screenshot found.")
        raise typer.Exit(code=1)

    path_str = str(screenshot_path)

    # 1. Print path of the most recent screenshot to stdout
    sys.stdout.write(path_str + "\n")
    sys.stdout.flush()

    # 2. Put path in wl-copy clipboard too
    if copy:
        ok, err = copy_to_wl_clipboard(path_str)
        if not ok and not quiet:
            err_console.print(f"[yellow]Warning:[/yellow] Could not copy to wl-clipboard: {err}")


@app.command("config")
def config(
    key: Annotated[
        Optional[str],
        typer.Argument(
            help="Optional configuration key to print.",
        ),
    ] = None,
    json_output: Annotated[
        bool,
        typer.Option(
            "--json",
            "-j",
            help="Output configuration as JSON.",
        ),
    ] = False,
    plain: Annotated[
        bool,
        typer.Option(
            "--plain",
            "-p",
            help="Output plain KEY=VALUE lines.",
        ),
    ] = False,
    reveal_secrets: Annotated[
        bool,
        typer.Option(
            "--reveal-secrets",
            help="Reveal raw secret values instead of masking them.",
        ),
    ] = False,
) -> None:
    """Print the current configuration variables."""
    config_vars = load_all_config()

    if key:
        var = config_vars.get(key)
        if not var:
            err_console.print(f"[red]Error:[/red] Unknown configuration variable '{key}'.")
            raise typer.Exit(code=1)
        sys.stdout.write(var.display_value(reveal_secrets) + "\n")
        sys.stdout.flush()
        return

    if json_output:
        payload = {
            k: {
                "value": var.display_value(reveal_secrets),
                "source": var.source,
                "is_secret": var.is_secret,
            }
            for k, var in config_vars.items()
        }
        sys.stdout.write(json.dumps(payload, indent=2) + "\n")
        sys.stdout.flush()
        return

    if plain or not sys.stdout.isatty():
        for k in sorted(config_vars.keys()):
            var = config_vars[k]
            sys.stdout.write(f"{var.key}={var.display_value(reveal_secrets)}\n")
        sys.stdout.flush()
        return

    # Rich formatted table when in an interactive terminal
    table = Table(title="ssbnk Configuration", show_header=True, header_style="bold magenta")
    table.add_column("Variable", style="cyan", no_wrap=True)
    table.add_column("Value", style="green")
    table.add_column("Source", style="yellow")

    for k in sorted(config_vars.keys()):
        var = config_vars[k]
        val = var.display_value(reveal_secrets)
        val_display = val if val else "[dim]<not set>[/dim]"
        table.add_row(var.key, val_display, var.source)

    console.print(table)


def main() -> None:
    app()


if __name__ == "__main__":
    main()
