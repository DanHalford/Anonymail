import { createHash } from 'node:crypto';
import { HttpError } from './http';

/**
 * Destination folder for an alias's mail, as a path of display names from the top of the
 * mailbox (e.g. ['Inbox', 'Shopping']). The worker keeps ONE inbox rule per (mailbox, folder)
 * and lists every alias for that folder in its conditions, so the number of rules grows with
 * folders, not aliases, and stays well inside the mailbox's inbox-rule quota.
 */
export interface FolderTarget {
  /** Exchange-style path relative to the mailbox root: segments joined with '\'. */
  path: string;
  /** Leaf folder name, used to name the rule: "Anonymail - Move to {name}". */
  name: string;
  /** Stable Table Storage key for the (case-insensitive) path. */
  key: string;
}

const MAX_DEPTH = 10;
const MAX_SEGMENT = 255;
// Control characters and the Exchange path separator can't appear in a single segment.
// eslint-disable-next-line no-control-regex
const BAD_SEGMENT = /[\u0000-\u001f\u007f\\]/;

export function folderKey(path: string): string {
  return createHash('sha256').update(path.toLowerCase(), 'utf8').digest('hex').slice(0, 32);
}

/** Validates folder path segments supplied by the SPA. Returns undefined when no folder was chosen. */
export function resolveFolder(segments: unknown): FolderTarget | undefined {
  if (segments === undefined || segments === null) return undefined;
  if (!Array.isArray(segments)) throw new HttpError(400, 'invalid_folder', 'Folder must be a list of folder names.');
  if (segments.length === 0) return undefined;
  if (segments.length > MAX_DEPTH) throw new HttpError(400, 'invalid_folder', `Folders can be at most ${MAX_DEPTH} levels deep.`);
  const clean = segments.map((s) => {
    if (typeof s !== 'string') throw new HttpError(400, 'invalid_folder', 'Folder names must be text.');
    // Not trimmed: Exchange folder names may legitimately start or end with spaces.
    const t = s;
    if (!t.trim() || t.length > MAX_SEGMENT || BAD_SEGMENT.test(t)) throw new HttpError(400, 'invalid_folder', 'That folder name is not supported.');
    return t;
  });
  const path = clean.join('\\');
  return { path, name: clean[clean.length - 1], key: folderKey(path) };
}

