/// A monolithic module that mixes state types with entry functions.
/// The task is to split this into `state.move` (types + view fns) and
/// `entry.move` (the entry/public mutators), preserving the public API.
module example::protocol;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::tx_context::TxContext;
use sui::transfer;

// ---------- state ----------

public struct Pool has key {
    id: UID,
    balance: Balance<SUI>,
}

public struct LpReceipt has key, store {
    id: UID,
    amount: u64,
}

// ---------- view fns ----------

public fun balance(pool: &Pool): u64 {
    pool.balance.value()
}

public fun receipt_amount(r: &LpReceipt): u64 {
    r.amount
}

// ---------- entry fns ----------

public fun new(ctx: &mut TxContext): Pool {
    Pool { id: object::new(ctx), balance: balance::zero<SUI>() }
}

public fun share(pool: Pool) {
    transfer::share_object(pool);
}

public fun deposit(pool: &mut Pool, coin: Coin<SUI>, ctx: &mut TxContext): LpReceipt {
    let amount = coin.value();
    pool.balance.join(coin.into_balance());
    LpReceipt { id: object::new(ctx), amount }
}

public fun withdraw(pool: &mut Pool, r: LpReceipt, ctx: &mut TxContext): Coin<SUI> {
    let LpReceipt { id, amount } = r;
    id.delete();
    coin::take(&mut pool.balance, amount, ctx)
}
