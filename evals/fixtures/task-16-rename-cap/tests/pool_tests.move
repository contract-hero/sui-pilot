#[test_only]
module example::pool_tests;

use sui::test_scenario;
use example::auth::AdminCap;
use example::pool;

#[test]
fun test_set_value_with_admin() {
    let admin = @0xA;
    let mut scenario = test_scenario::begin(admin);
    let cap = AdminCap { id: object::new(scenario.ctx()) };

    let mut p = pool::new(&cap, scenario.ctx());
    pool::set_value(&mut p, &cap, 100);
    pool::share(p);

    let AdminCap { id } = cap;
    id.delete();
    scenario.end();
}
