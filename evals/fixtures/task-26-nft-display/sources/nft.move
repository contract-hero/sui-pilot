module example::nft;

use std::string::String;
use sui::package;

public struct Hero has key, store {
    id: UID,
    name: String,
    image_url: String,
    description: String,
}

public struct NFT has drop {}

fun init(otw: NFT, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);
    // TODO: configure a `sui::display::Display<Hero>` here with at least
    // `name`, `image_url`, and `description` keys mapped to the struct
    // fields, call `update_version`, and transfer both the Display and the
    // Publisher to the sender.
    transfer::public_transfer(publisher, ctx.sender());
}

public fun mint(name: String, image_url: String, description: String, ctx: &mut TxContext): Hero {
    Hero { id: object::new(ctx), name, image_url, description }
}
