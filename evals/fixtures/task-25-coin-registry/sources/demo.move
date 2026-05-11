module example::demo;

use sui::coin;
use sui::tx_context::TxContext;
use sui::transfer;
use std::option;

public struct DEMO has drop {}

// Uses the legacy coin::create_currency flow. The newer Coin Registry
// pattern is preferred for net-new coin modules.
// TODO: migrate this init to the Coin Registry pattern documented in
// `.sui-docs/snippets/coin-standards-migrate.mdx` (or wherever the
// migration guide lives). Remove the legacy create_currency call.
fun init(otw: DEMO, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency(
        otw,
        9,
        b"DEMO",
        b"Demo Coin",
        b"A demo currency",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury, ctx.sender());
}
