use starknet::{ContractAddress, get_caller_address, get_block_timestamp};

#[starknet::interface]
trait IYieldVault<TContractState> {
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn stake_card(ref self: TContractState, card_id: u256, rarity: u8);
    fn unstake_card(ref self: TContractState, card_id: u256);
    fn claim_yield(ref self: TContractState);
    fn get_yield(self: @TContractState, user: ContractAddress) -> u64;
    fn get_staked_card(self: @TContractState, user: ContractAddress, card_id: u256) -> u64;
}

#[starknet::contract]
mod YieldVault {
    use super::{IYieldVault, ContractAddress, get_caller_address, get_block_timestamp};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{Map, StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess, StorageMapWriteAccess};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        staked_cards: Map<(ContractAddress, u256), u64>, // Timestamp
        yields: Map<ContractAddress, u64>,
        tier_multipliers: Map<u8, u64>,
        total_staked: u256,
        yield_token: ContractAddress, // $CARD
        vesu_pool: ContractAddress, // Mock Vesu
        lock_period: u64, // 7 days
        treasury: ContractAddress,
        paused: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        CardStaked: CardStaked,
        CardUnstaked: CardUnstaked,
        YieldClaimed: YieldClaimed,
        Paused: Paused,
        Unpaused: Unpaused,
    }

    #[derive(Drop, starknet::Event)]
    struct CardStaked {
        user: ContractAddress,
        card_id: u256,
        stake_time: u64,
        yield_rate: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct CardUnstaked {
        user: ContractAddress,
        card_id: u256,
        yield_earned: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct YieldClaimed {
        user: ContractAddress,
        amount: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Paused {
        caller: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Unpaused {
        caller: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, treasury: ContractAddress, yield_token: ContractAddress, vesu_pool: ContractAddress) {
        self.ownable.initializer(owner);
        self.tier_multipliers.write(1, 10);
        self.tier_multipliers.write(2, 20);
        self.tier_multipliers.write(3, 30);
        self.total_staked.write(0);
        self.yield_token.write(yield_token);
        self.vesu_pool.write(vesu_pool);
        self.lock_period.write(7 * 24 * 3600); // 7 days
        self.treasury.write(treasury);
        self.paused.write(false);
    }

    #[abi(embed_v0)]
    impl YieldVaultImpl of IYieldVault<ContractState> {
        fn pause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.paused.write(true);
            self.emit(Paused { caller: get_caller_address() });
        }

        fn unpause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.paused.write(false);
            self.emit(Unpaused { caller: get_caller_address() });
        }

        fn stake_card(ref self: ContractState, card_id: u256, rarity: u8) {
            assert(!self.paused.read(), 'Contract paused');
            assert(rarity >= 1 && rarity <= 3, 'Invalid rarity');
            let caller = get_caller_address();
            assert(self.staked_cards.read((caller, card_id)) == 0, 'Card already staked');
            let stake_time = get_block_timestamp();
            self.staked_cards.write((caller, card_id), stake_time);
            self.total_staked.write(self.total_staked.read() + 1);
            let yield_rate = self.tier_multipliers.read(rarity) * 50;
            self.yields.write(caller, self.yields.read(caller) + yield_rate);
            let token = IERC20Dispatcher { contract_address: self.yield_token.read() };
            token.transfer(self.vesu_pool.read(), yield_rate.into());
            self.emit(CardStaked { user: caller, card_id, stake_time, yield_rate });
        }

        fn unstake_card(ref self: ContractState, card_id: u256) {
            assert(!self.paused.read(), 'Contract paused');
            let caller = get_caller_address();
            let stake_time = self.staked_cards.read((caller, card_id));
            assert(stake_time > 0, 'Card not staked');
            assert(get_block_timestamp() >= stake_time + self.lock_period.read(), 'Lock period active');
            let duration = get_block_timestamp() - stake_time;
            let yield_earned = self.yields.read(caller) * duration / (24 * 3600);
            self.staked_cards.write((caller, card_id), 0);
            self.total_staked.write(self.total_staked.read() - 1);
            self.yields.write(caller, self.yields.read(caller) - yield_earned);
            let token = IERC20Dispatcher { contract_address: self.yield_token.read() };
            token.transfer_from(self.vesu_pool.read(), caller, yield_earned.into());
            self.emit(CardUnstaked { user: caller, card_id, yield_earned });
            self.emit(YieldClaimed { user: caller, amount: yield_earned });
        }

        fn claim_yield(ref self: ContractState) {
            assert(!self.paused.read(), 'Contract paused');
            let caller = get_caller_address();
            let yield = self.yields.read(caller);
            assert(yield > 0, 'No yield to claim');
            self.yields.write(caller, 0);
            let token = IERC20Dispatcher { contract_address: self.yield_token.read() };
            token.transfer_from(self.vesu_pool.read(), caller, yield.into());
            self.emit(YieldClaimed { user: caller, amount: yield });
        }

        fn get_yield(self: @ContractState, user: ContractAddress) -> u64 {
            self.yields.read(user)
        }

        fn get_staked_card(self: @ContractState, user: ContractAddress, card_id: u256) -> u64 {
            self.staked_cards.read((user, card_id))
        }
    }
}