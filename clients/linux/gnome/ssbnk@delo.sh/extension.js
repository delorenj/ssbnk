import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const NAME = 'sh.delo.SSBNK.Client';
const PATH = '/sh/delo/SSBNK/Client';
const INTERFACE = 'sh.delo.SSBNK.Client1';

export default class SSBNKExtension extends Extension {
    enable() {
        this._active = true;
        this._copyBusy = false;
        this._generation = 0;
        this._ownerEpoch = 0;
        this._cancellable = new Gio.Cancellable();
        this._button = new PanelMenu.Button(0, 'SSBNK Client');
        this._button.add_child(new St.Icon({icon_name: 'camera-photo-symbolic', style_class: 'system-status-icon'}));
        Main.panel.addToStatusArea(this.uuid, this._button);
        this._render({rows: [], error: 'Start SSBNK Client to connect'});
        this._sessionSignal = Main.sessionMode.connect('updated', () => {
            if (Main.sessionMode.isLocked) {
                this._action('UnregisterCompanion');
                this._generation = 0;
                this._ownerEpoch++;
            } else {
                this._ownerChanged();
            }
        });
        Gio.DBusProxy.new_for_bus(Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, null,
            NAME, PATH, INTERFACE, this._cancellable, (source, result) => {
                if (!this._active)
                    return;
                try {
                    this._proxy = Gio.DBusProxy.new_for_bus_finish(result);
                    this._ownerSignal = this._proxy.connect('notify::g-name-owner', () => this._ownerChanged());
                    this._signal = this._proxy.connect('g-signal', (_proxy, _sender, name) => {
                        if (name === 'Changed')
                            this._refresh();
                        if (name === 'CopyRequestsChanged')
                            this._fetchCopyRequests();
                    });
                    this._ownerChanged();
                } catch {
                    this._render({rows: [], error: 'Session adapter unavailable'});
                }
            });
    }

    async _call(method, signature = '()', values = []) {
        if (!this._active || !this._proxy?.g_name_owner)
            throw new Error('Adapter unavailable');
        const epoch = this._ownerEpoch;
        const proxy = this._proxy;
        const result = await new Promise((resolve, reject) => {
            proxy.call(method, new GLib.Variant(signature, values), Gio.DBusCallFlags.NONE,
                15000, this._cancellable, (proxy, reply) => {
                    try {
                        resolve(proxy.call_finish(reply));
                    } catch (error) {
                        reject(error);
                    }
                });
        });
        if (!this._active || epoch !== this._ownerEpoch)
            throw new Error('Stale adapter owner');
        return result.deep_unpack();
    }

    async _ownerChanged() {
        this._ownerEpoch++;
        this._generation = 0;
        if (!this._active || Main.sessionMode.isLocked)
            return;
        if (!this._proxy?.g_name_owner) {
            this._render({rows: [], error: 'SSBNK Client disconnected; restart the adapter'});
            return;
        }
        try {
            [this._generation] = await this._call('RegisterCompanion', '(u)', [1]);
            await this._refresh();
            await this._fetchCopyRequests();
        } catch {
            if (this._active)
                this._render({rows: [], error: 'Adapter registration failed'});
        }
    }

    async _refresh() {
        try {
            const [snapshot] = await this._call('GetSnapshot');
            this._render(JSON.parse(snapshot));
        } catch {
            if (this._active)
                this._render({rows: [], error: 'History unavailable; check the Python adapter'});
        }
    }

    async _fetchCopyRequests() {
        const generation = this._generation;
        if (!generation || this._copyBusy)
            return;
        this._copyBusy = true;
        try {
            const [encoded] = await this._call('GetCopyRequests', '(t)', [generation]);
            for (const request of JSON.parse(encoded)) {
                if (generation !== this._generation || !this._active)
                    break;
                const [url] = await this._call('ClaimCopy', '(st)', [request.token, generation]);
                let status = 'unknown';
                if (generation === this._generation && this._active) {
                    try {
                        St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, url);
                        status = 'write-issued';
                    } catch {
                        status = 'unknown';
                    }
                }
                await this._call('AcknowledgeCopy', '(sts)', [request.token, generation, status]);
            }
        } catch {
            // Durable client claims remain consumed; reconnect never replays them.
        } finally {
            this._copyBusy = false;
        }
    }

    _action(method, uuid) {
        this._call(method, uuid ? '(s)' : '()', uuid ? [uuid] : []).catch(() => {});
    }

    _render(snapshot) {
        if (!this._active)
            return;
        this._button.menu.removeAll();
        const rows = snapshot.rows || [];
        if (snapshot.error || !rows.length)
            this._button.menu.addMenuItem(new PopupMenu.PopupMenuItem(snapshot.error || 'No captures yet', {reactive: false}));
        const icons = {queued: 'content-loading-symbolic', uploading: 'document-send-symbolic', error: 'dialog-error-symbolic', OK: 'emblem-ok-symbolic'};
        for (const row of rows.slice(0, 15)) {
            const time = new Date(row.time * 1000).toLocaleTimeString();
            const item = new PopupMenu.PopupImageMenuItem(`${row.filename} · ${time} · ${row.kind} · ${row.state}`, icons[row.state] || 'content-loading-symbolic');
            if (row.state === 'OK' && row.availability === 'available')
                item.connect('activate', () => this._action('RequestCopy', row.uuid));
            this._button.menu.addMenuItem(item);
            if (row.detail && !['ready', 'queued'].includes(row.detail))
                this._button.menu.addMenuItem(new PopupMenu.PopupMenuItem(row.detail, {reactive: false}));
            if (row.url) {
                const open = new PopupMenu.PopupMenuItem(`Open ${row.filename}`);
                open.connect('activate', () => this._action('RequestOpen', row.uuid));
                this._button.menu.addMenuItem(open);
            }
            if (row.state === 'error') {
                const retry = new PopupMenu.PopupMenuItem(`Retry ${row.filename}`);
                retry.connect('activate', () => this._action('RequestRetry', row.uuid));
                this._button.menu.addMenuItem(retry);
            }
        }
        this._button.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        const settings = new PopupMenu.PopupMenuItem('Options / Show all history');
        settings.connect('activate', () => this._action('OpenSettings'));
        this._button.menu.addMenuItem(settings);
    }

    disable() {
        if (this._proxy?.g_name_owner)
            this._proxy.call('UnregisterCompanion', null, Gio.DBusCallFlags.NONE, 1000, null, () => {});
        this._active = false;
        this._ownerEpoch++;
        this._cancellable?.cancel();
        if (this._signal)
            this._proxy.disconnect(this._signal);
        if (this._ownerSignal)
            this._proxy.disconnect(this._ownerSignal);
        if (this._sessionSignal)
            Main.sessionMode.disconnect(this._sessionSignal);
        this._sessionSignal = 0;
        this._button?.destroy();
        this._proxy = null;
        this._button = null;
    }
}
