# Standing

**Recurring USDC payments for [Arc](https://www.arc.io).** A merchant publishes a plan, a subscriber approves once, and from then on anyone can settle a payment when it falls due — and is refunded the gas, out of the payment itself.

No billing server, no keeper token, no price oracle, no custody.

- **App:** _added at deployment_
- **Contract (Arc mainnet, chain 5042):** _added at deployment_

## Why this is an Arc-native idea

Subscriptions on a blockchain need someone to submit the transaction that collects each payment. Paying that someone fairly is the hard part. On Ethereum-style chains the executor spends ETH to move USDC, so reimbursing it means trusting a price oracle, issuing a keeper token, or running the bot yourself.

On Arc, gas is paid in USDC. `gasUsed × block.basefee` is already a dollar amount. The contract takes that figure, converts it from the 18 decimals of native USDC to the 6 decimals of the ERC-20 interface (a fixed factor of 10¹²), and pays it to the executor out of the payment it just collected:

```solidity
uint256 costNative = gasUsed * block.basefee;                     // USDC, 18 decimals
fee += (costNative + NATIVE_TO_ERC20 - 1) / NATIVE_TO_ERC20;      // USDC, 6 decimals, rounded up
if (fee > p.maxExecFee) fee = p.maxExecFee;                        // merchant's cap
```

Measured with real transactions on a mainnet fork, settling a payment costs about 133,000 gas — roughly **$0.0027** at Arc's 20 gwei floor — and the refund comes to 100–107% of what the executor actually spent, whichever way it submits (`keeper/calibrate.mjs` reproduces the numbers). Arc's EWMA-smoothed fee market keeps that number predictable, which is what makes a fixed merchant-side cap workable.

Other Arc features the project leans on:

| Feature | How it is used |
| --- | --- |
| Native USDC with an ERC-20 interface | Pull payments use `transferFrom` on `0x3600…0000`; no wrapper token |
| `Multicall3From` (sender-preserving batch) | Approve + subscribe + first payment in **one** transaction, with the user's wallet as `msg.sender` for both calls |
| Deterministic sub-second finality | The UI treats one receipt as final; no confirmation counting |
| EURC | Plans can be priced in euros; executors earn a flat tip since there is no oracle-free gas conversion |

## How it works

```
merchant ── createPlan(token, amount, period, tip, cap) ──▶ plan #n   (terms are immutable)
payer    ── approve + subscribe(plan, ref) ──────────────▶ order #m  (first period paid now)

every period, anyone:
executor ── execute(order) ─▶ pull `amount` from payer
                              ├─ protocol fee (0.3%, hard-capped at 1%)
                              ├─ executor: gas refund + tip, never above the plan's cap
                              └─ merchant: the rest
```

Guarantees for the subscriber:

- The contract never holds subscriber funds. Money leaves the wallet only when a payment is due, and is paid out in the same transaction.
- A plan's price and period cannot change after it is published.
- **Missed periods never stack.** A payment collected more than a little late (a quarter of the period, at most three days) restarts the schedule from that moment, so every payment buys a full period and a wallet that was unreachable for months is charged once.
- **Paid time is never forfeited.** Cancelling, being cancelled by the merchant, or the plan closing leaves the current period valid, and resubscribing inside it costs nothing.
- Cancelling is one call, effective immediately. Revoking the token allowance works too.

For the merchant, one read answers "has this wallet paid?":

```solidity
function isCurrent(uint256 planId, address payer, uint32 grace) external view returns (bool);
```

## Repository

```
contracts/   StandingOrders.sol, Foundry tests (run against an Arc mainnet fork), deploy script
web/         Static front end — Vite, TypeScript, viem. No backend, no indexer.
keeper/      A small bot that settles due payments and collects the refunds, plus the calibration script
```

## Run it

**Contracts.** Needs [Arc Foundry](https://docs.arc.io/arc/tutorials/install-arc-foundry), which emulates Arc's native-USDC precompiles; stock Foundry cannot run these tests.

```sh
cd contracts
arc-forge test          # 39 tests, forks Arc mainnet over the public RPC
```

**Web.**

```sh
cd web
npm install
VITE_STANDING=0x… npm run dev      # contract address; RPC defaults to Arc mainnet
npm run build                      # static site in web/dist
```

**Keeper.**

```sh
cd keeper
npm install
PRIVATE_KEY=0x… STANDING=0x… npm run keeper
```

The bot asks `executable()` for due orders whose fee covers its gas, simulates the batch, and calls `executeBatch()`. A failing order inside a batch is skipped, not fatal.

## Design notes

- **Refund at `block.basefee`, not `tx.gasprice`.** An executor that overbids pays the difference itself, so it cannot inflate its own refund. There is a test for this.
- **Balance-delta check on every pull.** A token that skims transfers cannot be paid out from fees accrued by other plans. Tokens are allow-listed (USDC and EURC) in any case.
- **The per-transaction overhead is refunded once per transaction.** A transient-storage flag stops an executor from looping single calls to collect the 21,000 intrinsic gas many times over.
- **Batch isolation.** `executeBatch` runs each order in its own call frame, so one blocklisted merchant or empty wallet cannot stall a keeper. It reverts if too little gas remains for an order rather than skipping it silently, which keeps gas estimation honest.
- **Keepers choose what is worth their gas.** `executable()` takes a minimum fee, so plans with a zero cap cannot be used to bleed a bot.
- **Native and ERC-20 USDC are one balance.** The contract has no `receive()` and never reads `address(this).balance`; all accounting goes through the 6-decimal interface, as Arc's porting guide recommends.
- **Owner powers are narrow.** The owner can change the protocol fee (never above 1%), allow-list tokens, and withdraw accrued fees. It cannot touch plans, orders, or anyone's funds.

## Status

An early proof of concept. The contract has a test suite and went through one adversarial review pass, whose findings are fixed and kept as regression tests in `contracts/test/Review.t.sol`. **It has not been professionally audited.** Use small amounts.

Known limits: the owner can raise the protocol fee up to the 1% ceiling without notice; there is no pause switch (payers can always cancel or revoke); tokens sent to the contract by mistake cannot be recovered; and `executable()` checks each order's allowance separately, so orders sharing one allowance may all be listed when only some can pay.

Next: gasless subscribe via EIP-3009 signatures, plan trials and proration, webhooks for merchants, and a hosted keeper.

## License

MIT
