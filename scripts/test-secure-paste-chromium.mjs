#!/usr/bin/env node
// Opt-in GUI regression. Requires Node 22+, Chrome and Accessibility permission.
// Uses only a disposable profile and local synthetic form; no real snippets,
// passwords, browser profile, clipboard or login submission is involved.
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const directory = await mkdtemp(join(tmpdir(), 'snippets-chromium-fixture-'));
const fixture = join(directory, 'fixture.html');
const driver = join(directory, 'driver');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
let browser;
let socket;
try {
    const compile = spawnSync('swiftc', ['-parse-as-library',
        'Tests/Integration/SecurePasteChromiumFixture.swift',
        'snippets/AXMessagingBudget.swift', 'snippets/SecurePasteTargetResolver.swift',
        '-o', driver], { cwd: repo, stdio: 'inherit', timeout: 60_000 });
    if (compile.status !== 0) throw new Error('Fixture compilation failed');
    await writeFile(fixture, `<!doctype html><meta charset=utf-8>
        <title>Snippets synthetic Chromium input</title>
        <p>Synthetic input only. No submission or network.</p>
        <input type=password id=password><input id=other>
        <script>window.model='';window.events=0;
        password.addEventListener('input',()=>{model=password.value;events++});</script>`);
    const fixtureURL = `file://${fixture}`;
    browser = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
        `--user-data-dir=${directory}/profile`, '--force-renderer-accessibility',
        '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
        '--use-mock-keychain', '--remote-debugging-port=0', `--app=${fixtureURL}`,
    ], { stdio: 'ignore' });
    browser.on('error', () => {});
    let port;
    for (let attempt = 0; attempt < 80; attempt++) {
        try {
            port = (await readFile(join(directory, 'profile/DevToolsActivePort'), 'utf8')).split('\n')[0];
            break;
        } catch {}
        await delay(100);
    }
    if (!port) throw new Error('Disposable Chrome instance did not start');
    let page;
    for (let attempt = 0; attempt < 80; attempt++) {
        const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
        page = pages.find(candidate => candidate.url === fixtureURL);
        if (page) break;
        await delay(100);
    }
    if (!page) throw new Error('Synthetic page unavailable');
    socket = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
    let nextID = 0;
    const requests = new Map();
    socket.onmessage = event => {
        const response = JSON.parse(event.data);
        requests.get(response.id)?.(response);
    };
    const call = (method, params = {}) => new Promise((resolve, reject) => {
        const id = ++nextID;
        const timeout = setTimeout(() => {
            requests.delete(id);
            reject(new Error('Synthetic page timed out'));
        }, 5_000);
        requests.set(id, response => {
            clearTimeout(timeout);
            requests.delete(id);
            resolve(response);
        });
        socket.send(JSON.stringify({ id, method, params }));
    });
    const evaluate = async expression => {
        const response = await call('Runtime.evaluate', { expression, returnByValue: true });
        if (response.error || response.result.exceptionDetails) throw new Error('Synthetic script failed');
        return response.result.result.value;
    };
    await call('Page.bringToFront');
    await delay(700);
    for (const [mode, length] of [
        ['container', 'short'], ['container', 'long'], ['focused', 'short'],
        ['bystander', 'short'], ['no-explicit', 'short'], ['redirect', 'short'],
    ]) {
        const text = length === 'long' ? 'synthetic-'.repeat(16) : 'synthetic-😀';
        await evaluate(`password.value='old';other.value='';model='old';events=0;
            password.focus();password.setSelectionRange(0,3);
            ${mode === 'focused' ? '' : mode === 'bystander' ? 'other.focus();' : 'password.blur();'}
            ${mode === 'redirect' ? "password.addEventListener('focus',()=>other.focus(),{once:true});" : ''}`);
        await delay(300);
        const result = spawnSync(driver, [String(browser.pid), fixture, mode, length],
            { stdio: 'inherit', timeout: 10_000 });
        if (result.status !== 0) throw new Error(`AX driver failed for ${mode} (${result.status})`);
        await delay(300);
        const refused = mode === 'bystander' || mode === 'no-explicit' || mode === 'redirect';
        const expected = JSON.stringify(refused ? 'old' : mode === 'container' ? 'old' + text : text);
        const matches = await evaluate(`password.value===${expected} && model===${expected}
            && other.value==='' && events===${refused ? 0 : 1}`);
        if (!matches) throw new Error(`Form model or bystander changed unexpectedly for ${mode}`);
        console.log(`PASS Chromium ${mode} ${length}: form model and bystander checked`);
    }
} finally {
    socket?.close();
    if (browser && browser.exitCode === null) {
        browser.kill('SIGTERM');
        for (let attempt = 0; attempt < 30 && browser.exitCode === null && browser.signalCode === null; attempt++) await delay(100);
        if (browser.exitCode === null && browser.signalCode === null) browser.kill('SIGKILL');
    }
    await rm(directory, { recursive: true, force: true });
}
