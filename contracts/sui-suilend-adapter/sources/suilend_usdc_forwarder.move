/// A deliberately narrow, DAY-owned money path for native Sui USDC into the
/// canonical Suilend main pool. Each deposit creates one Suilend obligation
/// and wraps its owner capability inside an address-owned DAY Position.
///
/// Deposit is fail-closed on DAY's canonical config/router/AdapterRegistryV2.
/// Full exit deliberately has no DAY config, registry, pause, server, caller
/// amount, caller profit, or caller payout parameter: the recorded owner can
/// always unwind directly through Suilend and proceeds go only to the payout
/// address recorded at deposit.
module day_suilend_adapter::suilend_usdc_forwarder {
    use std::type_name;
    use day::adapter_registry::{Self, AdapterRegistryV2};
    use day::day::{Self, ProtocolConfig};
    use day::yield_router::{Self, YieldRouter};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::event;
    use suilend::lending_market::{Self, LendingMarket, ObligationOwnerCap, RateLimiterExemption};
    use suilend::obligation;
    use suilend::suilend::MAIN_POOL;
    use usdc::usdc::USDC;
    #[test_only]
    use sui::{object_table, test_scenario as ts};
    #[test_only]
    use suilend::decimal;

    const E_WRONG_PROTOCOL_CONFIG: u64 = 1;
    const E_WRONG_ROUTER: u64 = 2;
    const E_ROUTER_PAUSED: u64 = 3;
    const E_WRONG_REGISTRY: u64 = 4;
    const E_WRONG_MARKET: u64 = 5;
    const E_NOT_OWNER: u64 = 6;
    const E_POSITION_CLOSED: u64 = 7;
    const E_WRONG_OBLIGATION: u64 = 8;
    const E_ZERO_AMOUNT: u64 = 9;
    const E_UNEXPECTED_OBLIGATION_STATE: u64 = 10;

    const CANONICAL_PROTOCOL_CONFIG: address =
        @0xdcd2e53c6ebc03cea47bcfc656337f03bf64cf1069bb92419bb67f4969603bba;
    const CANONICAL_YIELD_ROUTER: address =
        @0xa0722a3dd74837d9daa4a82c2ffd7ed4c1b6013d57a362a42cb5a6c9c004db6f;
    const CANONICAL_SUILEND_MAIN_POOL: address =
        @0x84030d26d85eaa7035084a057f2f11f701b7e2e4eda87551becbc7c97505ece1;
    const SUI_CHAIN: vector<u8> = b"sui";
    /// Exact AdapterRegistryV2 key registered on mainnet. This is deliberately
    /// not the venue slug: registry membership is keyed by the concrete DAY
    /// adapter deployment/asset route, `sui-suilend-usdc`.
    const SUI_LEND_ADAPTER: vector<u8> = b"sui-suilend-usdc";

    /// Owner-held receipt and the only production holder of the Suilend
    /// ObligationOwnerCap created for this deposit. Private fields prevent a
    /// caller from substituting owner, payout, market, obligation, or amount.
    public struct Position has key {
        id: UID,
        record: PositionRecord,
        obligation_cap: Option<ObligationOwnerCap<MAIN_POOL>>,
    }

    public struct PositionRecord has store {
        owner: address,
        payout_destination: address,
        market_id: ID,
        obligation_id: ID,
        principal_micros: u64,
        ctoken_amount: u64,
        closed: bool,
    }

    public struct Deposited has copy, drop {
        position_id: ID,
        owner: address,
        market_id: ID,
        obligation_id: ID,
        principal_micros: u64,
        ctoken_amount: u64,
    }

    public struct Withdrawn has copy, drop {
        position_id: ID,
        owner: address,
        payout_destination: address,
        market_id: ID,
        obligation_id: ID,
        principal_micros: u64,
        measured_return_micros: u64,
    }

    /// Emitted when the recorded owner takes direct custody of the exact
    /// Suilend obligation capability. The capability, not a caller-provided
    /// address, is transferred to the owner recorded at deposit.
    public struct ObligationCapabilityRecovered has copy, drop {
        position_id: ID,
        owner: address,
        market_id: ID,
        obligation_id: ID,
        principal_micros: u64,
    }

    /// Deposit the exact Coin<USDC> supplied by the signer. There is no scalar
    /// amount to trust: principal is measured from the coin, and Suilend's
    /// exact minted cToken balance is recorded for the eventual full exit.
    public fun deposit_usdc(
        config: &ProtocolConfig,
        router: &YieldRouter,
        registry: &AdapterRegistryV2,
        market: &mut LendingMarket<MAIN_POOL>,
        funds: Coin<USDC>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_deposit_authority(config, router, registry, market);

        let owner = tx_context::sender(ctx);
        let principal_micros = coin::value(&funds);
        assert_nonzero_principal(principal_micros);
        let reserve_index = lending_market::reserve_array_index<MAIN_POOL, USDC>(market);
        let obligation_cap = lending_market::create_obligation<MAIN_POOL>(market, ctx);
        let obligation_id = lending_market::obligation_id(&obligation_cap);
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<MAIN_POOL, USDC>(
            market,
            reserve_index,
            clock,
            funds,
            ctx,
        );
        let ctoken_amount = coin::value(&ctokens);
        lending_market::deposit_ctokens_into_obligation<MAIN_POOL, USDC>(
            market,
            reserve_index,
            &obligation_cap,
            clock,
            ctokens,
            ctx,
        );

        let market_id = object::id(market);
        let position = Position {
            id: object::new(ctx),
            record: PositionRecord {
                owner,
                payout_destination: owner,
                market_id,
                obligation_id,
                principal_micros,
                ctoken_amount,
                closed: false,
            },
            obligation_cap: option::some(obligation_cap),
        };
        let position_id = object::id(&position);
        event::emit(Deposited {
            position_id,
            owner,
            market_id,
            obligation_id,
            principal_micros,
            ctoken_amount,
        });
        transfer::transfer(position, owner);
    }

    /// Fully exit the recorded Suilend obligation. The exact cToken amount is
    /// read from Position, the returned USDC is measured, and payout is fixed
    /// to the source owner recorded by deposit_usdc.
    public fun withdraw_all_usdc(
        market: &mut LendingMarket<MAIN_POOL>,
        position: &mut Position,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert_exit_authority(market, position, ctx);

        let reserve_index = lending_market::reserve_array_index<MAIN_POOL, USDC>(market);
        assert_exact_recorded_obligation(market, position, reserve_index);
        let ctokens = lending_market::withdraw_ctokens<MAIN_POOL, USDC>(
            market,
            reserve_index,
            option::borrow(&position.obligation_cap),
            clock,
            position.record.ctoken_amount,
            ctx,
        );
        let no_exemption = option::none<RateLimiterExemption<MAIN_POOL, USDC>>();
        let proceeds = lending_market::redeem_ctokens_and_withdraw_liquidity<MAIN_POOL, USDC>(
            market,
            reserve_index,
            clock,
            ctokens,
            no_exemption,
            ctx,
        );
        let measured_return_micros = coin::value(&proceeds);

        let (payout_destination, obligation_cap) = close_and_take_cap(position);
        event::emit(Withdrawn {
            position_id: object::id(position),
            owner: position.record.owner,
            payout_destination,
            market_id: position.record.market_id,
            obligation_id: position.record.obligation_id,
            principal_micros: position.record.principal_micros,
            measured_return_micros,
        });
        transfer::public_transfer(proceeds, payout_destination);
        transfer::public_transfer(obligation_cap, position.record.owner);
    }

    /// Owner-only emergency escape hatch. It deliberately takes no market,
    /// router, config, registry, amount, profit, or destination. This remains
    /// callable if Suilend migrates its shared market to a version that the
    /// pinned adapter package can no longer execute. The recorded owner takes
    /// the exact wrapped capability and can use Suilend's current package to
    /// claim rewards and unwind every asset in the obligation directly.
    public fun recover_obligation_cap(
        position: &mut Position,
        ctx: &mut TxContext,
    ) {
        assert_recorded_owner(position, tx_context::sender(ctx));
        let owner = position.record.owner;
        let position_id = object::id(position);
        let market_id = position.record.market_id;
        let obligation_id = position.record.obligation_id;
        let principal_micros = position.record.principal_micros;
        let (_payout_destination, obligation_cap) = close_and_take_cap(position);
        event::emit(ObligationCapabilityRecovered {
            position_id,
            owner,
            market_id,
            obligation_id,
            principal_micros,
        });
        transfer::public_transfer(obligation_cap, owner);
    }

    fun assert_deposit_authority(
        config: &ProtocolConfig,
        router: &YieldRouter,
        registry: &AdapterRegistryV2,
        market: &LendingMarket<MAIN_POOL>,
    ) {
        assert!(object::id_address(config) == CANONICAL_PROTOCOL_CONFIG, E_WRONG_PROTOCOL_CONFIG);
        assert!(object::id_address(router) == CANONICAL_YIELD_ROUTER, E_WRONG_ROUTER);
        assert!(!yield_router::is_paused(router), E_ROUTER_PAUSED);
        assert!(object::id_address(market) == CANONICAL_SUILEND_MAIN_POOL, E_WRONG_MARKET);
        assert!(
            day::canonical_adapter_registry_v2_id(config) == option::some(object::id(registry)),
            E_WRONG_REGISTRY,
        );
        adapter_registry::assert_active_v2_on_chain(registry, SUI_LEND_ADAPTER, SUI_CHAIN);
    }

    fun assert_exit_authority(
        market: &LendingMarket<MAIN_POOL>,
        position: &Position,
        ctx: &TxContext,
    ) {
        assert_recorded_owner(position, tx_context::sender(ctx));
        assert_recorded_market(&position.record, object::id(market));
        assert!(object::id_address(market) == CANONICAL_SUILEND_MAIN_POOL, E_WRONG_MARKET);
        assert!(
            lending_market::obligation_id(option::borrow(&position.obligation_cap))
                == position.record.obligation_id,
            E_WRONG_OBLIGATION,
        );
    }

    fun assert_recorded_owner(position: &Position, sender: address) {
        assert!(sender == position.record.owner, E_NOT_OWNER);
        assert!(!position.record.closed, E_POSITION_CLOSED);
    }

    fun assert_recorded_market(record: &PositionRecord, market_id: ID) {
        assert!(market_id == record.market_id, E_WRONG_MARKET);
    }

    /// A permissionless Suilend reward crank can add a second collateral type
    /// to an obligation by ID. Never call this a full adapter exit if the live
    /// obligation has diverged from the one exact USDC deposit we recorded.
    /// Fail closed before mutation; the owner can always call
    /// recover_obligation_cap and unwind the complete obligation directly.
    fun assert_exact_recorded_obligation(
        market: &LendingMarket<MAIN_POOL>,
        position: &Position,
        reserve_index: u64,
    ) {
        let live = lending_market::obligation(market, position.record.obligation_id);
        let deposits = obligation::deposits(live);
        let borrows = obligation::borrows(live);
        assert_exact_recorded_shape(vector::length(deposits), vector::length(borrows));
        let deposit = vector::borrow(deposits, 0);
        assert_exact_recorded_deposit(
            obligation::deposit_reserve_array_index(deposit),
            obligation::deposit_deposited_ctoken_amount(deposit),
            reserve_index,
            position.record.ctoken_amount,
        );
        assert!(
            obligation::deposit_coin_type(deposit) == type_name::with_defining_ids<USDC>(),
            E_UNEXPECTED_OBLIGATION_STATE,
        );
    }

    fun assert_exact_recorded_shape(deposit_count: u64, borrow_count: u64) {
        assert!(deposit_count == 1, E_UNEXPECTED_OBLIGATION_STATE);
        assert!(borrow_count == 0, E_UNEXPECTED_OBLIGATION_STATE);
    }

    fun assert_exact_recorded_deposit(
        live_reserve_index: u64,
        live_ctoken_amount: u64,
        recorded_reserve_index: u64,
        recorded_ctoken_amount: u64,
    ) {
        assert!(live_reserve_index == recorded_reserve_index, E_UNEXPECTED_OBLIGATION_STATE);
        assert!(live_ctoken_amount == recorded_ctoken_amount, E_UNEXPECTED_OBLIGATION_STATE);
    }

    fun close_and_take_cap(
        position: &mut Position,
    ): (address, ObligationOwnerCap<MAIN_POOL>) {
        position.record.closed = true;
        let payout_destination = position.record.payout_destination;
        let obligation_cap = option::extract(&mut position.obligation_cap);
        (payout_destination, obligation_cap)
    }

    fun assert_nonzero_principal(principal_micros: u64) {
        assert!(principal_micros > 0, E_ZERO_AMOUNT);
    }

    public fun owner(position: &Position): address { position.record.owner }
    public fun payout_destination(position: &Position): address { position.record.payout_destination }
    public fun market_id(position: &Position): ID { position.record.market_id }
    public fun obligation_id(position: &Position): ID { position.record.obligation_id }
    public fun principal_micros(position: &Position): u64 { position.record.principal_micros }
    public fun ctoken_amount(position: &Position): u64 { position.record.ctoken_amount }
    public fun closed(position: &Position): bool { position.record.closed }

    #[test_only]
    fun record_for_testing(owner: address, market_id: ID): PositionRecord {
        PositionRecord {
            owner,
            payout_destination: owner,
            market_id,
            obligation_id: object::id_from_address(@0x777),
            principal_micros: 1_000_000,
            ctoken_amount: 999_000,
            closed: false,
        }
    }

    #[test_only]
    fun destroy_record_for_testing(record: PositionRecord) {
        let PositionRecord {
            owner: _,
            payout_destination: _,
            market_id: _,
            obligation_id: _,
            principal_micros: _,
            ctoken_amount: _,
            closed: _,
        } = record;
    }

    #[test_only]
    fun position_with_cap_for_testing(owner: address, ctx: &mut TxContext): Position {
        let obligations = object_table::new(ctx);
        let mut market = lending_market::mock_for_testing<MAIN_POOL>(
            vector[],
            obligations,
            owner,
            decimal::from(0),
            decimal::from(0),
            ctx,
        );
        let obligation_cap = lending_market::create_obligation<MAIN_POOL>(&mut market, ctx);
        let obligation_id = lending_market::obligation_id(&obligation_cap);
        let market_id = object::id(&market);
        transfer::public_share_object(market);
        Position {
            id: object::new(ctx),
            record: PositionRecord {
                owner,
                payout_destination: owner,
                market_id,
                obligation_id,
                principal_micros: 1_000_000,
                ctoken_amount: 999_000,
                closed: false,
            },
            obligation_cap: option::some(obligation_cap),
        }
    }

    #[test_only]
    fun destroy_closed_position_for_testing(position: Position) {
        let Position { id, record, obligation_cap } = position;
        option::destroy_none(obligation_cap);
        object::delete(id);
        destroy_record_for_testing(record);
    }

    #[test]
    fun recorded_payout_is_owner_bound() {
        let market_id = object::id_from_address(@0x8403);
        let record = record_for_testing(@0xa11ce, market_id);
        assert!(record.payout_destination == @0xa11ce, 100);
        assert!(!record.closed, 101);
        assert!(record.ctoken_amount == 999_000, 102);
        destroy_record_for_testing(record);
    }

    #[test]
    #[expected_failure(abort_code = E_ZERO_AMOUNT)]
    fun zero_principal_is_rejected_before_external_deposit() {
        assert_nonzero_principal(0);
    }

    #[test]
    fun recorded_owner_recovers_exact_cap_without_market_dependency() {
        let owner = @0xa11ce;
        let mut scenario = ts::begin(owner);
        let mut position = position_with_cap_for_testing(owner, ts::ctx(&mut scenario));
        let obligation_id = position.record.obligation_id;

        recover_obligation_cap(&mut position, ts::ctx(&mut scenario));
        assert!(position.record.closed, 200);
        assert!(option::is_none(&position.obligation_cap), 201);
        assert!(position.record.ctoken_amount == 999_000, 202);
        destroy_closed_position_for_testing(position);

        ts::next_tx(&mut scenario, owner);
        let cap = ts::take_from_sender<ObligationOwnerCap<MAIN_POOL>>(&scenario);
        assert!(lending_market::obligation_id(&cap) == obligation_id, 203);
        lending_market::destroy_for_testing(cap);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = E_NOT_OWNER)]
    fun non_owner_cannot_recover_obligation_cap() {
        let owner = @0xa11ce;
        let attacker = @0xb0b;
        let mut scenario = ts::begin(owner);
        let mut position = position_with_cap_for_testing(owner, ts::ctx(&mut scenario));
        ts::next_tx(&mut scenario, attacker);
        recover_obligation_cap(&mut position, ts::ctx(&mut scenario));
        destroy_closed_position_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = E_WRONG_MARKET)]
    fun market_substitution_is_rejected() {
        let record = record_for_testing(@0xa11ce, object::id_from_address(@0x8403));
        assert_recorded_market(&record, object::id_from_address(@0xbad));
        destroy_record_for_testing(record);
    }

    #[test]
    #[expected_failure(abort_code = E_POSITION_CLOSED)]
    fun recovered_position_cannot_replay() {
        let owner = @0xa11ce;
        let mut scenario = ts::begin(owner);
        let mut position = position_with_cap_for_testing(owner, ts::ctx(&mut scenario));
        recover_obligation_cap(&mut position, ts::ctx(&mut scenario));
        recover_obligation_cap(&mut position, ts::ctx(&mut scenario));
        destroy_closed_position_for_testing(position);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = E_UNEXPECTED_OBLIGATION_STATE)]
    fun permissionless_extra_collateral_forces_owner_recovery() {
        assert_exact_recorded_shape(2, 0);
    }

    #[test]
    #[expected_failure(abort_code = E_UNEXPECTED_OBLIGATION_STATE)]
    fun permissionless_ctoken_topup_forces_owner_recovery() {
        assert_exact_recorded_deposit(7, 1_000_000, 7, 999_000);
    }

    #[test]
    #[expected_failure(abort_code = E_UNEXPECTED_OBLIGATION_STATE)]
    fun an_unexpected_borrow_forces_owner_recovery() {
        assert_exact_recorded_shape(1, 1);
    }

    #[test]
    #[expected_failure(abort_code = E_UNEXPECTED_OBLIGATION_STATE)]
    fun reserve_substitution_forces_owner_recovery() {
        assert_exact_recorded_deposit(8, 999_000, 7, 999_000);
    }
}
