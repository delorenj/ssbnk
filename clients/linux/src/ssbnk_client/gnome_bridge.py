from __future__ import annotations

import threading
from pathlib import Path
from typing import Any

BUS_NAME = "sh.delo.SSBNK.Client"
OBJECT_PATH = "/sh/delo/SSBNK/Client"
INTERFACE = "sh.delo.SSBNK.Client1"


class GNOMEBridge:
    def __init__(self, worker: Any, open_settings: Any, open_url: Any) -> None:
        from gi.repository import Gio, GLib

        self.Gio, self.GLib = Gio, GLib
        self.closed = False
        self.worker, self.open_settings, self.open_url = worker, open_settings, open_url
        self.snapshot: dict[str, Any] = {"version": 1, "revision": 0, "rows": []}
        self.connection = None
        self.registration = 0
        self.companion_owner = ""
        self.generation = 0
        self.tokens: dict[str, dict[str, Any]] = {}
        self.changed_callback = lambda active: None
        xml = (Path(__file__).parent / "client1.xml").read_text()
        self.info = Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
        self.owner_id = Gio.bus_own_name(
            Gio.BusType.SESSION,
            BUS_NAME,
            Gio.BusNameOwnerFlags.NONE,
            self.bus_acquired,
            None,
            self.name_lost,
        )

    def bus_acquired(self, connection: Any, _name: str) -> None:
        self.connection = connection
        self.registration = connection.register_object(
            OBJECT_PATH, self.info, self.method_call, None, None
        )
        self.subscription = connection.signal_subscribe(
            "org.freedesktop.DBus",
            "org.freedesktop.DBus",
            "NameOwnerChanged",
            "/org/freedesktop/DBus",
            None,
            0,
            self.owner_changed,
        )

    def name_lost(self, _connection: Any, _name: str) -> None:
        self.companion_owner = ""
        self.tokens.clear()
        self.changed_callback(False)

    def owner_changed(
        self,
        _connection: Any,
        _sender: str,
        _path: str,
        _interface: str,
        _signal: str,
        parameters: Any,
    ) -> None:
        name, _old, new = parameters.unpack()
        if name == self.companion_owner and not new:
            self.companion_owner = ""
            self.generation += 1
            self.tokens.clear()
            self.changed_callback(False)

    def publish(self, snapshot: dict[str, Any]) -> None:
        generation = self.generation

        def apply() -> bool:
            if generation != self.generation or self.closed:
                return False
            if snapshot.get("latest_order", 0) > self.snapshot.get(
                "latest_order", 0
            ) or snapshot.get("copy_fence", 0) > self.snapshot.get("copy_fence", 0):
                self.tokens.clear()
            self.snapshot = snapshot
            if self.connection:
                self.connection.emit_signal(
                    None,
                    OBJECT_PATH,
                    INTERFACE,
                    "Changed",
                    self.GLib.Variant("(t)", (snapshot.get("revision", 0),)),
                )
            return False

        self.GLib.idle_add(apply)

    def method_call(
        self,
        _connection: Any,
        sender: str,
        _path: str,
        _interface: str,
        method: str,
        parameters: Any,
        invocation: Any,
    ) -> None:
        import json

        values = parameters.unpack()
        try:
            if method == "GetSnapshot":
                invocation.return_value(self.GLib.Variant("(s)", (json.dumps(self.snapshot),)))
                return
            if method == "RegisterCompanion":
                if values[0] != 1:
                    raise ValueError("Unsupported bridge version")
                self.companion_owner = sender
                self.generation += 1
                self.tokens.clear()
                self.changed_callback(True)
                invocation.return_value(self.GLib.Variant("(t)", (self.generation,)))
                return
            if method == "UnregisterCompanion":
                if sender == self.companion_owner:
                    self.companion_owner = ""
                    self.generation += 1
                    self.tokens.clear()
                    self.changed_callback(False)
            elif method == "GetCopyRequests":
                if sender != self.companion_owner or values[0] != self.generation:
                    raise ValueError("Stale companion generation")
                eligible = [
                    dict(token=token, **request)
                    for token, request in self.tokens.items()
                    if not request["consumed"]
                ]
                invocation.return_value(self.GLib.Variant("(s)", (json.dumps(eligible),)))
                return
            elif method == "ClaimCopy":
                token, generation = values
                request = self.tokens.get(token)
                if (
                    sender != self.companion_owner
                    or generation != self.generation
                    or not request
                    or request["consumed"]
                ):
                    raise ValueError("Copy token is stale or consumed")
                request["consumed"] = True
                invocation.return_value(self.GLib.Variant("(s)", (request["url"],)))
                return
            elif method == "AcknowledgeCopy":
                token, generation, status = values
                request = self.tokens.get(token)
                if sender != self.companion_owner or generation != self.generation or not request:
                    raise ValueError("Copy acknowledgement is stale")
                if status not in ("write-issued", "read-back-observed", "unknown"):
                    raise ValueError("Unknown copy acknowledgement")
                self.worker.submit("copy_ack", (request["uuid"], status))
                self.tokens.pop(token, None)
            elif method in ("RequestCopy", "RequestRetry"):
                self.worker.submit("copy" if method == "RequestCopy" else "retry", values[0])
            elif method == "RequestOpen":
                row = next(row for row in self.snapshot.get("rows", []) if row["uuid"] == values[0])
                if row.get("url"):
                    self.open_url(row["url"])
            elif method == "OpenSettings":
                self.open_settings()
            else:
                raise ValueError("Unknown bridge method")
            invocation.return_value(self.GLib.Variant("()", ()))
        except Exception:
            invocation.return_dbus_error(INTERFACE + ".InvalidRequest", "Request rejected")

    def dispatch_copy(self, identifier: str, url: str) -> Any:
        import uuid

        from .clipboard import CopyOutcome

        completed = threading.Event()
        outcome = [CopyOutcome("unknown", "GNOME companion unavailable; use Retry copy")]

        def dispatch() -> bool:
            if self.companion_owner and not self.closed:
                token = str(uuid.uuid4())
                self.tokens.clear()
                self.tokens[token] = {
                    "uuid": identifier,
                    "url": url,
                    "generation": self.generation,
                    "consumed": False,
                }
                self.connection.emit_signal(
                    self.companion_owner,
                    OBJECT_PATH,
                    INTERFACE,
                    "CopyRequestsChanged",
                    self.GLib.Variant("(t)", (self.generation,)),
                )
                outcome[0] = CopyOutcome("unknown", "Copy acknowledgement pending")
            completed.set()
            return False

        self.GLib.idle_add(dispatch)
        completed.wait(5)
        return outcome[0]

    def close(self) -> None:
        self.closed = True
        self.generation += 1
        self.tokens.clear()
        if self.connection and self.registration:
            self.connection.unregister_object(self.registration)
        if self.connection and hasattr(self, "subscription"):
            self.connection.signal_unsubscribe(self.subscription)
        self.Gio.bus_unown_name(self.owner_id)
