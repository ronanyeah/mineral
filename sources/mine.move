module mineral::mine {

    // === Imports ===

    use sui::balance;
    use sui::bcs;
    use sui::clock;
    use sui::coin;
    use sui::hash;
    use sui::math;
    use time_locked_balance::locker as tlb;
    use mineral::miner::Miner;

    // === Errors ===

    const ERewardsExhausted: u64 = 4001;
    const ENeedsReset: u64 = 4002;
    const EResetTooEarly: u64 = 4003;
    const EInsufficientDifficulty: u64 = 4004;
    const EInsufficientBuses: u64 = 4005;
    const EVestingInProgress: u64 = 4006;
    const EMiningHasEnded: u64 = 4007;
    const EMiningNotStarted: u64 = 4008;

    // === Constants ===

    const TOTAL_SUPPLY: u64 = 21_000_000 * UNIT;

    const UNIT: u64 = 1_000_000_000;
    const DECIMALS: u8 = 9;

    const EPOCH_DURATION: u64 = ONE_MINUTE;
    const TARGET_EPOCH_REWARDS: u64 = UNIT;
    const MAX_EPOCH_REWARDS: u64 = TARGET_EPOCH_REWARDS * 2;

    const INITIAL_BUS_COUNT: u64 = 8;
    const INITIAL_DIFFICULTY: u8 = 3;

    const ONE_MINUTE: u64 = 60_000;
    const ONE_DAY: u64 = ONE_MINUTE * 1440;

    const VERSION: u8 = 0;

    // === Structs ===

    public struct Config has key {
        id: UID,
        version: u8,
        bus_count: u64,
        treasury: tlb::Locker<MINE>,
        last_difficulty_adjustment: u64,
        total_rewards: u64,
        total_hashes: u64,
    }

    public struct Bus has key {
        id: UID,
        version: u8,
        live: bool,
        difficulty: u8,
        reward_rate: u64,
        last_reset: u64,
        rewards: balance::Balance<MINE>,
        epoch_hashes: u64,
    }

    public struct MINE has drop {}

    public struct AdminCap has store, key {
        id: UID,
    }

    // === Init ===

    // After 'init', an 'epoch_reset' is needed to start the mining process.
    // This can be done when the treasury begins vesting,
    // which is 24 hours after the start of the 'init' epoch.
    fun init(witness: MINE, ctx: &mut TxContext) {
        let (mut treasury_cap, metadata) = coin::create_currency(
            witness, DECIMALS, b"MINE", b"Mineral", b"Algorithmic resource mining.",
            option::some(mineral::icon::get_icon_url()), ctx
        );

        let mut total_mint = coin::into_balance(
            coin::mint(&mut treasury_cap, TOTAL_SUPPLY, ctx)
        );

        {
            // Transfer mint authority to metadata object and freeze
            transfer::public_transfer(
                treasury_cap,
                sui::object::id_address(&metadata)
            );
            transfer::public_freeze_object(metadata);
        };

        // Remove enough from the treasury to fill the buses
        let mut initial_bus_rewards = total_mint.split(MAX_EPOCH_REWARDS);

        let bus_epoch_rewards_allocation = MAX_EPOCH_REWARDS / INITIAL_BUS_COUNT;
        let initial_reward_rate = TARGET_EPOCH_REWARDS / 1_000_000;

        let mut buses = 0;
        while (buses < INITIAL_BUS_COUNT) {
            let bus = Bus {
                id: object::new(ctx),
                version: VERSION,
                live: true,
                difficulty: INITIAL_DIFFICULTY,
                reward_rate: initial_reward_rate,
                rewards: initial_bus_rewards.split(bus_epoch_rewards_allocation),
                // Each bus will require an 'epoch_reset' to enable mining
                last_reset: 0,
                epoch_hashes: 0,
            };
            transfer::share_object(bus);
            buses = buses + 1;
        };
        initial_bus_rewards.destroy_zero();

        let epoch_start = ctx.epoch_timestamp_ms();
        let treasury_vesting_start_time_sec = (epoch_start + ONE_DAY) / 1000;

        let treasury_release_per_second = {
            // Treasury releases MAX_EPOCH_REWARDS per minute
            // Pad MAX_EPOCH_REWARDS to divide evenly by 60
            let padding = 60 - (MAX_EPOCH_REWARDS % 60);
            let treasury_release_per_minute = MAX_EPOCH_REWARDS + padding;
            treasury_release_per_minute / 60
        };

        let treasury = tlb::create(
            total_mint,
            treasury_vesting_start_time_sec,
            treasury_release_per_second
        );

        let config = Config {
            id: object::new(ctx),
            version: VERSION,
            bus_count: INITIAL_BUS_COUNT,
            treasury,
            last_difficulty_adjustment: epoch_start,
            total_hashes: 0,
            total_rewards: 0,
        };
        transfer::share_object(config);

        let adminCap = AdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(adminCap, ctx.sender())
    }

    // === Public mutative ===

    #[allow(lint(share_owned))]
    public fun epoch_reset(
        config: &mut Config,
        mut buses: vector<Bus>,
        clock: &clock::Clock,
        _ctx: &mut TxContext,
    ) {
        assert!(buses.length() == config.bus_count, EInsufficientBuses);

        assert!(buses[0].live, EMiningHasEnded);

        let current_ts = clock.timestamp_ms();
        {
            let vesting_start_ms = config.treasury.unlock_start_ts_sec() * 1000;
            assert!(current_ts >= vesting_start_ms, EMiningNotStarted);
        };

        {
            let reset_threshold = buses[0].last_reset + EPOCH_DURATION;
            assert!(current_ts > reset_threshold, EResetTooEarly);
        };

        let total_epoch_hashes = {
            let mut accum = 0;
            let mut index = 0;
            while (index < config.bus_count) {
                let bus = buses.borrow(index);
                accum = accum + bus.epoch_hashes;
                index = index + 1;
            };
            accum
        };

        let bus_epoch_max_rewards = MAX_EPOCH_REWARDS / config.bus_count;

        // Gathers all of the currently withdrawable treasury, and unused bus rewards
        let (mut available_funds, previous_epoch_bus_rewards) = {
            let mut total_epoch_rewards = 0;
            let mut index = 0;
            let mut accum = balance::zero();

            while (index < config.bus_count) {
                let bus = buses.borrow_mut(index);
                let remaining_rewards = bus.rewards.withdraw_all();
                let epoch_rewards = bus_epoch_max_rewards - remaining_rewards.value();

                total_epoch_rewards = total_epoch_rewards + epoch_rewards;

                accum.join(remaining_rewards);
                index = index + 1;
            };

            let unlocked_rewards = config.treasury.withdraw_all(clock);
            accum.join(unlocked_rewards);

            (accum, total_epoch_rewards)
        };

        config.total_hashes = config.total_hashes + total_epoch_hashes;
        config.total_rewards = config.total_rewards + previous_epoch_bus_rewards;

        let rewards_are_available = available_funds.value() >= MAX_EPOCH_REWARDS;
        if (rewards_are_available) {
            let new_reward_rate = calculate_new_reward_rate(
                buses[0].reward_rate(),
                previous_epoch_bus_rewards,
                bus_epoch_max_rewards,
            );

            let suggested_difficulty = calculate_difficulty(config.total_hashes);
            let should_adjust_difficulty = buses[0].difficulty() != suggested_difficulty;

            if (should_adjust_difficulty) {
                config.last_difficulty_adjustment = current_ts;
            };

            while (!buses.is_empty()) {
                let mut bus = buses.pop_back();

                let topup = available_funds.split(bus_epoch_max_rewards);
                bus.rewards.join(topup);

                bus.last_reset = current_ts;
                bus.reward_rate = new_reward_rate;
                bus.epoch_hashes = 0;
                if (should_adjust_difficulty) {
                    bus.difficulty = suggested_difficulty;
                };

                transfer::share_object(bus);
            };

            // Put all the unused funds back in the treasury
            let unused_funds = available_funds.withdraw_all();
            config.treasury.top_up(unused_funds, clock);
        } else {
            {
                let vesting_completed = config.treasury.remaining_unlock(clock) == 0;
                assert!(vesting_completed, EVestingInProgress);
            };

            // Mining is finished
            // Vesting is complete, and there are insufficient rewards to fund the buses

            let extra_balance = config.treasury.skim_extraneous_balance();
            available_funds.join(extra_balance);

            let final_balance = available_funds.value();
            config.total_rewards = config.total_rewards + final_balance;

            // Add all remaining funds to a bus to be claimed
            let topup = available_funds.withdraw_all();
            buses[0].rewards.join(topup);

            while (!buses.is_empty()) {
                let mut bus = buses.pop_back();

                bus.live = false;

                transfer::share_object(bus);
            };
        };

        available_funds.destroy_zero();
        buses.destroy_empty();
    }

    public fun mine(
        nonce: u64,
        bus: &mut Bus,
        miner: &mut Miner,
        clock: &clock::Clock,
        ctx: &mut TxContext,
    ): coin::Coin<MINE> {
        if (!bus.live) {
            // Mining has ended, any rewards remaining in buses can be withdrawn
            let remaining_rewards = bus.rewards.withdraw_all();
            let remaining_amount = remaining_rewards.value();
            if (remaining_amount == 0) {
                abort EMiningHasEnded
            };
            miner.record_rewards(remaining_amount);
            return coin::from_balance(remaining_rewards, ctx)
        };

        let current_ts = clock.timestamp_ms();
        {
            let threshold = bus.last_reset + EPOCH_DURATION;
            assert!(current_ts < threshold, ENeedsReset);
        };

        assert!(bus.rewards.value() >= bus.reward_rate, ERewardsExhausted);

        let proof = generate_proof(miner.current_hash(), ctx.sender(), nonce);

        validate_proof(proof, bus.difficulty);

        let new_hash = {
            let mut new_hash_data: vector<u8> = vector::empty();
            vector::append(&mut new_hash_data, proof);
            vector::append(&mut new_hash_data, bcs::to_bytes(&current_ts));
            vector::append(&mut new_hash_data, bcs::to_bytes(&ctx.fresh_object_address()));
            hash::keccak256(&new_hash_data)
        };
        *miner.current_hash_mut() = new_hash;

        miner.record_hash();
        miner.record_rewards(bus.reward_rate);

        bus.epoch_hashes = bus.epoch_hashes + 1;

        let reward = bus.rewards.split(bus.reward_rate);

        coin::from_balance(reward, ctx)
    }

    // === Public view ===

    // Bus

    public fun live(
        bus: &Bus,
    ): bool {
        bus.live
    }

    public fun difficulty(
        bus: &Bus,
    ): u8 {
        bus.difficulty
    }

    public fun reward_rate(
        bus: &Bus,
    ): u64 {
        bus.reward_rate
    }

    public fun rewards(
        bus: &Bus,
    ): &balance::Balance<MINE> {
        &bus.rewards
    }

    // Config

    public fun total_rewards(
        config: &Config,
    ): u64 {
        config.total_rewards
    }

    public fun total_hashes(
        config: &Config,
    ): u64 {
        config.total_hashes
    }

    public fun treasury(
        config: &Config,
    ): &tlb::Locker<MINE> {
        &config.treasury
    }

    // === Private ===

    fun validate_proof(proof: vector<u8>, difficulty: u8) {
        if (difficulty < 1) {
            abort EInsufficientDifficulty
        };
        let mut n = 0;
        while (n < difficulty) {
            assert!(proof.borrow(n as u64) == 0, EInsufficientDifficulty);
            n = n + 1;
        };
    }

    fun generate_proof(current_hash: vector<u8>, sender: address, nonce: u64): vector<u8> {
        let mut data: vector<u8> = vector::empty();
        vector::append(&mut data, current_hash);
        vector::append(&mut data, bcs::to_bytes(&sender));
        vector::append(&mut data, bcs::to_bytes(&nonce));
        let res = hash::keccak256(&data);
        res
    }

    fun calculate_new_reward_rate(current_rate: u64, epoch_rewards: u64, max_reward: u64): u64 {
        let smoothing_factor = 2;

        if (epoch_rewards == 0) {
            return current_rate
        };

        let new_rate_min = current_rate / smoothing_factor;
        let new_rate_max = current_rate * smoothing_factor;

        let new_rate = (current_rate * TARGET_EPOCH_REWARDS) / epoch_rewards;


        let new_rate_smoothed = math::max(new_rate_min, math::min(new_rate_max, new_rate));

        math::min(math::max(new_rate_smoothed, 1), max_reward)
    }

    fun calculate_difficulty(total_hashes: u64): u8 {
        let billion = UNIT;
        let mut difficulty_bump = 0;
        // Difficulty increases as hashes pass
        // each subsequent power of 2, multiplied by a billion
        //
        // Initial difficulty: <1bn hashes
        // +1 difficulty: 1-3bn hashes (2bn)
        // +2: 3-7bn hashes (4bn)
        // +3: 7-15bn hashes (8bn)
        // +4: 15-31bn hashes (16bn)
        // ...
        let mut counter = 0;
        while (true) {
            let threshold = billion * math::pow(2, difficulty_bump);
            counter = counter + threshold;
            // Hashes cannot exceed the maximum number of individual rewards
            if (counter >= TOTAL_SUPPLY) {
                break
            };
            if (total_hashes >= counter) {
                difficulty_bump = difficulty_bump + 1;
            } else {
                break
            };
        };
        INITIAL_DIFFICULTY + difficulty_bump
    }

    // === Test ===

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(MINE {}, ctx);
    }

    #[test_only]
    public fun generate_proof_pub(current_hash: vector<u8>, sender: address, nonce: u64): vector<u8> {
        generate_proof(current_hash, sender, nonce)
    }

    #[test_only]
    public fun validate_proof_pub(proof: vector<u8>, difficulty: u8) {
        validate_proof(proof, difficulty)
    }

    #[test_only]
    public fun calculate_difficulty_pub(total_hashes: u64): u8 {
        calculate_difficulty(total_hashes)
    }

    #[test_only]
    // Fast forward the treasury for testing mining conclusion
    // This will also trigger a difficulty increase condition
    public fun simulate_claims(
        miner: &mut Miner,
        config: &mut Config,
        clock: &mut clock::Clock
    ): balance::Balance<MINE> {
        let simulated_hash_count = 1_000_000_001;

        // Enough time to vest the entire treasury
        // The remainder will be returned to the treasury on next 'epoch_reset'
        let one_year = ONE_DAY * 365;
        let fast_forward_length = 50 * one_year;
        clock.increment_for_testing(fast_forward_length);

        // Leave enough for 10 epochs
        let remainder = TARGET_EPOCH_REWARDS * 10;

        let amount_to_withdraw = config.treasury.max_withdrawable(clock) - remainder;

        // Add 'rewards' to counters
        miner.record_rewards(amount_to_withdraw);
        config.total_rewards = config.total_rewards + amount_to_withdraw;

        // Add 'hashes' to counters
        *miner.total_hashes_mut() = miner.total_hashes() + simulated_hash_count;
        config.total_hashes = config.total_hashes + simulated_hash_count;

        config.treasury.withdraw(
            amount_to_withdraw,
            clock
        )
    }

    #[test_only]
    public fun get_bus_epoch_rewards(): u64 {
        MAX_EPOCH_REWARDS / INITIAL_BUS_COUNT
    }

    #[test_only]
    public fun get_supply(): u64 {
        TOTAL_SUPPLY
    }

    #[test_only]
    public fun get_epoch_duration(): u64 {
        EPOCH_DURATION
    }

    #[test_only]
    public fun get_initial_bus_count(): u64 {
        INITIAL_BUS_COUNT
    }

    #[test_only]
    public fun get_initial_difficulty(): u8 {
        INITIAL_DIFFICULTY
    }

}
