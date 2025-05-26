use starknet::{ContractAddress, get_caller_address, get_block_timestamp, get_contract_address};

#[derive(Copy, Drop, starknet::Store, Serde)]
struct Listing {
    card_id: u256,
    seller: ContractAddress,
    price: u64,
    auction_end: u64,
    is_auction: bool,
    active: bool,
}

#[derive(Copy, Drop, starknet::Store, Serde)]
struct BidRecord {
    bidder: ContractAddress,
    bid: u64,
    timestamp: u64,
}

#[starknet::interface]
trait IStarkMarketplace<TContractState> {
    fn pause(ref self: TContractState);
    fn unpause(ref self: TContractState);
    fn set_fee_percent(ref self: TContractState, percent: u8);
    fn list_card(ref self: TContractState, card_id: u256, price: u64, is_auction: bool, auction_duration: u64);
    fn place_bid(ref self: TContractState, listing_id: u256, bid: u64);
    fn buy_card(ref self: TContractState, listing_id: u256);
    fn end_auction(ref self: TContractState, listing_id: u256);
    fn cancel_listing(ref self: TContractState, listing_id: u256);
    fn get_bid_history(self: @TContractState, listing_id: u256, bid_id: u256) -> BidRecord;
}

#[starknet::contract]
mod Marketplace {
    use super::{IStarkMarketplace, ContractAddress, get_caller_address, get_block_timestamp, get_contract_address, Listing, BidRecord};
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
        listings: Map<u256, Listing>,
        listing_count: u256,
        bids: Map<(u256, ContractAddress), u64>,
        bid_history: Map<(u256, u256), BidRecord>,
        bid_count: Map<u256, u256>,
        highest_bid: Map<u256, u64>,
        highest_bidder: Map<u256, ContractAddress>,
        escrow: Map<u256, u64>,
        payment_token: ContractAddress, // $CARD
        treasury: ContractAddress,
        fee_percent: u8, // 2%
        paused: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        Listed: Listed,
        Purchased: Purchased,
        BidPlaced: BidPlaced,
        ListingCancelled: ListingCancelled,
        AuctionEnded: AuctionEnded,
        Paused: Paused,
        Unpaused: Unpaused,
    }

    #[derive(Drop, starknet::Event)]
    struct Listed {
        listing_id: u256,
        card_id: u256,
        seller: ContractAddress,
        price: u64,
        is_auction: bool,
        auction_end: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct Purchased {
        listing_id: u256,
        card_id: u256,
        buyer: ContractAddress,
        price: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct BidPlaced {
        listing_id: u256,
        bidder: ContractAddress,
        bid: u64,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ListingCancelled {
        listing_id: u256,
        card_id: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct AuctionEnded {
        listing_id: u256,
        card_id: u256,
        winner: ContractAddress,
        price: u64,
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
    fn constructor(ref self: ContractState, owner: ContractAddress, treasury: ContractAddress, payment_token: ContractAddress) {
        self.ownable.initializer(owner);
        self.treasury.write(treasury);
        self.payment_token.write(payment_token);
        self.fee_percent.write(2);
        self.paused.write(false);
    }

    #[abi(embed_v0)]
    impl StarkMarketplaceImpl of IStarkMarketplace<ContractState> {
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

        fn set_fee_percent(ref self: ContractState, percent: u8) {
            self.ownable.assert_only_owner();
            assert(percent <= 10, 'Fee too high');
            self.fee_percent.write(percent);
        }

        fn list_card(ref self: ContractState, card_id: u256, price: u64, is_auction: bool, auction_duration: u64) {
            assert(!self.paused.read(), 'Contract paused');
            assert(price > 0, 'Price must be > 0');
            assert(auction_duration > 0 || !is_auction, 'Invalid auction duration');
            let caller = get_caller_address();
            let id = self.listing_count.read() + 1;
            self.listing_count.write(id);
            let auction_end = if is_auction { get_block_timestamp() + auction_duration } else { 0 };
            self.listings.write(id, Listing { card_id, seller: caller, price, auction_end, is_auction, active: true });
            self.emit(Listed { listing_id: id, card_id, seller: caller, price, is_auction, auction_end });
        }

        fn place_bid(ref self: ContractState, listing_id: u256, bid: u64) {
            assert(!self.paused.read(), 'Contract paused');
            assert(listing_id > 0 && listing_id <= self.listing_count.read(), 'Invalid listing ID');
            let listing = self.listings.read(listing_id);
            assert(listing.active, 'Listing inactive');
            assert(listing.is_auction, 'Not an auction');
            assert(get_block_timestamp() < listing.auction_end, 'Auction ended');
            let min_bid = self.highest_bid.read(listing_id) * 105 / 100; // 5% increment
            assert(bid >= min_bid && bid >= listing.price, 'Bid too low');
            let caller = get_caller_address();
            let token = IERC20Dispatcher { contract_address: self.payment_token.read() };
            token.transfer_from(caller, get_contract_address(), bid.into()); // Escrow
            self.escrow.write(listing_id, bid);
            let bid_id = self.bid_count.read(listing_id) + 1;
            self.bid_count.write(listing_id, bid_id);
            self.bids.write((listing_id, caller), bid);
            self.bid_history.write((listing_id, bid_id), BidRecord { bidder: caller, bid, timestamp: get_block_timestamp() });
            self.highest_bid.write(listing_id, bid);
            self.highest_bidder.write(listing_id, caller);
            self.emit(BidPlaced { listing_id, bidder: caller, bid, timestamp: get_block_timestamp() });
        }

        fn buy_card(ref self: ContractState, listing_id: u256) {
            assert(!self.paused.read(), 'Contract paused');
            assert(listing_id > 0 && listing_id <= self.listing_count.read(), 'Invalid listing ID');
            let listing = self.listings.read(listing_id);
            assert(listing.active, 'Listing inactive');
            assert(!listing.is_auction, 'Auction listing');
            let caller = get_caller_address();
            let token = IERC20Dispatcher { contract_address: self.payment_token.read() };
            let fee = listing.price * self.fee_percent.read().into() / 100;
            let seller_amount = listing.price - fee;
            token.transfer_from(caller, self.treasury.read(), fee.into());
            token.transfer_from(caller, listing.seller, seller_amount.into());
            self.listings.write(listing_id, Listing { card_id: listing.card_id, seller: listing.seller, price: listing.price, auction_end: listing.auction_end, is_auction: false, active: false });
            self.emit(Purchased { listing_id, card_id: listing.card_id, buyer: caller, price: listing.price });
        }

        fn end_auction(ref self: ContractState, listing_id: u256) {
            assert(!self.paused.read(), 'Contract paused');
            assert(listing_id > 0 && listing_id <= self.listing_count.read(), 'Invalid listing ID');
            let listing = self.listings.read(listing_id);
            assert(listing.active, 'Listing inactive');
            assert(listing.is_auction, 'Not an auction');
            assert(get_block_timestamp() >= listing.auction_end, 'Auction not ended');
            let winner = self.highest_bidder.read(listing_id);
            let price = self.highest_bid.read(listing_id);
            let token = IERC20Dispatcher { contract_address: self.payment_token.read() };
            let fee = price * self.fee_percent.read().into() / 100;
            let seller_amount = price - fee;
            token.transfer(self.treasury.read(), fee.into());
            token.transfer(listing.seller, seller_amount.into());
            self.listings.write(listing_id, Listing { card_id: listing.card_id, seller: listing.seller, price: listing.price, auction_end: listing.auction_end, is_auction: false, active: false });
            self.escrow.write(listing_id, 0);
            if winner != 0x0.try_into().unwrap() {
                self.emit(AuctionEnded { listing_id, card_id: listing.card_id, winner, price });
            } else {
                self.emit(ListingCancelled { listing_id, card_id: listing.card_id });
            }
        }

        fn cancel_listing(ref self: ContractState, listing_id: u256) {
            assert(!self.paused.read(), 'Contract paused');
            assert(listing_id > 0 && listing_id <= self.listing_count.read(), 'Invalid listing ID');
            let caller = get_caller_address();
            let listing = self.listings.read(listing_id);
            assert(listing.active, 'Listing inactive');
            assert(listing.seller == caller, 'Not seller');
            assert(!listing.is_auction || get_block_timestamp() < listing.auction_end, 'Auction active');
            self.listings.write(listing_id, Listing { card_id: listing.card_id, seller: listing.seller, price: listing.price, auction_end: listing.auction_end, is_auction: false, active: false });
            self.emit(ListingCancelled { listing_id, card_id: listing.card_id });
        }

        fn get_bid_history(self: @ContractState, listing_id: u256, bid_id: u256) -> BidRecord {
            assert(listing_id > 0 && listing_id <= self.listing_count.read(), 'Invalid listing ID');
            assert(bid_id > 0 && bid_id <= self.bid_count.read(listing_id), 'Invalid bid ID');
            self.bid_history.read((listing_id, bid_id))
        }
    }
}