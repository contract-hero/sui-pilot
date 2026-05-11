module example::auth;

use sui::tx_context::TxContext;
use sui::transfer;

public struct AdminCap has key, store {
    id: UID,
}

fun init(ctx: &mut TxContext) {
    let cap = AdminCap { id: object::new(ctx) };
    transfer::transfer(cap, ctx.sender());
}

public fun admin_signature(_cap: &AdminCap): u64 {
    42
}
