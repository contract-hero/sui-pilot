module example::vault;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::tx_context::TxContext;
use sui::transfer;

public struct Vault has key {
    id: UID,
    balance: Balance<SUI>,
}

public fun new(ctx: &mut TxContext): Vault {
    Vault { id: object::new(ctx), balance: balance::zero<SUI>() }
}

public fun share(v: Vault) {
    transfer::share_object(v);
}

// Per the spec in the eval prompt, add the following: an AdminCap; a
// per-address deposit ledger keyed on sender address; a withdraw flow
// that consumes the ledger entry (one-shot per deposit); an emergency
// pause toggle; and two events (Deposited / Withdrew). See the prompt
// for the full requirements, edge cases, and acceptance criteria.
public fun deposit(v: &mut Vault, coin: Coin<SUI>) {
    v.balance.join(coin.into_balance());
}

public fun withdraw(v: &mut Vault, amount: u64, ctx: &mut TxContext): Coin<SUI> {
    coin::take(&mut v.balance, amount, ctx)
}
