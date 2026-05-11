#[test_only]
module example::pool_tests;

use sui::test_scenario;
use example::pool::{Self, Pool, Treasury};

#[test]
fun test_treasury_accessor() {
    let user = @0xA;
    let mut scenario = test_scenario::begin(user);

    let _p = pool::new(scenario.ctx());
    let _t = pool::new_treasury(1_000, scenario.ctx());
    // TODO: attach _t onto _p as a dynamic object field, then assert that
    // pool::treasury(&_p).balance == 1_000. Until the accessor exists,
    // we abort here so the test exposes the gap.
    abort 0
}
