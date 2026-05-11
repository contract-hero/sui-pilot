module example::pool;

use sui::tx_context::TxContext;
use sui::transfer;

public struct Pool has key {
    id: UID,
}

public struct Treasury has key, store {
    id: UID,
    balance: u64,
}

public fun new(ctx: &mut TxContext): Pool {
    Pool { id: object::new(ctx) }
}

public fun new_treasury(initial: u64, ctx: &mut TxContext): Treasury {
    Treasury { id: object::new(ctx), balance: initial }
}

public fun share(pool: Pool) {
    transfer::share_object(pool);
}

// TODO: attach the Treasury as a dynamic object field on Pool with the
// key b"treasury", and add a typed accessor `treasury(&Pool): &Treasury`
// (and a mutable variant) so callers can read/update the balance without
// re-implementing the dynamic-field plumbing.
