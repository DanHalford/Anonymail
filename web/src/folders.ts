/** A mail folder the user can send an alias's mail to; path is display names from the mailbox root. */
export interface MailFolder {
  path: string[];
  label: string;
}

const GRAPH = 'https://graph.microsoft.com/v1.0';
const SELECT = '$select=id,displayName,childFolderCount&$top=100';
const MAX_DEPTH = 5; // the API accepts up to 10; deeper trees are rare and slow to walk
const MAX_FOLDERS = 500;

interface GraphFolder { id: string; displayName: string; childFolderCount: number }
interface GraphPage { value: GraphFolder[]; '@odata.nextLink'?: string }

/**
 * Lists the signed-in user's own mail folders (depth-first, so children follow their parent).
 * Uses a delegated Mail.ReadBasic token, which covers folder names but never message content.
 */
export async function listMailFolders(token: string): Promise<MailFolder[]> {
  const out: MailFolder[] = [];
  const get = async (url: string): Promise<GraphPage> => {
    const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (!res.ok) throw new Error(`Could not read your folders (${res.status})`);
    return (await res.json()) as GraphPage;
  };
  const walk = async (url: string, parent: string[], depth: number): Promise<void> => {
    let next: string | undefined = url;
    while (next && out.length < MAX_FOLDERS) {
      const page = await get(next);
      for (const f of page.value) {
        if (out.length >= MAX_FOLDERS) return;
        const path = [...parent, f.displayName];
        out.push({ path, label: path.join(' › ') });
        if (f.childFolderCount > 0 && depth + 1 < MAX_DEPTH) {
          await walk(`${GRAPH}/me/mailFolders/${encodeURIComponent(f.id)}/childFolders?${SELECT}`, path, depth + 1);
        }
      }
      next = page['@odata.nextLink'];
    }
  };
  await walk(`${GRAPH}/me/mailFolders?${SELECT}`, [], 0);
  return out;
}
