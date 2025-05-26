use starknet::{ContractAddress, get_block_timestamp, get_caller_address};

#[derive(Copy, Drop, starknet::Store, Serde)]
    struct CardStats {
        attack: u64,
        defense: u64,
        rarity: u8,
        element: u8,
        level: u64,
        experience: u64,
    }

// Define the trait for your contract's external interface
#[starknet::interface]

trait IStarkCard<TContractState> {
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn set_mint_fee(ref self: TContractState, fee: u256);
    fn mint_card(
        ref self: TContractState,
        attack: u64,
        defense: u64,
        rarity: u8,
        element: u8,
        name: felt252,
        ipfs_hash: felt252,
        card_trait: felt252
    );
    fn transfer_card(ref self: TContractState, to: ContractAddress, token_id: u256);
    fn approve(ref self: TContractState, approved: ContractAddress, token_id: u256);
    fn upgrade_card(ref self: TContractState, token_id: u256, experience: u64);
    fn get_card(self: @TContractState, token_id: u256) -> (ContractAddress, CardStats, felt252, felt252);
    fn balance_of(self: @TContractState, owner: ContractAddress) -> u256;
    fn total_supply(self: @TContractState) -> u256;
}

#[starknet::contract]
mod StarkCard {
    use super::{IStarkCard, ContractAddress, get_block_timestamp, get_caller_address, CardStats};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        token_id: u256,
        owners: Map<u256, ContractAddress>,
        card_stats: Map<u256, CardStats>,
        balances: Map<ContractAddress, u256>,
        approvals: Map<u256, ContractAddress>,
        metadata: Map<u256, felt252>, // IPFS hash
        traits: Map<u256, felt252>, // e.g., "Dragon"
        total_supply: u256,
        treasury: ContractAddress,
        mint_fee: u256, // 0.01 ETH
        payment_token: ContractAddress, // ETH
        paused: bool,
    }

    

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        CardMinted: CardMinted,
        CardTransferred: CardTransferred,
        CardApproved: CardApproved,
        CardUpgraded: CardUpgraded,
        Paused: Paused,
        Unpaused: Unpaused,
    }

    #[derive(Drop, starknet::Event)]
    struct CardMinted {
        token_id: u256,
        owner: ContractAddress,
        attack: u64,
        defense: u64,
        rarity: u8,
        element: u8,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct CardTransferred {
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct CardApproved {
        token_id: u256,
        approved: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct CardUpgraded {
        token_id: u256,
        level: u64,
        experience: u64,
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
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        treasury: ContractAddress,
        payment_token: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self.token_id.write(0);
        self.total_supply.write(0);
        self.treasury.write(treasury);
        self.mint_fee.write(10000000000000000); // 0.01 ETH
        self.payment_token.write(payment_token);
        self.paused.write(false);
    }

    // Implement the external trait
    #[abi(embed_v0)]
    impl StarkCardImpl of IStarkCard<ContractState> {
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

        fn set_mint_fee(ref self: ContractState, fee: u256) {
            self.ownable.assert_only_owner();
            self.mint_fee.write(fee);
        }

        fn mint_card(
            ref self: ContractState,
            attack: u64,
            defense: u64,
            rarity: u8,
            element: u8,
            name: felt252,
            ipfs_hash: felt252,
            card_trait: felt252,
        ) {
            assert(!self.paused.read(), 'Contract paused');
            assert(rarity >= 1 && rarity <= 3, 'Invalid rarity: 1-3');
            assert(element >= 1 && element <= 4, 'Invalid element: 1-4');
            assert(attack >= 10 && attack <= 100, 'Attack must be 10-100');
            assert(defense >= 5 && defense <= 80, 'Defense must be 5-80');
            assert(name != 0, 'Name required');
            let caller = get_caller_address();
            let fee = self.mint_fee.read();
            let token = IERC20Dispatcher { contract_address: self.payment_token.read() };
            token.transfer_from(caller, self.treasury.read(), fee);
            let id = self.token_id.read() + 1;
            self.token_id.write(id);
            self.total_supply.write(self.total_supply.read() + 1);
            self.owners.write(id, caller);
            self
                .card_stats
                .write(id, CardStats { attack, defense, rarity, element, level: 1, experience: 0 });
            self.balances.write(caller, self.balances.read(caller) + 1);
            self.metadata.write(id, ipfs_hash);
            self.traits.write(id, card_trait);
            self
                .emit(
                    CardMinted {
                        token_id: id,
                        owner: caller,
                        attack,
                        defense,
                        rarity,
                        element,
                        timestamp: get_block_timestamp(),
                    },
                );
        }

        fn transfer_card(ref self: ContractState, to: ContractAddress, token_id: u256) {
            assert(!self.paused.read(), 'Contract paused');
            assert(token_id > 0 && token_id <= self.token_id.read(), 'Invalid token ID');
            let caller = get_caller_address();
            assert(self.owners.read(token_id) == caller, 'Not owner');
            assert(to != 0x0.try_into().unwrap(), 'Invalid recipient: Zero address');
            self.owners.write(token_id, to);
            self.balances.write(caller, self.balances.read(caller) - 1);
            self.balances.write(to, self.balances.read(to) + 1);
            self.approvals.write(token_id,  0x0.try_into().unwrap()); // Use the imported zero() function
            self.emit(CardTransferred { from: caller, to, token_id });
        }
        
        fn approve(ref self: ContractState, approved: ContractAddress, token_id: u256) {
            assert(!self.paused.read(), 'Contract paused');
            assert(token_id > 0 && token_id <= self.token_id.read(), 'Invalid token ID');
            let caller = get_caller_address();
            assert(self.owners.read(token_id) == caller, 'Not owner');
            self.approvals.write(token_id, approved);
            self.emit(CardApproved { token_id, approved });
        }

        fn upgrade_card(ref self: ContractState, token_id: u256, experience: u64) {
            assert(!self.paused.read(), 'Contract paused');
            assert(token_id > 0 && token_id <= self.token_id.read(), 'Invalid token ID');
            let caller = get_caller_address();
            assert(self.owners.read(token_id) == caller, 'Not owner');
            let mut stats = self.card_stats.read(token_id);
            stats.experience += experience;
            if stats.experience >= stats.level * 100 {
                stats.level += 1;
                stats.attack += 10 * stats.level;
                stats.defense += 5 * stats.level;
                stats.experience = 0;
            }
            self.card_stats.write(token_id, stats);
            self.emit(CardUpgraded { token_id, level: stats.level, experience: stats.experience });
        }

        fn get_card(
            self: @ContractState, token_id: u256,) -> (ContractAddress, CardStats, felt252, felt252) {
            assert(token_id > 0 && token_id <= self.token_id.read(), 'Invalid token ID');
            (
                self.owners.read(token_id),
                self.card_stats.read(token_id),
                self.metadata.read(token_id),
                self.traits.read(token_id),
            )
        }

        fn balance_of(self: @ContractState, owner: ContractAddress) -> u256 {
            self.balances.read(owner)
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }
    

        // ... (implement all other trait methods here)
        // Include all the functions from your original implementation
    }
}