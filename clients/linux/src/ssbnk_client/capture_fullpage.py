from __future__ import annotations

import argparse
import asyncio
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from .config import Configuration, xdg_paths


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="ssbnk-capture-fullpage",
        description="Capture a web page's full vertical content to the SSBNK screenshot directory",
    )
    parser.add_argument("url", help="URL to capture (http/https)")
    parser.add_argument(
        "-o",
        "--output-dir",
        help="Output directory (defaults to configured screenshot directory)",
    )
    parser.add_argument(
        "--wait-until",
        choices=["load", "domcontentloaded", "networkidle"],
        default="networkidle",
        help="Playwright wait condition (default: networkidle)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60000,
        help="Navigation timeout in milliseconds (default: 60000)",
    )
    parser.add_argument(
        "--device-scale-factor",
        type=float,
        default=1.0,
        help="Device scale factor for capture (default: 1.0)",
    )
    parser.add_argument(
        "--no-clipboard",
        action="store_true",
        help="Do not copy the hosted URL to clipboard after upload",
    )
    return parser.parse_args(argv)


def resolve_output_dir(args: argparse.Namespace, config: Configuration) -> Path:
    if args.output_dir:
        return Path(args.output_dir).expanduser().resolve()
    return Path(config.screenshot_directory).expanduser().resolve()


def timestamped_filename(ext: str = ".png") -> str:
    return datetime.now(UTC).strftime("%Y%m%d-%H%M%S-%f") + ext


async def capture_fullpage(
    url: str,
    output_path: Path,
    wait_until: Literal["commit", "domcontentloaded", "load", "networkidle"],
    timeout: int,
    device_scale_factor: float,
) -> None:
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        try:
            context = await browser.new_context(device_scale_factor=device_scale_factor)
            page = await context.new_page()
            await page.goto(url, wait_until=wait_until, timeout=timeout)
            # Wait for fonts and any lazy-loaded images
            await page.wait_for_load_state("networkidle")
            # Give a brief moment for any final layout shifts
            await page.wait_for_timeout(500)
            # Capture full page
            await page.screenshot(path=str(output_path), full_page=True)
        finally:
            await browser.close()


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    # Validate URL
    if not (args.url.startswith("http://") or args.url.startswith("https://")):
        print("Error: URL must start with http:// or https://", file=sys.stderr)
        return 1

    # Load configuration to get default screenshot directory
    config_dir, state_dir = xdg_paths()
    config_path = config_dir / "configuration.json"
    try:
        config = Configuration.load(config_path)
    except (OSError, ValueError) as e:
        print(f"Error loading configuration from {config_path}: {e}", file=sys.stderr)
        return 1

    output_dir = resolve_output_dir(args, config)
    output_dir.mkdir(parents=True, exist_ok=True)

    output_file = output_dir / timestamped_filename()

    print(f"Capturing {args.url} -> {output_file}")
    try:
        asyncio.run(
            capture_fullpage(
                args.url,
                output_file,
                args.wait_until,
                args.timeout,
                args.device_scale_factor,
            )
        )
    except ImportError:
        print(
            "Error: Playwright not installed. Install with: "
            "pip install 'ssbnk-client[fullpage]' && playwright install chromium",
            file=sys.stderr,
        )
        return 1
    except Exception as e:
        print(f"Error during capture: {e}", file=sys.stderr)
        return 1

    if not output_file.exists():
        print(f"Error: Output file not created at {output_file}", file=sys.stderr)
        return 1

    size = output_file.stat().st_size
    print(f"Capture saved: {output_file} ({size} bytes)")

    # The scanner will pick up the file automatically and upload it.
    # Clipboard URL will be available via the tray once upload completes.
    if not args.no_clipboard:
        print(
            "File written to capture directory. The SSBNK client will upload it "
            "and the hosted URL will be available via the tray Copy action."
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())