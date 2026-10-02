// Settles due standing orders and collects the gas refund + tip.
//
//   PRIVATE_KEY=0x… STANDING=0x… npm run keeper
//
// Optional: RPC_URL (default Arc mainnet), INTERVAL seconds (default 60), BATCH (default 50),
// MIN_PROFIT in USDC per order (default 0) — only take orders whose fee beats gas by this much.
import { createPublicClient, createWalletClient, decodeFunctionResult, encodeFunctionData, http, parseAbi, parseUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const { PRIVATE_KEY, STANDING, RPC_URL = "https://rpc.mainnet.arc.io" } = process.env;
if (!PRIVATE_KEY || !STANDING) {
  console.error("Set PRIVATE_KEY and STANDING.");
  process.exit(1);
}
const INTERVAL = Number(process.env.INTERVAL ?? 60) * 1000;
const BATCH = BigInt(process.env.BATCH ?? 50);
const MIN_PROFIT = parseUnits(process.env.MIN_PROFIT ?? "0", 6);

const abi = parseAbi([
  "function orderCount() view returns (uint256)",
  "function executable(uint256 from, uint256 count, uint256 minExecFee) view returns (uint256[])",
  "function executeBatch(uint256[] orderIds) returns (uint256)",
]);

/** Rough gas per settled order, for deciding which orders are worth it. The contract refunds real usage. */
const GAS_PER_ORDER = 90_000n;

const transport = http(RPC_URL);
const account = privateKeyToAccount(PRIVATE_KEY);
const reader = createPublicClient({ transport });
const chain = { id: await reader.getChainId(), name: "Arc", nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, rpcUrls: { default: { http: [RPC_URL] } } };
const wallet = createWalletClient({ account, chain, transport });
const standing = { address: STANDING, abi };

const log = (...a) => console.log(new Date().toISOString(), ...a);
log(`keeper ${account.address} watching ${STANDING} on chain ${chain.id}`);

async function tick() {
  const total = await reader.readContract({ ...standing, functionName: "orderCount" });
  const { baseFeePerGas } = await reader.getBlock();
  // Gas is USDC with 18 decimals; fees are quoted with 6. Ask only for orders whose fee covers
  // our gas plus the margin we want — this is what filters out dust plans with a zero cap.
  const minFee = (GAS_PER_ORDER * baseFeePerGas) / 10n ** 12n + MIN_PROFIT;

  // A plain eth_call on Arc reports block.basefee as zero, which would make the contract quote
  // the tip alone and hide orders that are worth running. Giving the call a gas limit and a fee
  // makes the node evaluate it at the real base fee.
  const atBaseFee = { gas: 30_000_000n, maxFeePerGas: baseFeePerGas };
  const due = [];
  for (let from = 0n; from < total; from += 500n) {
    const call = { abi, functionName: "executable", args: [from, 500n, minFee] };
    const { data } = await reader.call({ to: STANDING, data: encodeFunctionData(call), ...atBaseFee });
    due.push(...decodeFunctionResult({ ...call, data }));
  }
  for (let i = 0; i < due.length; i += Number(BATCH)) {
    const ids = due.slice(i, i + Number(BATCH));
    // Simulate first: orders sharing one allowance can be listed together yet not all be payable.
    const { result: payable, request } = await reader.simulateContract({ ...standing, functionName: "executeBatch", args: [ids], account, maxFeePerGas: baseFeePerGas * 2n });
    if (payable === 0n) continue;
    const hash = await wallet.writeContract(request);
    const receipt = await reader.waitForTransactionReceipt({ hash });
    log(`settled ${payable}/${ids.length} order(s) [${ids.join(", ")}] ${receipt.status} ${hash}`);
  }
}

for (;;) {
  try {
    await tick();
  } catch (err) {
    log("error:", err.shortMessage ?? err.message);
  }
  await new Promise((r) => setTimeout(r, INTERVAL));
}
