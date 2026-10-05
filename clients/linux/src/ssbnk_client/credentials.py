from __future__ import annotations

import os
import selectors
import shutil
import subprocess
import time


class CredentialError(RuntimeError):
    pass


def resolve_credential(reference: str, timeout: float = 15) -> str:
    if not reference.startswith("op://DeLoSecrets/") or any(c in reference for c in "\r\n\x00"):
        raise CredentialError("Choose a DeLoSecrets op:// reference")
    executable = shutil.which("op")
    if not executable:
        raise CredentialError("Install 1Password CLI and authorize this desktop session")
    process = subprocess.Popen(
        [executable, "read", reference],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.stdout is None or process.stderr is None:
        process.kill()
        process.wait()
        raise CredentialError("Could not open credential memory pipes")
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + timeout
    try:
        while selector.get_map():
            if time.monotonic() >= deadline:
                raise CredentialError("Vault resolution timed out; authorize 1Password")
            for key, _ in selector.select(min(0.2, max(0, deadline - time.monotonic()))):
                data = os.read(key.fd, 4096)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                buffer = buffers[key.data]
                if len(buffer) + len(data) > 8192:
                    raise CredentialError("Vault response exceeds credential bound")
                buffer.extend(data)
        if process.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
            raise CredentialError("Vault access denied; unlock and authorize 1Password CLI")
        try:
            credential = buffers["stdout"].decode("utf-8").strip()
        except UnicodeDecodeError as error:
            raise CredentialError("Vault credential is not valid UTF-8") from error
        if not credential or any(c in credential for c in "\r\n\x00"):
            raise CredentialError("Vault credential is empty or malformed")
        return credential
    except subprocess.TimeoutExpired as error:
        raise CredentialError("Vault resolution timed out") from error
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        selector.close()
        process.stdout.close()
        process.stderr.close()
        for buffer in buffers.values():
            buffer[:] = b"\x00" * len(buffer)
