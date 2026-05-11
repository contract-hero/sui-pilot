import { TransactionBlock } from '@mysten/sui/transactions';
import { client } from './client.js';

export async function buildTransfer(recipient: string, amount: bigint) {
  const tx = new TransactionBlock();
  const coin = tx.splitCoins(tx.gas, [tx.pure.u64(amount)]);
  tx.transferObjects([coin], tx.pure.address(recipient));
  return tx;
}

export async function dryRun(tx: TransactionBlock, sender: string) {
  return client.dryRunTransactionBlock({
    transactionBlock: await tx.build({ client }),
  });
}
