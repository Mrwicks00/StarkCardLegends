# StarkCard Legends
A scalable, mobile-first on-chain trading card game built on Starknet. Players collect, trade, and battle NFT-based cards with unique attributes, stake them for BTC-denominated yields via Vesu, and interact through a feature-rich Flutter app powered by Starknet.dart. The game features a marketplace, provably fair battles with Dojo, and Bitcoin integration for cross-chain prestige.

## Features
- **NFT Cards**: Mint and trade ERC-721 cards with attributes (attack, defense, rarity, element).
- **Battles**: Provably fair, grid-based battles with Dojo ECS and on-chain RNG.
- **BTCfi Yields**: Stake cards in Vesu vaults for dynamic BTC yields (LBTC/wBTC).
- **Mobile App**: Flutter app with card minting, trading, battling, and yield dashboard.
- **Bitcoin Integration**: Inscribe achievements on Bitcoin via Broly.
- **Scalability**: Modular design for future features like multiplayer and leaderboards.

## Setup
1. Clone repo: `git clone https://github.com/mrwicks00/StarkCardLegends.git`
2. Install Cairo, Dojo, Flutter, and Starknet.dart (see /docs/setup.md).
3. Deploy contracts to Sepolia: `scripts/deploy.sh`
4. Run mobile app: `cd mobile && flutter run`

## Future Vision
Expand to multiplayer battles, global leaderboards, and cross-chain marketplaces.

## Team
Built with Grok 3 (xAI) for a robust, all-rounder Web3 experience.