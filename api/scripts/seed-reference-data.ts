/**
 * Seeds the cost-validation reference dataset (docs/cost-model.md): 25 users x 100 = 2,500
 * alias records, marked synthetic=true. Rows are written to Table Storage ONLY; nothing is
 * queued, so no Exchange change is made. Use to measure storage size/transactions at scale.
 *
 *   STORAGE_ACCOUNT_NAME=<name> npx tsx scripts/seed-reference-data.ts            # seed
 *   STORAGE_ACCOUNT_NAME=<name> npx tsx scripts/seed-reference-data.ts --remove   # clean up
 *
 * Requires Storage Table Data Contributor for the signed-in identity (az login).
 */
import { TableClient, TransactionAction } from '@azure/data-tables';
import { DefaultAzureCredential } from '@azure/identity';

const account = process.env.STORAGE_ACCOUNT_NAME;
if (!account) throw new Error('Set STORAGE_ACCOUNT_NAME');
const remove = process.argv.includes('--remove');
const client = new TableClient(`https://${account}.table.core.windows.net`, 'aliases', new DefaultAzureCredential());

const USERS = 25;
const PER_USER = 100;

async function main() {
  for (let u = 0; u < USERS; u++) {
    const userId = `00000000-0000-0000-0000-${u.toString().padStart(12, '0')}`; // never a real object id
    const actions: TransactionAction[] = [];
    for (let i = 0; i < PER_USER; i++) {
      const address = `synthetic-${u}-${i}@reference.invalid`;
      actions.push(remove
        ? ['delete', { partitionKey: userId, rowKey: address }]
        : ['upsert', {
            partitionKey: userId, rowKey: address, address, domain: 'reference.invalid', status: i % 5 === 0 ? 'Removed' : 'Active',
            createdAt: new Date().toISOString(), note: 'synthetic reference workload', synthetic: true,
          }]);
    }
    await client.submitTransaction(actions); // one batch per partition (max 100 actions)
    process.stdout.write(`${remove ? 'removed' : 'seeded'} user ${u + 1}/${USERS}\r`);
  }
  console.log(`\nDone: ${USERS * PER_USER} rows ${remove ? 'removed' : 'seeded'}.`);
}

main().catch((e) => { console.error(e); process.exit(1); });
