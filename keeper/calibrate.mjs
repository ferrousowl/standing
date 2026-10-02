// Measures what an executor really nets on each route, with real transactions and a zero tip.
// This is how ORDER_OVERHEAD and TX_OVERHEAD in StandingOrders.sol were calibrated.
//
//   arc-anvil --network arc --fork-url https://rpc.mainnet.arc.io     (in another terminal)
//   (cd ../contracts && arc-forge build) && node calibrate.mjs
import { createPublicClient, createWalletClient, http, parseAbi, encodeFunctionData, parseEther } from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import fs from "fs";
const RPC = "http://127.0.0.1:8545", USDC = "0x3600000000000000000000000000000000000000", EURC = "0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1", MCF = "0x522fAf9A91c41c443c66765030741e4AaCe147D0";
const art = JSON.parse(fs.readFileSync("../contracts/out/StandingOrders.sol/StandingOrders.json", "utf8"));
const chain = { id: 5042, name: "Arc", nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
const rpc = (method, params = []) => pub.request({ method, params });
const mk = async () => { const a = privateKeyToAccount(generatePrivateKey()); await rpc("anvil_setBalance", [a.address, "0x" + parseEther("100").toString(16)]); return createWalletClient({ account: a, chain, transport: http(RPC) }); };
const wait = h => pub.waitForTransactionReceipt({ hash: h });
const erc = parseAbi(["function approve(address,uint256) returns (bool)"]);
const mcf = parseAbi(["struct Call3 { address target; bool allowFailure; bytes callData; }", "struct Result { bool success; bytes returnData; }", "function aggregate3(Call3[] calls) returns (Result[])"]);

const dep = await mk(), merchant = await mk();
const r = await wait(await dep.deployContract({ abi: art.abi, bytecode: art.bytecode.object, args: [dep.account.address, 30, [USDC, EURC]] }));
const so = { address: r.contractAddress, abi: art.abi };
console.log("deployed", so.address, "gas", r.gasUsed);
await wait(await merchant.writeContract({ ...so, functionName: "createPlan", args: [USDC, 10_000000n, 3600, 0n, 500000n, "calib"] }));
const N = 21;
for (let i = 0; i < N; i++) {
  const p = await mk();
  await wait(await p.writeContract({ address: USDC, abi: erc, functionName: "approve", args: [so.address, 10n ** 12n] }));
  await wait(await p.writeContract({ ...so, functionName: "subscribe", args: [0n, "0x" + "00".repeat(32)] }));
}
await rpc("evm_increaseTime", [3601]); await rpc("evm_mine");

async function run(label, n, send) {
  const k = await mk();
  const before = await pub.getBalance({ address: k.account.address });
  const rc = await wait(await send(k));
  const after = await pub.getBalance({ address: k.account.address });
  const price = rc.effectiveGasPrice, base = (await pub.getBlock({ blockNumber: rc.blockNumber })).baseFeePerGas;
  const refundGas = Number((after - before + rc.gasUsed * price) / base);
  console.log(`${label}: status ${rc.status} gasUsed ${rc.gasUsed} refund(gas-eq) ${refundGas} => ${(100 * refundGas / Number(rc.gasUsed)).toFixed(1)}% of cost, net/order ${((refundGas - Number(rc.gasUsed)) / n).toFixed(0)} gas`);
}
const ids = Array.from({ length: N }, (_, i) => BigInt(i));
await run("single execute       ", 1, k => k.writeContract({ ...so, functionName: "execute", args: [ids[0]] }));
await run("executeBatch x1      ", 1, k => k.writeContract({ ...so, functionName: "executeBatch", args: [ids.slice(1, 2)] }));
await run("executeBatch x9      ", 9, k => k.writeContract({ ...so, functionName: "executeBatch", args: [ids.slice(2, 11)] }));
await run("Multicall3From loop x10", 10, k => k.writeContract({ address: MCF, abi: mcf, functionName: "aggregate3", args: [ids.slice(11, 21).map(id => ({ target: so.address, allowFailure: false, callData: encodeFunctionData({ abi: art.abi, functionName: "execute", args: [id] }) }))] }));
