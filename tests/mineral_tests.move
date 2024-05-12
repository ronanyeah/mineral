#[test_only]
module mineral::mineral_tests {
    use sui::bcs;
    use sui::balance;
    use sui::clock;
    use sui::test_utils::assert_eq;
    use sui::coin::{Self, Coin};
    use time_locked_balance::locker as tlb;
    use mineral::miner::{register, Miner};
    use mineral::mine::{
        Self, mine, Config, Bus,
        epoch_reset
    };

    use fun assert_value as coin::Coin.assert_value;

    const ONE_MINUTE: u64 = 60_000;
    const ONE_DAY: u64 = ONE_MINUTE * 1440;

    const ETestFail: u64 = 1;

    // Nonces to be used alongside mock_hash() + generate_proof()
    const MOCK_NONCE: u64 = 111;
    const NONCE_DIFFICULTY_2: u64 = 10129;
    const NONCE_DIFFICULTY_3: u64 = 13780591;
    const NONCE_DIFFICULTY_4: u64 = 535698351;

    const SIGNER: address = @0xFADE;

    #[test]
    fun test_hash() {
        let r2 = mine::generate_proof_pub(mock_hash(), SIGNER, NONCE_DIFFICULTY_2);
        mine::validate_proof_pub(r2, 2);
        let r3 = mine::generate_proof_pub(mock_hash(), SIGNER, NONCE_DIFFICULTY_3);
        mine::validate_proof_pub(r3, 3);
        let r4 = mine::generate_proof_pub(mock_hash(), SIGNER, NONCE_DIFFICULTY_4);
        mine::validate_proof_pub(r4, 4);
    }

    #[test, expected_failure(abort_code = mineral::mine::EInsufficientDifficulty)]
    fun test_mock_hash_fail() {
        let res = mine::generate_proof_pub(mock_hash(), SIGNER, MOCK_NONCE);
        mine::validate_proof_pub(res, 1);
    }

    #[test, expected_failure(abort_code = mineral::mine::EInsufficientDifficulty)]
    fun test_insufficient_diff_fail() {
        let r4 = mine::generate_proof_pub(mock_hash(), SIGNER, NONCE_DIFFICULTY_4);
        mine::validate_proof_pub(r4, 4);
        mine::validate_proof_pub(r4, 5);
    }

    #[test]
    public fun test_difficulty_grading() {
        use mineral::mine::calculate_difficulty_pub as calc;

        let initial_difficulty = mine::get_initial_difficulty();
        let total_supply = mine::get_supply();
        let billion = 1_000_000_000;

        let mut hashes = 0;
        assert!(calc(hashes) == initial_difficulty, ETestFail);

        hashes = billion;
        let mut difficulty_bump = 1;

        assert!(calc(hashes - 1) == initial_difficulty, ETestFail);
        assert!(calc(hashes) == (initial_difficulty + difficulty_bump), ETestFail);

        hashes = hashes + (billion * 2);
        // Total hashes cannot be greater than total units of supply
        while (hashes < total_supply) {
            assert!(calc(hashes - 1) == (initial_difficulty + difficulty_bump), ETestFail);
            assert!(
                calc(hashes) ==
                    (initial_difficulty + (difficulty_bump + 1)),
                ETestFail
            );

            difficulty_bump = difficulty_bump + 1;
            hashes = hashes + (billion * sui::math::pow(2, difficulty_bump));
        };

        assert!(calc(total_supply) == (initial_difficulty + difficulty_bump), ETestFail);
    }

    #[test]
    public fun test_reset() {
        use sui::test_scenario as ts;

        let mut test = ts::begin(SIGNER);

        let mut clock = clock::create_for_testing(test.ctx());
        clock.set_for_testing(mine::get_epoch_duration() + ONE_DAY);

        let bus_epoch_rewards = mine::get_bus_epoch_rewards();

        test.next_tx(SIGNER);
        {
            let ctx = test.ctx();
            mine::init_for_testing(ctx);
        };

        test.next_tx(SIGNER);
        {
            let mut config = test.take_shared<Config>();

            let battery = get_buses(&test);

            epoch_reset(&mut config, battery, &clock, test.ctx());

            ts::return_shared(config);
        };

        test.next_tx(SIGNER);
        {
            let battery = get_buses(&test);
            let mut index = 0;
            while (index < battery.length()) {
                let bus = battery.borrow(index);
                assert!(balance::value(bus.rewards()) == bus_epoch_rewards, ETestFail);
                index = index + 1;
            };
            release_buses(battery);
        };

        clock.destroy_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = mineral::mine::EInsufficientDifficulty)]
    public fun test_bad_hash() {
        use sui::test_scenario as ts;

        let mut test = ts::begin(SIGNER);
        let mut clock = clock::create_for_testing(test.ctx());

        create_start(SIGNER, &mut test, &mut clock);

        let mut miner = test.take_from_sender<Miner>();
        let mut bus = test.take_shared<Bus>();
        let reward = mine(MOCK_NONCE, &mut bus, &mut miner, &clock, test.ctx());

        reward.assert_value(bus.reward_rate());
        ts::return_shared(bus);
        test.return_to_sender(miner);

        clock.destroy_for_testing();
        test.end();
    }

    #[test]
    public fun test_smoke() {
        use sui::test_scenario as ts;

        let mut test = ts::begin(SIGNER);
        let mut clock = clock::create_for_testing(test.ctx());

        create_start(SIGNER, &mut test, &mut clock);

        let bus_epoch_rewards = mine::get_bus_epoch_rewards();

        test.next_tx(SIGNER);
        {
            let config = test.take_shared<Config>();

            let max_withdrawable = tlb::max_withdrawable(config.treasury(), &clock);
            assert!(max_withdrawable == 0, ETestFail);

            ts::return_shared(config);
        };

        test.next_tx(SIGNER);
        {
            let mut miner = test.take_from_sender<Miner>();
            let mut bus = test.take_shared<Bus>();
            let config = test.take_shared<Config>();

            let ctx = test.ctx();
            let reward = mine(NONCE_DIFFICULTY_3, &mut bus, &mut miner, &clock, ctx);

            let reward_rate = bus.reward_rate();
            assert!(balance::value(bus.rewards()) == bus_epoch_rewards - reward_rate, ETestFail);
            assert!(coin::value(&reward) == reward_rate, ETestFail);
            assert!(miner.total_rewards() == reward_rate, ETestFail);

            reward.assert_value(reward_rate);
            ts::return_shared(config);
            ts::return_shared(bus);
            test.return_to_sender(miner);
        };

        clock.destroy_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = mineral::mine::EInsufficientDifficulty)]
    public fun test_smoke_fail() {
        use sui::test_scenario as ts;

        let mut test = ts::begin(SIGNER);
        let mut clock = clock::create_for_testing(test.ctx());

        create_start(SIGNER, &mut test, &mut clock);

        test.next_tx(SIGNER);
        {
            let mut miner = test.take_from_sender<Miner>();
            let mut bus = test.take_shared<Bus>();
            let config = test.take_shared<Config>();

            let ctx = test.ctx();
            let reward = mine(NONCE_DIFFICULTY_2, &mut bus, &mut miner, &clock, ctx);

            reward.assert_value(bus.reward_rate());
            ts::return_shared(config);
            ts::return_shared(bus);
            test.return_to_sender(miner);
        };

        clock.destroy_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = mineral::mine::EInsufficientBuses)]
    public fun test_missing_buses() {
        use sui::test_scenario as ts;

        let mut test = ts::begin(SIGNER);
        let clock = clock::create_for_testing(test.ctx());

        test.next_tx(SIGNER);
        {
            let ctx = test.ctx();
            mine::init_for_testing(ctx);
        };

        test.next_tx(SIGNER);
        {
            let mut config = test.take_shared<Config>();

            let battery = vector::singleton(test.take_shared<Bus>());

            let ctx = test.ctx();
            epoch_reset(&mut config, battery, &clock, ctx);

            ts::return_shared(config);
        };

        clock.destroy_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = mineral::mine::EMiningHasEnded)]
    public fun test_endgame_reset() {
        use sui::test_scenario as ts;

        let mut test = ts::begin(SIGNER);
        let mut clock = clock::create_for_testing(test.ctx());
        create_endgame(SIGNER, &mut test, &mut clock);

        test.next_tx(SIGNER);
        let mut config = test.take_shared<Config>();
        let battery = get_buses(&test);
        epoch_reset(&mut config, battery, &clock, test.ctx());

        ts::return_shared(config);
        clock.destroy_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = mineral::mine::EMiningHasEnded)]
    public fun test_endgame_mine() {
        use sui::test_scenario as ts;

        let mut test = ts::begin(SIGNER);
        let mut clock = clock::create_for_testing(test.ctx());
        create_endgame(SIGNER, &mut test, &mut clock);

        test.next_tx(SIGNER);
        let mut bus = test.take_shared<Bus>();
        let mut miner = test.take_from_sender<Miner>();
        let reward = mine(MOCK_NONCE, &mut bus, &mut miner, &clock, test.ctx());

        reward.assert_value(bus.reward_rate());
        test.return_to_sender(miner);
        ts::return_shared(bus);
        clock.destroy_for_testing();
        test.end();
    }

    #[test]
    public fun test_drain() {
        use sui::test_scenario as ts;

        let mut test = ts::begin(SIGNER);
        let mut clock = clock::create_for_testing(test.ctx());
        create_endgame(SIGNER, &mut test, &mut clock);

        test.next_tx(SIGNER);
        // Assert correct config and bus values
        {
            let initial_difficulty = mine::get_initial_difficulty();

            let config = test.take_shared<Config>();
            let miner = test.take_from_sender<Miner>();

            {
                let battery = get_buses(&test);
                let mut index = 0;
                while (index < battery.length()) {
                    let bus = battery.borrow(index);
                    assert!(balance::value(bus.rewards()) == 0, ETestFail);
                    assert!(!bus.live(), ETestFail);
                    assert!(bus.difficulty() == (initial_difficulty + 1), ETestFail);
                    index = index + 1;
                };
                release_buses(battery);
            };

            let total_supply = mine::get_supply();
            assert_treasury_empty(&config, &clock);
            assert!(miner.total_rewards() == total_supply, ETestFail);
            assert!(config.total_rewards() == total_supply, ETestFail);
            assert!(miner.total_hashes() == config.total_hashes(), ETestFail);

            test.return_to_sender(miner);
            ts::return_shared(config);
        };

        clock.destroy_for_testing();
        test.end();
    }

    fun create_start(signer: address, test: &mut sui::test_scenario::Scenario, clock: &mut clock::Clock) {
        // 1. initialise module
        // 2. initial epoch_reset
        // 3. create miner object
        // 4. reset miner current hash to mock value

        use sui::test_scenario as ts;

        test.next_tx(signer);
        {
            let ctx = test.ctx();
            mine::init_for_testing(ctx);
        };

        test.next_tx(signer);
        // INITIAL EPOCH RESET
        {
            // simulate 0 -> 24hr diff for first epoch_reset
            clock.increment_for_testing(ONE_DAY);
            let mut config = test.take_shared<Config>();

            let battery = get_buses(test);

            let ctx = test.ctx();
            epoch_reset(&mut config, battery, clock, ctx);

            ts::return_shared(config);
        };

        test.next_tx(signer);
        {
            register(test.ctx());
        };

        test.next_tx(signer);
        {
            let mut miner = test.take_from_sender<Miner>();
            miner.reset_hash();
            test.return_to_sender(miner);
        };

        test.next_tx(signer);
    }

    fun create_endgame(signer: address, test: &mut sui::test_scenario::Scenario, clock: &mut clock::Clock) {
        use sui::test_scenario as ts;

        create_start(signer, test, clock);

        test.next_tx(signer);
        // ADVANCE CLOCK
        {
            let mut config = test.take_shared<Config>();
            let mut miner = test.take_from_sender<Miner>();
            let ctx = test.ctx();

            let burn = mine::simulate_claims(&mut miner, &mut config, clock);

            coin::burn_for_testing(coin::from_balance(burn, ctx));

            ts::return_shared(config);
            test.return_to_sender(miner);
        };

        test.next_tx(signer);
        // Reset epoch after fast forward
        {
            let mut config = test.take_shared<Config>();

            let battery = get_buses(test);

            let ctx = test.ctx();
            epoch_reset(&mut config, battery, clock, ctx);

            ts::return_shared(config);
        };

        test.next_tx(signer);
        // Fast-forward should trigger a difficulty increase
        {
            let initial_difficulty = mine::get_initial_difficulty();
            let bus = test.take_shared<Bus>();
            assert!(bus.difficulty() == (initial_difficulty + 1), ETestFail);
            ts::return_shared(bus);
        };

        let mut current_miner = 0;
        let mut exit = false;
        while (!exit) {
            test.next_tx(signer);
            // Run mines + resets until treasury is drained
            {
                let mut miner = test.take_from_sender<Miner>();
                let mut battery = get_buses(test);
                let bus = battery.borrow_mut(current_miner);
                let config = test.take_shared<Config>();
                let ctx = test.ctx();

                let reward = mine(NONCE_DIFFICULTY_4, bus, &mut miner, clock, ctx);

                miner.reset_hash();

                reward.assert_value(bus.reward_rate());
                release_buses(battery);
                ts::return_shared(config);
                test.return_to_sender(miner);
            };

            clock.increment_for_testing(mine::get_epoch_duration() + 1);

            test.next_tx(signer);
            {
                let mut config = test.take_shared<Config>();

                let battery = get_buses(test);

                let ctx = test.ctx();
                epoch_reset(&mut config, battery, clock, ctx);

                ts::return_shared(config);
            };

            {
                test.next_tx(signer);
                let bus = test.take_shared<Bus>();
                if (!bus.live()) {
                    exit = true;
                };
                ts::return_shared(bus);
            };

            if (current_miner == 7) {
                current_miner = 0;
            } else {
                current_miner = current_miner + 1;
            }
        };

        test.next_tx(signer);
        // Run final mines on all buses
        {
            let mut battery = get_buses(test);
            let mut index = 0;
            while (index < battery.length()) {
                let bus = battery.borrow_mut(index);

                if (balance::value(bus.rewards()) > 0) {
                    let mut miner = test.take_from_sender<Miner>();
                    let ctx = test.ctx();

                    let reward = mine(MOCK_NONCE, bus, &mut miner, clock, ctx);

                    coin::burn_for_testing(reward);
                    test.return_to_sender(miner);
                };

                index = index + 1;
            };
            release_buses(battery);
        };
    }

    fun assert_treasury_empty(
        config: &Config,
        clock: &clock::Clock
    ) {
        let treasury = config.treasury();
        assert!(tlb::extraneous_locked_amount(treasury) == 0, ETestFail);
        assert!(tlb::max_withdrawable(treasury, clock) == 0, ETestFail);
        assert!(tlb::remaining_unlock(treasury, clock) == 0, ETestFail);
    }

    fun get_buses(scenario: &sui::test_scenario::Scenario): vector<Bus> {
        let mut xs = vector[];
        while (xs.length() < mine::get_initial_bus_count()) {
            let bus = scenario.take_shared<Bus>();
            xs.push_back(bus);
        };
        xs
    }

    fun release_buses(mut battery: vector<Bus>) {
        while (!battery.is_empty()) {
            let bus = battery.pop_back();
            sui::test_scenario::return_shared(bus);
        };
        battery.destroy_empty();
    }

    fun assert_value(coin: Coin<mine::MINE>, value: u64) {
        assert_eq(coin::burn_for_testing(coin), value);
    }

    fun mock_hash(): vector<u8> {
        sui::hash::keccak256(&bcs::to_bytes(&0))
    }
}
