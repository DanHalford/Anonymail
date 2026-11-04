import { RestError, TableClient } from '@azure/data-tables';
import { DefaultAzureCredential } from '@azure/identity';
import { QueueClient } from '@azure/storage-queue';
import { config } from './config';

/** Table names. Created by infra/main.bicep; created lazily only for local (Azurite) development. */
export const T = {
  aliases: 'aliases', // PK = user object id, RK = alias address
  aliasIndex: 'aliasindex', // PK = domain, RK = local part  -> uniqueness reservation (never reused)
  expiry: 'expiry', // PK = yyyymmdd expiry bucket, RK = alias address
  operations: 'operations', // PK = user object id, RK = operation id
  mailboxes: 'mailboxes', // PK = 'mbx', RK = user object id  -> cached eligibility/mailbox mapping
  usage: 'usage', // quota counters
  state: 'state', // worker lock
  audit: 'audit', // PK = yyyymm, RK = inverted ticks + id
  inboxRules: 'inboxrules', // PK = user object id, RK = folderKey  -> one worker-managed inbox rule per folder
} as const;
export type TableName = (typeof T)[keyof typeof T];

let credential: DefaultAzureCredential | undefined;
export function azureCredential(): DefaultAzureCredential {
  return (credential ??= new DefaultAzureCredential());
}

const tableClients = new Map<string, TableClient>();
const ensured = new Set<string>();

export async function table(name: TableName): Promise<TableClient> {
  const cfg = config();
  let client = tableClients.get(name);
  if (!client) {
    client = cfg.storageConnectionString
      ? TableClient.fromConnectionString(cfg.storageConnectionString, name, { allowInsecureConnection: true })
      : new TableClient(`https://${cfg.storageAccountName}.table.core.windows.net`, name, azureCredential());
    tableClients.set(name, client);
  }
  if (cfg.storageConnectionString && !ensured.has(name)) {
    await client.createTable();
    ensured.add(name);
  }
  return client;
}

let queueClient: QueueClient | undefined;
export async function opsQueue(): Promise<QueueClient> {
  const cfg = config();
  if (!queueClient) {
    queueClient = cfg.storageConnectionString
      ? new QueueClient(cfg.storageConnectionString, cfg.queueName)
      : new QueueClient(`https://${cfg.storageAccountName}.queue.core.windows.net/${cfg.queueName}`, azureCredential());
    if (cfg.storageConnectionString) await queueClient.createIfNotExists();
  }
  return queueClient;
}

export function isStatus(err: unknown, status: number): boolean {
  return err instanceof RestError && err.statusCode === status;
}

export async function getEntityOrUndefined<T extends object>(
  client: TableClient, pk: string, rk: string,
): Promise<(T & { etag: string; partitionKey: string; rowKey: string }) | undefined> {
  try {
    return (await client.getEntity<T>(pk, rk)) as T & { etag: string; partitionKey: string; rowKey: string };
  } catch (err) {
    if (isStatus(err, 404)) return undefined;
    throw err;
  }
}

/** OData string literal escaping for table filters. */
export function odata(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}
