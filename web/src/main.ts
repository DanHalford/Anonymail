import { Alias, Api, ApiError, Me } from './api';
import { InteractionRequiredAuthError } from '@azure/msal-browser';
import { Auth, RuntimeConfig } from './auth';
import { MailFolder, listMailFolders } from './folders';
import { StatusPoller } from './poll';

type Child = Node | string | null | undefined | false;

// Builds DOM nodes with textContent only, so alias notes and server messages are never parsed as HTML.
function h(tag: string, attrs: Record<string, string | ((e: Event) => void)> = {}, ...children: Child[]): HTMLElement {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (typeof v === 'function') el.addEventListener(k.replace(/^on/, ''), v);
    else el.setAttribute(k, v);
  }
  for (const c of children) if (c) el.append(c);
  return el;
}

const app = document.getElementById('app')!;
const accountBox = document.getElementById('account')!;
const PENDING = new Set(['Pending', 'Removing']);
// Keep polling until a new alias's folder rule has been applied too (same worker pass, moments later).
const busy = (a: Alias) => PENDING.has(a.status) || (a.status === 'Active' && a.ruleStatus === 'Pending');

let api: Api;
let auth: Auth;
let me: Me;
let aliases: Alias[] = [];
let message: { kind: 'error' | 'info'; text: string } | undefined;

/** Form state lives outside the DOM so re-renders never lose what the user typed or was offered. */
interface Draft {
  domain: string;
  suggestion?: string; // free random local part offered by the API
  suggesting: boolean;
  custom: boolean;
  customName: string;
  note: string;
  expiresOn: string; // yyyy-mm-dd in the user's time zone; '' = never
  folder: string; // index into folders, '' = leave in the Inbox
  busy: boolean;
}

/** The user's mail folders for the "Deliver to" picker; loaded once per page. */
type FolderState = { kind: 'idle' | 'loading' | 'consent' } | { kind: 'error'; message: string } | { kind: 'ready'; list: MailFolder[] };
let folders: FolderState = { kind: 'idle' };

async function loadFolders() {
  if (folders.kind === 'loading' || folders.kind === 'ready') return;
  folders = { kind: 'loading' };
  renderForm();
  try {
    folders = { kind: 'ready', list: await listMailFolders(await auth.graphToken()) };
  } catch (err) {
    folders = err instanceof InteractionRequiredAuthError ? { kind: 'consent' } : { kind: 'error', message: (err as Error).message };
  }
  renderForm();
}
let draft: Draft | undefined;
let suggestSeq = 0;

// Page regions, so status polling refreshes only the list and never disturbs the form.
const bannerEl = h('div');
const formEl = h('div');
const listEl = h('div');

const poller = new StatusPoller(async () => {
  aliases = await api.list();
  renderList();
  return aliases.some(busy);
});

const pad = (n: number) => String(n).padStart(2, '0');
const localDate = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const addDays = (n: number) => { const d = new Date(); d.setDate(d.getDate() + n); return d; };

/** End of the chosen day in the user's own time zone, with an explicit offset. */
function endOfDayIso(yyyyMmDd: string): string {
  const [y, m, d] = yyyyMmDd.split('-').map(Number);
  const off = -new Date(y, m - 1, d, 23, 59, 59).getTimezoneOffset();
  const sign = off >= 0 ? '+' : '-';
  return `${yyyyMmDd}T23:59:59${sign}${pad(Math.floor(Math.abs(off) / 60))}:${pad(Math.abs(off) % 60)}`;
}

async function newSuggestion() {
  if (!draft) return;
  const seq = ++suggestSeq;
  draft.suggestion = undefined;
  draft.suggesting = true;
  renderForm();
  try {
    const s = await api.suggest(draft.domain);
    if (seq === suggestSeq) draft.suggestion = s.localPart;
  } catch (err) {
    if (seq === suggestSeq) setMessage('error', err instanceof ApiError ? err.message : 'Could not get a suggestion.');
  } finally {
    if (seq === suggestSeq) { draft.suggesting = false; renderForm(); }
  }
}

function setMessage(kind: 'error' | 'info', text: string) {
  message = { kind, text };
  renderBanner();
}

async function boot() {
  const cfg = (await fetch('/config.json', { cache: 'no-cache' }).then((r) => r.json())) as RuntimeConfig;
  auth = await Auth.create(cfg);
  if (!auth.account) {
    app.replaceChildren(
      h('section', { class: 'card' },
        h('p', {}, 'Sign in with your organisation account. Passkeys work if your organisation has enabled them.'),
        h('button', { onclick: () => auth.signIn() }, 'Sign in')),
    );
    return;
  }
  accountBox.replaceChildren(h('span', {}, auth.account.name ?? auth.account.username), ' ',
    h('button', { class: 'link', onclick: () => auth.signOut() }, 'Sign out'));
  api = new Api(auth);
  await refresh();
}

async function refresh() {
  me = await api.me();
  aliases = me.eligible ? await api.list() : [];
  if (!me.eligible) {
    app.replaceChildren(h('section', { class: 'card' }, h('p', {}, `Your account is not eligible for aliases (${me.reason ?? 'unknown'}). Contact your administrator.`)));
    return;
  }
  if (!app.contains(formEl)) app.replaceChildren(bannerEl, formEl, listEl);
  const firstLoad = !draft;
  draft ??= {
    domain: me.domains[0], suggesting: false, custom: false, customName: '', note: '', folder: '', busy: false,
    // With a maximum lifetime configured there is no "never": default to the latest allowed date.
    expiresOn: me.maxAliasLifetimeDays > 0 ? localDate(addDays(me.maxAliasLifetimeDays - 1)) : '',
  };
  renderBanner();
  renderForm();
  renderList();
  if (firstLoad && me.creationEnabled) void newSuggestion();
  if (firstLoad && me.creationEnabled && me.allowFolderRules) void loadFolders();
  if (aliases.some(busy)) poller.start();
}

function renderBanner() {
  bannerEl.replaceChildren(...(message ? [h('p', { class: `banner ${message.kind}`, role: 'status' }, message.text)] : []));
}

function renderList() {
  listEl.replaceChildren(h('section', { class: 'card' },
    h('h2', {}, 'Your aliases'),
    h('p', { class: 'muted' }, `${me.quotas.active} of ${me.quotas.activeMax} active · ${me.quotas.today} of ${me.quotas.todayMax} created today`),
    aliases.length ? h('ul', { class: 'aliases' }, ...aliases.map(renderAlias)) : h('p', { class: 'muted' }, 'No aliases yet.')));
}

function renderForm() {
  if (!me.creationEnabled || !draft) {
    formEl.replaceChildren(h('section', { class: 'card' }, h('p', {}, 'Creating new aliases is paused. Your existing aliases keep receiving mail, and you can still remove them.')));
    return;
  }
  const d = draft;

  const domain = h('select', { name: 'domain', onchange: () => { d.domain = domain.value; if (!d.custom) void newSuggestion(); } },
    ...me.domains.map((x) => h('option', { value: x }, x))) as HTMLSelectElement;
  domain.value = d.domain;

  // Address: a checked-free random suggestion by default, which can be regenerated at will.
  const regenerate = h('button', { type: 'button', class: 'secondary', title: 'Get a different random address', onclick: () => void newSuggestion() }, 'New suggestion') as HTMLButtonElement;
  regenerate.disabled = d.suggesting || d.busy;
  let addressRow: HTMLElement;
  if (d.custom) {
    const name = h('input', { name: 'localPart', maxlength: '64', autocomplete: 'off', placeholder: 'your-chosen-name', oninput: () => { d.customName = name.value; } }) as HTMLInputElement;
    name.value = d.customName;
    addressRow = h('div', { class: 'row' },
      h('label', {}, 'Name', name),
      h('label', {}, 'Domain', domain),
      h('div', { class: 'address-actions' },
        h('button', { type: 'button', class: 'link', onclick: () => { d.custom = false; void newSuggestion(); } }, 'Use a random address')));
  } else {
    addressRow = h('div', { class: 'row' },
      h('div', { class: 'address' },
        h('span', { class: 'muted' }, 'Address'),
        h('code', {}, d.suggestion ? `${d.suggestion}@${d.domain}` : 'Finding a free address…')),
      h('label', {}, 'Domain', domain),
      h('div', { class: 'address-actions' },
        regenerate,
        me.allowCustomLocalPart ? h('button', { type: 'button', class: 'link', onclick: () => { d.custom = true; renderForm(); } }, 'Choose my own name') : null));
  }

  const note = h('input', { name: 'note', placeholder: 'e.g. online shop', maxlength: '200', oninput: () => { d.note = note.value; } }) as HTMLInputElement;
  note.value = d.note;

  const capped = me.maxAliasLifetimeDays > 0;
  const expires = h('input', {
    type: 'date', name: 'expiresOn', min: localDate(addDays(1)),
    ...(capped ? { max: localDate(addDays(me.maxAliasLifetimeDays - 1)), required: 'required' } : {}),
    oninput: () => { d.expiresOn = expires.value; },
  }) as HTMLInputElement;
  expires.value = d.expiresOn;

  let folderRow: HTMLElement | null = null;
  if (me.allowFolderRules) {
    let control: HTMLElement;
    if (folders.kind === 'ready') {
      const select = h('select', { name: 'folder', onchange: () => { d.folder = select.value; } },
        h('option', { value: '' }, "Inbox (don't move)"),
        ...folders.list.map((f, i) => h('option', { value: String(i) }, f.label))) as HTMLSelectElement;
      select.value = d.folder;
      control = select;
    } else if (folders.kind === 'consent') {
      control = h('button', { type: 'button', class: 'secondary', onclick: () => void auth.consentGraph() }, 'Allow access to my folder list');
    } else if (folders.kind === 'error') {
      control = h('span', { class: 'error-text' }, folders.message);
    } else {
      control = h('span', { class: 'muted' }, 'Loading your folders…');
    }
    folderRow = h('div', { class: 'row' },
      h('label', {}, 'Deliver to', control,
        h('span', { class: 'hint' }, 'Mail to this alias is moved to the folder by an "Anonymail - Move to …" rule in your mailbox.')));
  }

  const canSubmit = d.custom ? true : !!d.suggestion;
  const submit = h('button', { type: 'submit' }, d.busy ? 'Creating…' : 'Create alias') as HTMLButtonElement;
  submit.disabled = d.busy || !canSubmit;

  formEl.replaceChildren(h('form', {
    class: 'card',
    onsubmit: async (e: Event) => {
      e.preventDefault();
      const localPart = d.custom ? d.customName.trim() : d.suggestion;
      if (!localPart) return setMessage('error', d.custom ? 'Enter a name, or use a random address.' : 'Wait for a suggestion.');
      const folder = folders.kind === 'ready' && d.folder !== '' ? folders.list[Number(d.folder)]?.path : undefined;
      d.busy = true;
      renderForm();
      try {
        const res = await api.create({
          domain: d.domain,
          localPart,
          note: d.note.trim() || undefined,
          expiresAt: d.expiresOn ? endOfDayIso(d.expiresOn) : undefined,
          folder,
        });
        const until = res.alias.expiresAt ? ` It stops working after ${new Date(res.alias.expiresAt).toLocaleDateString()}.` : '';
        setMessage('info', `${res.alias.address} is being set up. It usually works within a few minutes.${until}`);
        d.note = '';
        d.customName = '';
        d.custom = false;
        d.busy = false;
        await refresh();
        void newSuggestion();
      } catch (err) {
        d.busy = false;
        setMessage('error', err instanceof ApiError ? err.message : 'Something went wrong.');
        // Someone took the suggestion in the meantime: offer a fresh one automatically.
        if (err instanceof ApiError && err.code === 'address_taken' && !d.custom) void newSuggestion();
        else renderForm();
      }
    },
  },
    h('h2', {}, 'New alias'),
    addressRow,
    h('div', { class: 'row' },
      h('label', {}, 'Note', note),
      h('label', {}, capped ? 'Expires on' : 'Expires on (leave blank for never)', expires,
        h('span', { class: 'hint' }, 'Stops working after the end of this day; removed overnight.'))),
    folderRow,
    submit));
}

function renderAlias(a: Alias): HTMLElement {
  const canRemove = a.status === 'Active' || a.status === 'RemoveFailed' || a.status === 'Failed';
  return h('li', { class: `alias ${a.status.toLowerCase()}` },
    h('div', {},
      h('code', {}, a.address),
      h('span', { class: 'badge' }, a.status),
      a.note ? h('div', { class: 'muted' }, a.note) : null,
      a.expiresAt ? h('div', { class: 'muted' }, `Expires ${new Date(a.expiresAt).toLocaleDateString()}`) : null,
      a.lastError ? h('div', { class: 'error-text' }, a.lastError) : null,
      renderFolder(a)),
    h('div', { class: 'actions' },
      a.status === 'Active' ? h('button', { class: 'link', onclick: () => navigator.clipboard.writeText(a.address) }, 'Copy') : null,
      canRemove ? h('button', {
        class: 'link danger',
        onclick: async () => {
          if (!confirm(`Remove ${a.address}? Mail sent to it will bounce.`)) return;
          try {
            await api.remove(a.address);
            setMessage('info', `${a.address} is being removed.`);
            await refresh();
          } catch (err) {
            setMessage('error', err instanceof ApiError ? err.message : 'Something went wrong.');
          }
        },
      }, 'Remove') : null));
}

/** Destination folder and the state of its inbox rule, while the alias is (or is becoming) live. */
function renderFolder(a: Alias): HTMLElement | null {
  if (!a.folderPath || a.status === 'Removed' || a.status === 'Failed') return null;
  const where = `Moved to ${a.folderPath.split('\\').join(' › ')}`;
  if (a.ruleStatus === 'Failed' || a.ruleStatus === 'Missing') {
    return h('div', { class: a.ruleStatus === 'Failed' ? 'error-text' : 'muted' }, `${where}: ${a.ruleError ?? 'rule not applied'}`);
  }
  return h('div', { class: 'muted' }, a.ruleStatus === 'Applied' ? where : `${where} (setting up the rule…)`);
}

boot().catch((err) => {
  app.replaceChildren(h('p', { class: 'banner error' }, `Could not start: ${(err as Error).message}`));
});
