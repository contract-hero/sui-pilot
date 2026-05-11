module example::messy;

use sui::tx_context::TxContext;
use sui::transfer;

// Inconsistent error constants: some PascalCase prefixed E, some ALL_CAPS.
const ENotAuthorized: u64 = 0;
const INVALID_AMOUNT: u64 = 1;
const ETooSmall: u64 = 2;

// Inconsistent struct names; mixes "Capability" / "Cap" / no suffix.
public struct Admin has key, store { id: UID }
public struct OperatorCapability has key, store { id: UID }
public struct ManagerCap has key, store { id: UID }

public struct User has key {
    id: UID,
    name: vector<u8>,
    bal: u64,
}

// Inconsistent getter shapes: get_X / X_value / X (the canonical one).
public fun get_name(u: &User): vector<u8> { u.name }
public fun bal_value(u: &User): u64 { u.bal }
public fun id(u: &User): &UID { &u.id }

// "Setter" pattern is non-idiomatic in Move — usually a mutable
// accessor is preferred. Keep one if it really makes sense; replace
// the rest with mutable accessors.
public fun setName(u: &mut User, name: vector<u8>) { u.name = name; }
public fun set_bal(u: &mut User, bal: u64) { u.bal = bal; }

public fun new(ctx: &mut TxContext): User {
    User { id: object::new(ctx), name: b"alice", bal: 0 }
}

public fun share_user(u: User) { transfer::share_object(u); }
