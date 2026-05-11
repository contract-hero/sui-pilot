module example::pool;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::tx_context::TxContext;
use sui::transfer;

public struct Pool has key {
    id: UID,
    balance: Balance<SUI>,
}

public fun new(ctx: &mut TxContext): Pool {
    Pool { id: object::new(ctx), balance: balance::zero<SUI>() }
}

public fun share(pool: Pool) {
    transfer::share_object(pool);
}

public fun deposit(pool: &mut Pool, coin: Coin<SUI>) {
    pool.balance.join(coin.into_balance());
}

// Currently withdraw returns the full requested amount with no fee.
// Add a withdraw fee mechanism. Implementation choices are up to you —
// document the trade-offs in comments.
public fun withdraw(pool: &mut Pool, amount: u64, ctx: &mut TxContext): Coin<SUI> {
    coin::take(&mut pool.balance, amount, ctx)
}
