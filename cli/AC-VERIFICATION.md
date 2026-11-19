# SSBNK-4 CLI acceptance verification

Verified on repair commit `786c7669350cc3d57d0537267887dae590c7d14d` (`ssbnk-4-cli-multi-get`). From the ticket worktree root:

```sh
cli/.venv/bin/python -m unittest discover -s cli/tests -v
```

Result: **16 tests passed**. `git diff --check` passed. Unit tests mock clipboard writes; the separate Wayland readback below exercised the real CLI and clipboard. Acceptance coverage:

| Criterion | Verification |
| --- | --- |
| AC1 — default `get` and explicit `get 1` retain one-image lookup and copy/quiet flags | `test_marker_precedes_newer_images_and_clipboard_matches_stdout`, `test_single_valid_marker_skips_directory_and_ledger_scans`, `test_no_copy_and_warning_modes` |
| AC2 — `get 3` selects three distinct paths, marker first, remaining directory images by mtime with deterministic ties | `test_marker_precedes_newer_images_and_clipboard_matches_stdout`, `test_scan_ties_dedup_overlapping_dirs_and_filters_nonimages` |
| AC3 — hosted/data and screenshot directories, supported image extensions, deduplication, stale marker fallback and ledger ordering | `test_absolute_marker_and_data_hosted_fallback`, `test_scan_ties_dedup_overlapping_dirs_and_filters_nonimages`, `test_stale_and_nonimage_markers_fall_back_to_directory`, `test_missing_absolute_marker_uses_basename_before_newer_images`, `test_ledger_only_when_directories_have_no_images`, `test_malformed_ledger_identities_do_not_hide_older_valid_images` |
| AC4 — stdout has one absolute path per line and one exact newline-joined plain-text clipboard payload, including a path with spaces | `test_marker_precedes_newer_images_and_clipboard_matches_stdout`; real clipboard readback below |
| AC5 — fewer than requested succeeds; none exits 1 with empty stdout and without clipboard access | `test_scan_ties_dedup_overlapping_dirs_and_filters_nonimages`, `test_no_images_exits_one_without_clipboard` |
| AC6 — invalid counts and extra arguments fail before lookup/copy; help documents count and output | `test_invalid_count_fails_before_lookup`, `test_help_describes_count_and_paths` |
| AC7 — `--no-copy` skips writing; clipboard failure warns but preserves success and stdout, quiet flags suppress warning | `test_no_copy_and_warning_modes` |
| AC8 — suite regression coverage and real CLI/Wayland clipboard readback | 16 passing tests listed above; real clipboard readback below |

**Real clipboard check after repair:** the parent ran the CLI against three local test images on commit `786c7669` and read back `wl-paste --no-newline`. Exit status was 0; stdout contained exactly three paths, with the older marker `shot.png` first, followed by `new.webp` and `middle.jpg`. The clipboard text exactly matched the newline-joined stdout paths without stdout's final newline. The pre-existing text clipboard was restored (`original_text_clipboard_restored=True`). This was a real clipboard check, not a unit-test mock. No further clipboard probe is needed. An independent reviewer reported no remaining actionable code findings on the repaired diff.
