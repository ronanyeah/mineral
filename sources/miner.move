module mineral::miner {
    use sui::hash;
    use sui::bcs;

    public struct Miner has store, key {
        id: UID,
        current_hash: vector<u8>,
        total_rewards: u64,
        total_hashes: u64,
    }

    // Public

    entry fun register(
        ctx: &mut TxContext
    ) {
        let miner = new(ctx);

        transfer::transfer(miner, ctx.sender());
    }

    public fun current_hash(
        self: &Miner,
    ): vector<u8> {
        self.current_hash
    }

    public fun total_rewards(
        self: &Miner,
    ): u64 {
        self.total_rewards
    }

    public fun total_hashes(
        self: &Miner,
    ): u64 {
        self.total_hashes
    }

    public fun destroy(self: Miner) {
        let Miner {
            id,
            current_hash: _,
            total_rewards: _,
            total_hashes: _,
        } = self;
        object::delete(id);
    }

    // Protected

    public(package) fun record_hash(
        self: &mut Miner,
    ) {
        self.total_hashes = self.total_hashes + 1;
    }

    public(package) fun record_rewards(
        self: &mut Miner,
        amount: u64,
    ) {
        self.total_rewards = self.total_rewards + amount;
    }

    public(package) fun current_hash_mut(
        self: &mut Miner,
    ): &mut vector<u8> {
        &mut self.current_hash
    }

    // Private

    fun new(ctx: &mut TxContext): Miner {
        let mut seed: vector<u8> = vector::empty();
        vector::append(&mut seed, bcs::to_bytes(&ctx.sender()));
        vector::append(&mut seed, bcs::to_bytes(&ctx.fresh_object_address()));
        let initial_hash = hash::keccak256(&seed);

        let miner = Miner {
            id: object::new(ctx),
            current_hash: initial_hash,
            total_rewards: 0,
            total_hashes: 0,
        };

        miner
    }

    // Test

    #[test_only]
    public fun total_hashes_mut(
        self: &mut Miner,
    ): &mut u64 {
        &mut self.total_hashes
    }

    #[test_only]
    public fun reset_hash(
        self: &mut Miner,
    ) {
        self.current_hash = hash::keccak256(
            &bcs::to_bytes(&0)
        );
    }
}
