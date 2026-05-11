import { client, getOwnedObjects } from './client.js';
import { buildTransfer, dryRun } from './transactions.js';

export async function transferAndDryRun(sender: string, recipient: string, amount: bigint) {
  const tx = await buildTransfer(recipient, amount);
  return dryRun(tx, sender);
}

export { client, getOwnedObjects };
