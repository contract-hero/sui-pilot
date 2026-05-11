import { SuiClient } from '@mysten/sui/client';

const client = new SuiClient({ url: 'https://fullnode.mainnet.sui.io' });

export async function balanceOf(addr: string) {
  return client.getBalance({ owner: addr });
}

export async function ownedObjects(addr: string) {
  return client.getOwnedObjects({ owner: addr });
}
