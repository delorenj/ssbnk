# `ssbnk get`

Run `ssbnk get [num]` to print up to `num` existing local image paths (default 1), one resolved absolute path per line. The same newline-joined paths are copied as **plain text** to the Wayland clipboard once; they are not URLs or image bytes. Use `--no-copy` to leave the clipboard untouched. `--quiet`/`-q` suppresses clipboard failure warnings, not the path output. Clipboard failure does not affect the exit status when images were found.

A valid `last-screenshot` marker wins first, even if it is older. Remaining images come from configured hosted and screenshot directories, ordered by descending modification time; ties use the resolved absolute path in ascending lexicographic order. Repeated directories and resolved files are deduplicated. When those directories contain no images, the local capture ledger supplies existing image paths in descending capture-time order. If fewer than `num` exist, all available paths are returned successfully; if none exist, the command exits 1 without copying. `num` must be a positive integer.

```sh
ssbnk get              # latest image
ssbnk get 3            # up to three paths, copied together
ssbnk get 3 --no-copy  # print only
```
