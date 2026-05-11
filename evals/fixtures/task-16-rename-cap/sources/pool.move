module example::pool;

use sui::tx_context::TxContext;
use sui::transfer;
use example::auth::AdminCap;

public struct Pool has key {
    id: UID,
    value: u64,
}

public fun new(_cap: &AdminCap, ctx: &mut TxContext): Pool {
    Pool { id: object::new(ctx), value: 0 }
}

public fun set_value(pool: &mut Pool, _cap: &AdminCap, value: u64) {
    pool.value = value;
}

public fun share(pool: Pool) {
    transfer::share_object(pool);
}
