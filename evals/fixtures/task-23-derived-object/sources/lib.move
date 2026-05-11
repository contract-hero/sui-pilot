module example::registry;

use sui::tx_context::TxContext;
use sui::transfer;

public struct Registry has key {
    id: UID,
}

public struct Entry has key, store {
    id: UID,
    payload: u64,
}

public fun new(ctx: &mut TxContext): Registry {
    Registry { id: object::new(ctx) }
}

public fun share(r: Registry) {
    transfer::share_object(r);
}

// TODO: expose `claim_entry(registry: &mut Registry, key: u64, payload: u64, ctx)`
// that creates an Entry whose UID is deterministically derived from
// (registry.id, key) using `sui::derived_object`. Two callers passing the
// same (registry, key) must abort instead of producing two different
// Entries. Read .sui-docs/develop/objects/derived-objects.mdx for the
// current API shape before implementing.
