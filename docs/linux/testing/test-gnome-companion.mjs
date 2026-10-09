// Policy tests execute the extension's actual methods with a deterministic Shell.
// They complement real Mutter/GTK/Chromium tests; they do not qualify a desktop.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';
const file = fileURLToPath(new URL('../../../snippets-linux/gnome/snippets@wowlocal.github.io/extension.js', import.meta.url));
const source = fs.readFileSync(file, 'utf8').replace(/^import .*;\n/gm, '')
    .replace('export default class SnippetsExtension', 'globalThis.SnippetsExtension = class SnippetsExtension');
function signals(extra = {}) {
    const handlers = new Map();
    return Object.assign({
        connect(name, fn) { const id = handlers.size + 1; handlers.set(id, [name, fn]); return id; },
        disconnect(id) { handlers.delete(id); },
        emit(name, ...args) { for (const [n, fn] of handlers.values()) if (n === name) fn(this, ...args); },
    }, extra);
}
function fixture() {
    let time = 1000000, modifiers = 0, appeared, vanished, pending, defer = false;
    const committed = [];
    let sources = [['xkb', 'us'], ['xkb', 'ru']], engine = true, writable = true;
    const inputManager = {inputSources: {}, currentSource: null};
    const inputSource = {type: 'ibus', id: 'snippets', activate() {inputManager.currentSource = this;}};
    const focus = {is_focused: () => true};
    let formats = ['text/plain;charset=utf-8'], transfer, readCount = 0;
    const selection = signals({get_mimetypes: type => {assert.equal(type, 1); return formats;},
        transfer_async(type, mime, size, output, cancel, callback) {
            assert.equal(type, 1); assert.ok(formats.includes(mime)); assert.equal(size, 256 * 1024 + 1);
            readCount++; transfer = {output, cancel, callback};
        }, transfer_finish() {return true;}});
    const timers = new Map(); let nextTimer = 10;
    const display = signals({focus_window: null, get_selection: () => selection});
    const stage = signals();
    const Main = {
        screenShield: signals({active: false}),
        sessionMode: signals({isLocked: false, isGreeter: false, hasWindows: true}),
        overview: signals(), actionMode: 1,
        inputMethod: {currentFocus: focus, content_purpose: 0, content_hints: 0,
            commit(text) { committed.push(text); }},
    };
    function window(pid) {
        return {alive: true, get_pid: () => pid, get_gtk_application_id: () => null,
            get_wm_class: () => 'public.fixture', get_compositor_private() { return this.alive ? {} : null; },
            get_workspace() { return this; },
            activate_with_workspace(stamp, workspace) {
                assert.equal(stamp, 1); assert.equal(workspace, this);
                display.focus_window = this; Main.inputMethod.currentFocus = focus;
                display.emit('notify::focus-window');
            }};
    }
    const target = window(101), panel = window(42), other = window(102);
    display.focus_window = target;
    const connection = {call(...args) {
        const reply = () => args.at(-1)({call_finish: () => ({deep_unpack: () => [42]})}, {});
        if (defer) pending = reply; else reply();
    }};
    const Clutter = {
        InputContentPurpose: Object.fromEntries(['NORMAL', 'ALPHA', 'DIGITS', 'NUMBER', 'PHONE', 'URL', 'EMAIL', 'NAME', 'TERMINAL', 'PASSWORD'].map((n, i) => [n, i])),
        InputContentHintFlags: {COMPLETION: 1, SPELLCHECK: 2, AUTO_CAPITALIZATION: 4, LOWERCASE: 8, UPPERCASE: 16, TITLECASE: 32, SENSITIVE_DATA: 64, HIDDEN_TEXT: 128},
        EventType: {KEY_PRESS: 1, BUTTON_PRESS: 2, TOUCH_BEGIN: 3, KEY_RELEASE: 4},
        ModifierType: {CONTROL_MASK: 4, MOD1_MASK: 8, SUPER_MASK: 64, META_MASK: 128},
        EVENT_PROPAGATE: false,
    };
    let sequence = 0, sleep;
    const sandbox = {TextEncoder, Clutter, Main, Meta: {SelectionType: {SELECTION_CLIPBOARD: 1}},
        Keyboard: {getInputSourceManager: () => inputManager},
        IBusManager: {getIBusManager: () => ({getEngineDesc: () => engine ? {} : null})},
        Shell: {ActionMode: {NORMAL: 1}}, Extension: class {},
        global: {display, stage, get_pointer: () => [0, 0, modifiers], get_current_time: () => 1},
        GLib: {Variant: class {constructor(_type, value) { this.value = value; }}, VariantType: class {},
            get_monotonic_time: () => time, uuid_string_random: () => `ticket-${++sequence}`,
            timeout_add_seconds: () => 1, timeout_add(_priority, _duration, callback) {const id = nextTimer++; timers.set(id, callback); return id;}, source_remove(id) {timers.delete(id);}, PRIORITY_DEFAULT: 0, SOURCE_CONTINUE: true},
        Gio: {Cancellable: class {cancel() {this.cancelled = true;} is_cancelled() {return !!this.cancelled;}},
            MemoryOutputStream: {new_resizable: () => ({bytes: [], close() {}, get_data_size() {return this.bytes.length;}, steal_as_bytes() {return {get_data: () => this.bytes};}})},
            Settings: class {
                get_value() { return {deep_unpack: () => sources}; }
                is_writable() {return writable;}
                set_value(_key, value) {sources = value.value; inputManager.inputSources = {0: inputSource}; return true;}
            }, DBus: {session: connection, system: {signal_subscribe(...args) {sleep = args.at(-1); return 1;}, signal_unsubscribe() {}}},
            DBusExportedObject: {wrapJSObject: () => ({export() {}, unexport() {}})},
            BusType: {SESSION: 0}, BusNameWatcherFlags: {NONE: 0}, DBusCallFlags: {NO_AUTO_START: 0}, DBusSignalFlags: {NONE: 0},
            bus_watch_name(_type, _name, _flags, on, off) {appeared = on; vanished = off; on(null, null, ':1.42'); return 1;},
            bus_unwatch_name() {}},
    };
    vm.runInNewContext(source, sandbox, {filename: file});
    const extension = new sandbox.SnippetsExtension();
    extension.enable();
    const invoke = (method, args = [], sender = ':1.42') => {
        const reply = {};
        extension[`${method}Async`](args, {get_sender: () => sender,
            return_value(v) {reply.value = v?.value;}, return_dbus_error(name) {reply.error = name;}});
        return reply;
    };
    const capture = () => invoke('Capture').value?.[0];
    const switchTo = w => { display.focus_window = w; display.emit('notify::focus-window'); };
    return {extension, invoke, capture, switchTo, target, panel, other, Main, Clutter, committed,
        formats(value) {formats = value;}, readCount: () => readCount,
        clipboard(bytes) {transfer.output.bytes = bytes; transfer.callback(selection, {});},
        selectionChanged() {selection.emit('owner-changed', 1);},
        timeout() {for (const [id, callback] of [...timers]) {timers.delete(id); callback();}},
        sources: () => sources, inputManager, noEngine() {engine = false;}, readOnly() {writable = false;},
        key(type = 1) {stage.emit('captured-event', {type: () => type});},
        advance(us) {time += us;}, modifiers(value) {modifiers = value;},
        ownerGone() {vanished();}, ownerChanged() {appeared(null, null, ':1.99');}, sleep() {sleep();},
        defer() {defer = true;}, finish() {pending();}};
}
function selected(f) {const ticket = f.capture(); assert.ok(ticket); f.switchTo(f.panel); return ticket;}
{
    const f = fixture();
    assert.equal(f.invoke('Capture', [], ':1.666').error, 'com.khm.Snippets.Unavailable');
    assert.equal(f.extension._tickets.size, 0);
    const ticket = selected(f);
    assert.equal(f.invoke('Focus', [ticket]).value[0], true);
    assert.equal(f.invoke('Commit', [ticket, 'Public insertion']).value[0], true);
    assert.deepEqual(f.committed, ['Public insertion']);
    assert.equal(f.invoke('Commit', [ticket, 'Duplicate']).value[0], false);
}
for (const revoke of [
    f => f.switchTo(f.other), f => f.switchTo(f.target),
    f => {f.Main.screenShield.active = true; f.Main.screenShield.emit('active-changed'); f.Main.screenShield.active = false;},
    f => f.Main.overview.emit('showing'), f => f.sleep(), f => f.ownerGone(),
    f => f.ownerChanged(), f => {f.target.alive = false;}, f => f.advance(120000001),
    f => {f.extension.disable(); f.extension.enable();},
]) {
    const f = fixture(), ticket = selected(f); revoke(f);
    assert.notEqual(f.invoke('Focus', [ticket]).value?.[0], true);
    assert.notEqual(f.invoke('Commit', [ticket, 'Must not arrive']).value?.[0], true);
    assert.equal(f.committed.length, 0);
}
for (const modify of [
    f => {f.Main.inputMethod.content_purpose = f.Clutter.InputContentPurpose.PASSWORD;},
    f => {f.Main.inputMethod.content_hints = 64;}, f => {f.Main.inputMethod.content_hints = 128;},
    f => {f.Main.inputMethod.content_hints = 4096;}, f => {f.Main.inputMethod.content_purpose = 100;},
    f => {f.Main.inputMethod.currentFocus = null;},
]) {
    const f = fixture(); modify(f); assert.equal(f.capture(), '');
    const g = fixture(), ticket = selected(g);
    assert.equal(g.invoke('Focus', [ticket]).value[0], true);
    modify(g); assert.equal(g.invoke('Commit', [ticket, 'Rejected']).value[0], false);
    assert.equal(g.committed.length, 0);
}
for (const change of [f => f.switchTo(f.other), f => f.ownerChanged(), f => f.extension.disable(),
    f => {f.extension.disable(); f.extension.enable();}]) {
    const f = fixture(); f.defer(); const response = f.invoke('Capture'); change(f); f.finish();
    assert.equal(response.value[0], '');
}
for (const body of ['x\0y', 'é'.repeat(128 * 1024 + 1)]) {
    const f = fixture(), ticket = selected(f); f.invoke('Focus', [ticket]);
    assert.equal(f.invoke('Commit', [ticket, body]).value[0], false);
    assert.equal(f.committed.length, 0);
}
for (const modifier of [4, 8, 64, 128]) {
    const f = fixture(), ticket = selected(f); f.invoke('Focus', [ticket]); f.modifiers(modifier);
    assert.equal(f.invoke('Commit', [ticket, 'Rejected']).value[0], false);
}
{
    const f = fixture(), ticket = selected(f); f.invoke('Focus', [ticket]); f.key();
    assert.equal(f.invoke('Commit', [ticket, 'Interrupted']).value[0], false);
}
console.log('GNOME companion policy: identity, single use, focus, privacy, lock/sleep, restart and payload bounds passed');

{
    const f = fixture();
    assert.equal(f.invoke('EnableInput', [], ':1.666').error, 'com.khm.Snippets.Unavailable');
    assert.equal(f.invoke('EnableInput').value[0], false); // Another app has focus.
    f.switchTo(f.panel);
    assert.equal(f.invoke('EnableInput').value[0], true);
    assert.deepEqual(JSON.parse(JSON.stringify(f.sources())), [['xkb', 'us'], ['xkb', 'ru'], ['ibus', 'snippets']]);
    assert.equal(f.inputManager.currentSource.id, 'snippets');
    assert.equal(f.invoke('EnableInput').value[0], true);
    assert.equal(f.sources().length, 3);
}
for (const change of [f => f.switchTo(f.other), f => f.ownerChanged(),
    f => f.extension.disable(), f => {f.extension.disable(); f.extension.enable();}, f => f.noEngine(), f => f.readOnly(),
    f => {f.Main.screenShield.active = true;}, f => f.sleep(),
    f => {f.switchTo(f.other); f.switchTo(f.panel);},
    f => {f.Main.screenShield.emit('active-changed');}]) {
    const f = fixture(); f.switchTo(f.panel); f.defer();
    const response = f.invoke('EnableInput'); change(f); f.finish();
    assert.equal(response.value[0], false);
    assert.equal(f.sources().length, 2);
    assert.equal(f.inputManager.currentSource, null);
}
console.log('GNOME input setup: preserves sources, idempotent activation, owner/focus/lock and unavailable engine checks passed');

{
    const f = fixture();
    assert.equal(f.invoke('ReadClipboard', [], ':1.666').error, 'com.khm.Snippets.Unavailable');
    assert.equal(f.readCount(), 0);
    const response = f.invoke('ReadClipboard');
    assert.equal(f.invoke('ReadClipboard').value[0], false);
    f.clipboard([80, 117, 98]);
    assert.equal(response.value[0], true);
    assert.deepEqual(response.value[1], [80, 117, 98]);
}
for (const format of ['application/x-keepassxc', 'x-kde-passwordmanagerhint',
    'application/x-snippets-clipboard-history', 'text/uri-list', 'com.apple.is-sensitive', 'x'.repeat(257)]) {
    const f = fixture(); f.formats(['text/plain', format]);
    assert.equal(f.invoke('ReadClipboard').value[0], false);
    assert.equal(f.readCount(), 0);
}
for (const cancel of [f => f.selectionChanged(), f => f.switchTo(f.other),
    f => {f.switchTo(f.other); f.switchTo(f.target);}, f => f.ownerGone(),
    f => f.sleep(), f => f.Main.screenShield.emit('active-changed'),
    f => {f.extension.disable(); f.extension.enable();}, f => f.timeout(),
    f => f.advance(1500000),
    f => {f.Main.inputMethod.content_purpose = f.Clutter.InputContentPurpose.PASSWORD;}]) {
    const f = fixture(), response = f.invoke('ReadClipboard'); cancel(f);
    f.clipboard([80]); assert.equal(response.value[0], false); assert.equal(response.value[1].length, 0);
}
{
    const f = fixture(), response = f.invoke('ReadClipboard');
    f.clipboard(new Uint8Array(256 * 1024 + 1)); assert.equal(response.value[0], false);
    const g = fixture(); g.Main.inputMethod.content_purpose = g.Clutter.InputContentPurpose.PASSWORD;
    assert.equal(g.invoke('ReadClipboard').value[0], false); assert.equal(g.readCount(), 0);
}
console.log('GNOME clipboard: primary-only, bounded transfer, sensitive formats, single read and lifecycle cancellation passed');

{
    const f = fixture();
    assert.equal(f.invoke('ReadHistory', ['', []], ':1.666').error, 'com.khm.Snippets.Unavailable');
    const baseline = f.invoke('ReadHistory', ['', []]).value;
    assert.equal(baseline[1], false);
    f.selectionChanged();
    const response = f.invoke('ReadHistory', [baseline[0], []]);
    assert.equal(f.readCount(), 1);
    f.clipboard([80, 117, 98]);
    assert.equal(response.value[1], true);
    assert.deepEqual(response.value[2], [80, 117, 98]);
    assert.equal(f.invoke('ReadHistory', [response.value[0], []]).value[1], false);
    assert.equal(f.readCount(), 1);
    f.selectionChanged();
    assert.equal(f.invoke('ReadHistory', ['', []]).value[1], false); // A fresh collector skips existing text.
    assert.equal(f.readCount(), 1);
}
for (const excluded of [['public.fixture'], [' PUBLIC.FIXTURE '], ['x'.repeat(257)], Array(129).fill('public'), ['line\nbreak']]) {
    const f = fixture();
    const baseline = f.invoke('ReadHistory', ['', []]).value[0];
    f.selectionChanged();
    assert.equal(f.invoke('ReadHistory', [baseline, excluded]).value[1], false);
    assert.equal(f.readCount(), 0);
}
for (const change of [
    f => f.switchTo(f.other), f => {f.switchTo(f.other); f.switchTo(f.target);},
    f => f.advance(5000000), f => f.sleep(), f => f.Main.screenShield.emit('active-changed'),
    f => {f.extension.disable(); f.extension.enable();},
    f => {f.target.get_gtk_application_id = () => 'com.khm.snippets.linux';},
    f => {f.target.get_pid = () => 42;},
    f => {f.target.get_wm_class = () => null;},
    f => {f.Main.inputMethod.content_purpose = f.Clutter.InputContentPurpose.PASSWORD;},
    f => f.formats(['text/plain', 'application/x-keepassxc']),
]) {
    const f = fixture();
    const baseline = f.invoke('ReadHistory', ['', []]).value[0];
    f.selectionChanged(); change(f);
    assert.equal(f.invoke('ReadHistory', [baseline, []]).value[1], false);
    assert.equal(f.readCount(), 0);
}
for (const change of [f => f.selectionChanged(), f => f.switchTo(f.other), f => f.ownerChanged(),
    f => f.sleep(), f => f.extension.disable(), f => {f.target.get_wm_class = () => 'changed.fixture';}]) {
    const f = fixture();
    const baseline = f.invoke('ReadHistory', ['', []]).value[0];
    f.selectionChanged(); f.defer();
    const reply = f.invoke('ReadHistory', [baseline, []]); change(f); f.finish();
    assert.equal(reply.value[1], false);
    assert.equal(f.readCount(), 0);
}
{
    const f = fixture();
    const baseline = f.invoke('ReadHistory', ['', []]).value[0];
    f.selectionChanged();
    const reply = f.invoke('ReadHistory', [baseline, []]);
    f.selectionChanged(); f.clipboard([80]);
    assert.equal(reply.value[1], false);
    assert.equal(reply.value[2].length, 0);
}
{
    const f = fixture();
    f.selectionChanged();
    assert.equal(f.invoke('ReadHistory', ['unknown-before-collection', []]).value[1], false);
    assert.equal(f.readCount(), 0);
    const cursor = f.invoke('ReadHistory', ['', []]).value[0];
    f.advance(2000000);
    f.selectionChanged(); // A stopped collector no longer admits source metadata.
    assert.equal(f.invoke('ReadHistory', [cursor, []]).value[1], false);
    assert.equal(f.readCount(), 0);
}
console.log('GNOME history protocol: initial baseline, source exclusions, privacy, expiry and deferred-read revocation passed');
