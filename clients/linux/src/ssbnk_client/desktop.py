from __future__ import annotations

import sys
from typing import Any

from .autostart import set_launch_at_login
from .clipboard import copy_native
from .config import Configuration, xdg_paths
from .gnome_bridge import GNOMEBridge
from .session import Singleton, desktop_session
from .worker import Worker


class Desktop:
    def __init__(self) -> None:
        import gi

        gi.require_version("Gtk", "3.0")
        from gi.repository import Gio, GLib, Gtk

        self.Gio, self.GLib, self.Gtk = Gio, GLib, Gtk
        config_directory, self.state_directory = xdg_paths()
        self.singleton = Singleton(self.state_directory)
        self.config_path = config_directory / "configuration.json"
        self.configuration = Configuration.load(self.config_path)
        self.snapshot: dict[str, Any] = {"version": 1, "rows": []}
        self.window = Gtk.Window(title="SSBNK Client — Options and History")
        self.window.set_default_size(720, 640)
        self.window.connect("delete-event", self.hide_window)
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        layout.set_border_width(16)
        self.window.add(layout)
        self.remedy = Gtk.Label(xalign=0)
        self.remedy.set_line_wrap(True)
        layout.pack_start(self.remedy, False, False, 0)
        grid = Gtk.Grid(column_spacing=12, row_spacing=10)
        self.fields = {}
        for index, (key, label, value) in enumerate(
            [
                ("screenshot_directory", "Screenshots", self.configuration.screenshot_directory),
                ("recording_directory", "Recordings", self.configuration.recording_directory),
                ("api_origin", "API origin", self.configuration.api_origin),
                (
                    "credential_reference",
                    "DeLoSecrets reference",
                    self.configuration.credential_reference,
                ),
            ]
        ):
            entry = Gtk.Entry(text=value)
            entry.set_hexpand(True)
            self.fields[key] = entry
            grid.attach(Gtk.Label(label=label, xalign=0), 0, index, 1, 1)
            grid.attach(entry, 1, index, 1, 1)
            if key.endswith("directory"):
                picker = Gtk.Button(label="Choose…")
                picker.connect("clicked", self.choose_folder, entry)
                grid.attach(picker, 2, index, 1, 1)
        layout.pack_start(grid, False, False, 0)
        self.login = Gtk.CheckButton(label="Launch in my graphical session at login")
        self.login.set_active(self.configuration.launch_at_login)
        layout.pack_start(self.login, False, False, 0)
        controls = Gtk.Box(spacing=8)
        for label, callback in [
            ("Save settings", self.save),
            ("Sync existing", self.sync_existing),
            ("Legacy handover…", self.handover),
            ("Quit", self.quit),
        ]:
            button = Gtk.Button(label=label)
            button.connect("clicked", callback)
            controls.pack_start(button, False, False, 0)
        layout.pack_start(controls, False, False, 0)
        self.history = Gtk.ListBox()
        self.history.connect("row-activated", self.activate_row)
        self.history.set_selection_mode(Gtk.SelectionMode.NONE)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.history)
        layout.pack_start(scroll, True, True, 0)
        self.worker = Worker(self.state_directory, self.configuration, self.publish, self.copy)
        self.bridge = GNOMEBridge(self.worker, self.show, self.open_url)
        self.bridge.changed_callback = self.companion_changed
        self.indicator = None
        self.create_indicator()
        self.worker.thread.start()
        self.window.show_all()

    def create_indicator(self) -> None:
        if desktop_session() == "gnome":
            self.remedy.set_text(
                "Enable the SSBNK GNOME companion next session and verify ACTIVE. "
                "This window remains available."
            )
            return
        try:
            import gi

            gi.require_version("AyatanaAppIndicator3", "0.1")
            from gi.repository import AyatanaAppIndicator3

            self.indicator_api = AyatanaAppIndicator3
            self.indicator = AyatanaAppIndicator3.Indicator.new(
                "ssbnk-client",
                "camera-photo-symbolic",
                AyatanaAppIndicator3.IndicatorCategory.APPLICATION_STATUS,
            )
            self.indicator.set_status(AyatanaAppIndicator3.IndicatorStatus.ACTIVE)
            self.refresh_indicator()
            self.remedy.set_text(
                "If your desktop has no tray host, keep this window open "
                "and enable Waybar tray support."
            )
        except (ImportError, ValueError):
            self.remedy.set_text(
                "Ayatana tray adapter missing. Install the declared desktop dependencies; "
                "this window remains available."
            )

    def companion_changed(self, active: bool) -> None:
        if self.indicator:
            self.indicator.set_status(
                self.indicator_api.IndicatorStatus.PASSIVE
                if active
                else self.indicator_api.IndicatorStatus.ACTIVE
            )

    def copy(self, identifier: str, url: str) -> Any:
        if desktop_session() != "gnome":
            return copy_native(url)
        return self.bridge.dispatch_copy(identifier, url)

    def publish(self, snapshot: dict[str, Any]) -> None:
        def apply() -> bool:
            self.snapshot = snapshot
            self.bridge.publish(snapshot)
            for child in self.history.get_children():
                self.history.remove(child)
            errors = [
                snapshot.get("error", ""),
                snapshot.get("handover_error", ""),
                *snapshot.get("root_errors", {}).values(),
            ]
            if snapshot.get("handover") == "pending":
                errors.append(
                    "Legacy uploader detected. Automatic submissions are gated "
                    "pending controlled handover."
                )
            self.remedy.set_text("\n".join(error for error in errors if error))
            for row in snapshot.get("rows", [])[:500]:
                self.history.add(self.history_row(row))
            if not snapshot.get("rows"):
                self.history.add(
                    self.Gtk.Label(
                        label="No captures yet. Existing files are baselined until Sync existing."
                    )
                )
            self.history.show_all()
            self.refresh_indicator()
            return False

        self.GLib.idle_add(apply)

    def history_row(self, row: dict[str, Any]) -> Any:
        from datetime import datetime

        Gtk = self.Gtk
        box = Gtk.Box(spacing=8)
        box.set_border_width(8)
        icons = {
            "queued": "content-loading-symbolic",
            "uploading": "document-send-symbolic",
            "error": "dialog-error-symbolic",
            "OK": "emblem-ok-symbolic",
        }
        box.pack_start(
            Gtk.Image.new_from_icon_name(
                icons.get(row["state"], "content-loading-symbolic"), Gtk.IconSize.MENU
            ),
            False,
            False,
            0,
        )
        capture_time = datetime.fromtimestamp(row["time"]).strftime("%H:%M:%S")
        text = f"{row['filename']} · {capture_time} · {row['kind']} · {row['state']}"
        if row.get("detail"):
            text += "\n" + row["detail"]
        label = Gtk.Label(label=text, xalign=0)
        label.set_line_wrap(True)
        box.pack_start(label, True, True, 0)
        if row["state"] == "OK" and row.get("availability") == "available":
            button = Gtk.Button(
                label="Retry copy" if "copy" in row.get("detail", "").lower() else "Copy"
            )
            button.connect("clicked", lambda _: self.worker.submit("copy", row["uuid"]))
            box.pack_start(button, False, False, 0)
        if row.get("url"):
            button = Gtk.Button(label="Open")
            button.connect("clicked", lambda _: self.open_url(row["url"]))
            box.pack_start(button, False, False, 0)
        if row["state"] == "error":
            button = Gtk.Button(label="Retry")
            button.connect("clicked", lambda _: self.worker.submit("retry", row["uuid"]))
            box.pack_start(button, False, False, 0)
        return box

    def activate_row(self, _list: Any, row: Any) -> None:
        index = row.get_index()
        rows = self.snapshot.get("rows", [])
        if index < len(rows) and rows[index]["state"] == "OK":
            self.worker.submit("copy", rows[index]["uuid"])

    def refresh_indicator(self) -> None:
        if not self.indicator:
            return
        from datetime import datetime

        menu = self.Gtk.Menu()
        icons = {
            "queued": "content-loading-symbolic",
            "uploading": "document-send-symbolic",
            "error": "dialog-error-symbolic",
            "OK": "emblem-ok-symbolic",
        }
        for row in self.snapshot.get("rows", [])[:15]:
            capture_time = datetime.fromtimestamp(row["time"]).strftime("%H:%M:%S")
            item = self.Gtk.ImageMenuItem(
                label=f"{row['filename']} · {capture_time} · {row['kind']} · {row['state']}"
            )
            item.set_image(
                self.Gtk.Image.new_from_icon_name(
                    icons.get(row["state"], "content-loading-symbolic"), self.Gtk.IconSize.MENU
                )
            )
            item.set_always_show_image(True)
            if row["state"] == "OK":
                item.connect(
                    "activate",
                    lambda _, identifier=row["uuid"]: self.worker.submit("copy", identifier),
                )
            menu.append(item)
            if row.get("url"):
                action = self.Gtk.MenuItem(label="Open " + row["filename"])
                action.connect("activate", lambda _, url=row["url"]: self.open_url(url))
                menu.append(action)
            if row["state"] == "error":
                action = self.Gtk.MenuItem(label="Retry " + row["filename"])
                action.connect(
                    "activate",
                    lambda _, identifier=row["uuid"]: self.worker.submit("retry", identifier),
                )
                menu.append(action)
        for label, callback in [("Options / Show all history", self.show), ("Quit", self.quit)]:
            item = self.Gtk.MenuItem(label=label)
            item.connect("activate", callback)
            menu.append(item)
        menu.show_all()
        self.indicator.set_menu(menu)

    def choose_folder(self, _button: Any, entry: Any) -> None:
        dialog = self.Gtk.FileChooserDialog(
            title="Choose capture folder",
            parent=self.window,
            action=self.Gtk.FileChooserAction.SELECT_FOLDER,
        )
        dialog.add_buttons(
            "Cancel", self.Gtk.ResponseType.CANCEL, "Choose", self.Gtk.ResponseType.OK
        )
        if dialog.run() == self.Gtk.ResponseType.OK:
            entry.set_text(dialog.get_filename())
        dialog.destroy()

    def save(self, *_args: Any) -> None:
        try:
            configuration = Configuration(
                **{key: entry.get_text() for key, entry in self.fields.items()},
                launch_at_login=self.login.get_active(),
            ).parsed()
            configuration.save(self.config_path)
            set_launch_at_login(configuration.launch_at_login)
            self.configuration = configuration
            self.worker.submit("configuration", configuration)
        except (ValueError, OSError) as error:
            self.remedy.set_text(str(error))

    def handover(self, *_args: Any) -> None:
        dialog = self.Gtk.MessageDialog(
            transient_for=self.window,
            modal=True,
            message_type=self.Gtk.MessageType.QUESTION,
            buttons=self.Gtk.ButtonsType.OK_CANCEL,
            text=(
                "Verify vault migration and a controlled capture, then disable the legacy uploader?"
            ),
        )
        dialog.format_secondary_text(
            "The boundary is persisted before disabling. Failure preserves rollback. "
            "Legacy credential files are never deleted."
        )
        if dialog.run() == self.Gtk.ResponseType.OK:
            self.worker.submit("handover", True)
        dialog.destroy()

    def sync_existing(self, *_args: Any) -> None:
        self.worker.submit("existing")

    def open_url(self, url: str) -> None:
        self.Gio.AppInfo.launch_default_for_uri(url, None)

    def show(self, *_args: Any) -> None:
        self.window.show_all()
        self.window.present()

    def hide_window(self, *_args: Any) -> bool:
        if self.bridge.companion_owner:
            self.window.hide()
        else:
            self.remedy.set_text(
                "No tray host detected. Use Quit to stop; the accessible window stays open."
            )
        return True

    def quit(self, *_args: Any) -> None:
        self.worker.stopping.set()
        self.worker.thread.join(timeout=65)
        if self.worker.thread.is_alive():
            self.remedy.set_text(
                "Waiting for the bounded active request before releasing the queue lock"
            )
            return
        self.bridge.close()
        self.singleton.close()
        self.Gtk.main_quit()


def main() -> None:
    try:
        desktop = Desktop()
        desktop.Gtk.main()
    except (ImportError, ValueError, RuntimeError) as error:
        sys.stderr.write(f"SSBNK Client: {error}\n")
        raise SystemExit(1) from error
