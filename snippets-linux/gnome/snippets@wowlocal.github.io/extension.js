import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Keyboard from 'resource:///org/gnome/shell/ui/status/keyboard.js';
import * as IBusManager from 'resource:///org/gnome/shell/misc/ibusManager.js';

const APP = 'com.khm.snippets.linux';
const PATH = '/com/khm/Snippets/Gnome';
const XML = `<node><interface name="com.khm.Snippets.Gnome1">
<method name="EnableInput"><arg type="b" direction="out"/></method>
<method name="Capture"><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<method name="Check"><arg type="s" direction="in"/><arg type="b" direction="out"/><arg type="b" direction="out"/></method>
<method name="Focus"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
<method name="Commit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
<method name="Release"><arg type="s" direction="in"/></method>
</interface></node>`;
const LIFETIME_US = 120 * 1000000;

// Only public input-purpose and hint enums are inspected. Never read or retain
// surrounding text, window titles, clipboard contents, or application bodies.
function ordinaryFocus() {
    const im = Main.inputMethod;
    if (!im?.currentFocus?.is_focused())
        return null;
    const purposes = ['NORMAL', 'ALPHA', 'DIGITS', 'NUMBER', 'PHONE', 'URL',
        'EMAIL', 'NAME', 'TERMINAL'].map(name => Clutter.InputContentPurpose[name]);
    const names = ['COMPLETION', 'SPELLCHECK', 'AUTO_CAPITALIZATION', 'LOWERCASE',
        'UPPERCASE', 'TITLECASE'];
    const knownHints = names.reduce((mask, name) => mask | (Clutter.InputContentHintFlags[name] ?? 0), 0);
    if (!Number.isInteger(im.content_purpose) || !purposes.includes(im.content_purpose) ||
        !Number.isInteger(im.content_hints) || (im.content_hints & ~knownHints) !== 0)
        return null;
    return im.currentFocus;
}

export default class SnippetsExtension extends Extension {
    enable() {
        this._tickets = new Map();
        this._owner = null;
        // Keep epochs monotonic across disable/enable on the same extension.
        this._generation = (this._generation ?? 0) + 1;
        this._setupGeneration = (this._setupGeneration ?? 0) + 1;
        this._exported = Gio.DBusExportedObject.wrapJSObject(XML, this);
        this._exported.export(Gio.DBus.session, PATH);
        // Only the primary GTK application connection may issue commands. There
        // is no arbitrary window selector or generic input/clipboard endpoint.
        this._watch = Gio.bus_watch_name(Gio.BusType.SESSION, APP,
            Gio.BusNameWatcherFlags.NONE,
            (_connection, _name, owner) => {
                this._cancelOperations();
                this._owner = owner;
                this._generation++;
            }, () => {
                this._cancelOperations();
                this._owner = null;
                this._generation++;
            });
        this._focusSignal = global.display.connect('notify::focus-window', () => this._focusChanged());
        this._lockSignal = Main.screenShield.connect('active-changed', () => this._cancelOperations());
        this._modeSignal = Main.sessionMode.connect('updated', () => this._cancelOperations());
        this._overviewSignal = Main.overview.connect('showing', () => this._cancelOperations());
        this._sleepSignal = Gio.DBus.system.signal_subscribe('org.freedesktop.login1',
            'org.freedesktop.login1.Manager', 'PrepareForSleep', '/org/freedesktop/login1',
            null, Gio.DBusSignalFlags.NONE, () => this._cancelOperations());
        this._inputSignal = global.stage.connect('captured-event', (_stage, event) => {
            const type = event.type();
            if ([Clutter.EventType.KEY_PRESS, Clutter.EventType.BUTTON_PRESS,
                Clutter.EventType.TOUCH_BEGIN].includes(type)) {
                for (const [id, ticket] of this._tickets) {
                    if (!this._ready() || !this._appWindow(global.display.focus_window, ticket.pid))
                        this._tickets.delete(id);
                }
            }
            return Clutter.EVENT_PROPAGATE;
        });
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
            for (const [id, ticket] of this._tickets) {
                if (!this._valid(ticket))
                    this._tickets.delete(id);
            }
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        this._cancelOperations();
        this._generation++;
        this._owner = null;
        if (this._timer)
            GLib.source_remove(this._timer);
        if (this._watch)
            Gio.bus_unwatch_name(this._watch);
        if (this._focusSignal)
            global.display.disconnect(this._focusSignal);
        if (this._lockSignal)
            Main.screenShield.disconnect(this._lockSignal);
        if (this._modeSignal)
            Main.sessionMode.disconnect(this._modeSignal);
        if (this._inputSignal)
            global.stage.disconnect(this._inputSignal);
        if (this._overviewSignal)
            Main.overview.disconnect(this._overviewSignal);
        if (this._sleepSignal)
            Gio.DBus.system.signal_unsubscribe(this._sleepSignal);
        this._exported?.unexport();
        this._exported = null;
        this._timer = this._watch = this._focusSignal = this._lockSignal = this._modeSignal = this._inputSignal = this._overviewSignal = this._sleepSignal = 0;
    }

    _cancelOperations() {
        this._tickets?.clear();
        this._setupGeneration++;
    }

    _ready() {
        return this._exported && this._owner && !Main.screenShield.active &&
            !Main.sessionMode.isLocked && !Main.sessionMode.isGreeter && Main.sessionMode.hasWindows &&
            Main.actionMode === Shell.ActionMode.NORMAL;
    }

    _caller(invocation) {
        if (!this._ready() || invocation.get_sender() !== this._owner) {
            invocation.return_dbus_error('com.khm.Snippets.Unavailable', 'Snippets insertion is unavailable.');
            return false;
        }
        return true;
    }

    _appWindow(window, pid) {
        return window && window.get_pid() === pid;
    }

    _valid(ticket) {
        const now = GLib.get_monotonic_time();
        return this._ready() && ticket.owner === this._owner && ticket.generation === this._generation &&
            now >= ticket.created && now - ticket.created < LIFETIME_US &&
            ticket.window.get_compositor_private() !== null;
    }

    _get(id) {
        const ticket = this._tickets.get(id);
        if (!ticket || !this._valid(ticket)) {
            this._tickets.delete(id);
            return null;
        }
        return ticket;
    }

    _focusChanged() {
        this._setupGeneration++;
        const window = global.display.focus_window;
        for (const [id, ticket] of this._tickets) {
            if (!this._valid(ticket)) {
                this._tickets.delete(id);
            } else if (this._appWindow(window, ticket.pid)) {
                ticket.phase = 'panel';
            } else if (window === ticket.window) {
                if (ticket.phase === 'panel')
                    this._tickets.delete(id); // An unsolicited return cancels the pending insertion.
            } else if (window !== null) {
                this._tickets.delete(id);
            }
        }
    }

    EnableInputAsync(_parameters, invocation) {
        if (!this._caller(invocation))
            return;
        const owner = this._owner;
        const generation = this._generation;
        const setupGeneration = this._setupGeneration;
        const window = global.display.focus_window;
        // Setup is only accepted while the primary application's own window
        // has focus. A delayed PID reply must not apply after focus/owner loss.
        Gio.DBus.session.call('org.freedesktop.DBus', '/org/freedesktop/DBus',
            'org.freedesktop.DBus', 'GetConnectionUnixProcessID',
            new GLib.Variant('(s)', [owner]), new GLib.VariantType('(u)'),
            Gio.DBusCallFlags.NO_AUTO_START, 1000, null, (connection, result) => {
                let ok = false;
                try {
                    const [pid] = connection.call_finish(result).deep_unpack();
                    if (!this._ready() || owner !== this._owner || generation !== this._generation ||
                        this._setupGeneration !== setupGeneration || global.display.focus_window !== window || !pid || !this._appWindow(window, pid) ||
                        !IBusManager.getIBusManager().getEngineDesc('snippets'))
                        throw new Error('unavailable');
                    const settings = new Gio.Settings({schema_id: 'org.gnome.desktop.input-sources'});
                    const sources = settings.get_value('sources').deep_unpack();
                    if (!sources.some(([type, id]) => type === 'ibus' && id === 'snippets')) {
                        if (!settings.is_writable('sources') || sources.length >= 64 ||
                            !settings.set_value('sources', new GLib.Variant('a(ss)', [...sources, ['ibus', 'snippets']])))
                            throw new Error('unavailable');
                    }
                    const manager = Keyboard.getInputSourceManager();
                    const source = Object.values(manager.inputSources).find(s => s.type === 'ibus' && s.id === 'snippets');
                    // GSettings changes can arrive on the next main-loop tick.
                    // The caller may retry; no delayed Shell mutation is queued.
                    if (source) {
                        source.activate(true);
                        ok = manager.currentSource === source;
                    }
                } catch {
                    // Keep other sources and report the actual activation state.
                }
                invocation.return_value(new GLib.Variant('(b)', [ok]));
            });
    }

    CaptureAsync(_parameters, invocation) {
        if (!this._caller(invocation))
            return;
        const owner = this._owner;
        const generation = this._generation;
        const window = global.display.focus_window;
        const focus = ordinaryFocus();
        if (!window || !focus || window.get_gtk_application_id() === APP) {
            invocation.return_value(new GLib.Variant('(ss)', ['', '']));
            return;
        }
        Gio.DBus.session.call('org.freedesktop.DBus', '/org/freedesktop/DBus',
            'org.freedesktop.DBus', 'GetConnectionUnixProcessID',
            new GLib.Variant('(s)', [owner]), new GLib.VariantType('(u)'),
            Gio.DBusCallFlags.NO_AUTO_START, 1000, null, (connection, result) => {
                try {
                    const [pid] = connection.call_finish(result).deep_unpack();
                    if (!this._ready() || owner !== this._owner || generation !== this._generation ||
                        global.display.focus_window !== window || ordinaryFocus() !== focus || !pid || window.get_pid() === pid)
                        throw new Error('unavailable');
                    const label = window.get_wm_class() ?? '';
                    if (label.length > 256 || /[\x00-\x1f\x7f]/.test(label))
                        throw new Error('unavailable');
                    this._cancelOperations(); // At most one pending selection per primary application.
                    const id = GLib.uuid_string_random();
                    this._tickets.set(id, {window, focus, pid, owner, generation,
                        created: GLib.get_monotonic_time(), phase: 'captured'});
                    invocation.return_value(new GLib.Variant('(ss)', [id, label]));
                } catch {
                    invocation.return_value(new GLib.Variant('(ss)', ['', '']));
                }
            });
    }

    CheckAsync([id], invocation) {
        if (!this._caller(invocation))
            return;
        const ticket = this._get(id);
        invocation.return_value(new GLib.Variant('(bb)', [Boolean(ticket),
            Boolean(ticket && global.display.focus_window === ticket.window && ordinaryFocus() === ticket.focus)]));
    }

    FocusAsync([id], invocation) {
        if (!this._caller(invocation))
            return;
        const ticket = this._get(id);
        let ok = false;
        if (ticket && ['captured', 'panel'].includes(ticket.phase)) {
            try {
                ticket.phase = 'restoring';
                ticket.window.activate_with_workspace(global.get_current_time(), ticket.window.get_workspace());
                ok = true;
            } catch {
                this._tickets.delete(id);
            }
        }
        invocation.return_value(new GLib.Variant('(b)', [ok]));
    }

    CommitAsync([id, text], invocation) {
        if (!this._caller(invocation))
            return;
        const ticket = this._get(id);
        this._tickets.delete(id); // Single use, including all rejected attempts.
        const blockedModifiers = Clutter.ModifierType.CONTROL_MASK | Clutter.ModifierType.MOD1_MASK |
            Clutter.ModifierType.SUPER_MASK | Clutter.ModifierType.META_MASK;
        const modifiers = global.get_pointer()[2];
        let ok = Boolean(ticket && ticket.phase === 'restoring' &&
            global.display.focus_window === ticket.window && ordinaryFocus() === ticket.focus &&
            !(modifiers & blockedModifiers) && !text.includes('\0') &&
            new TextEncoder().encode(text).length <= 256 * 1024);
        if (ok) {
            try {
                // Use Mutter's input-method transport after the final window,
                // focus and privacy checks. Never synthesize arbitrary keys.
                Main.inputMethod.commit(text);
            } catch {
                ok = false;
            }
        }
        invocation.return_value(new GLib.Variant('(b)', [ok]));
    }

    ReleaseAsync([id], invocation) {
        if (!this._caller(invocation))
            return;
        this._tickets.delete(id);
        invocation.return_value(null);
    }
}
