import {
  createPublicClient,
  defineChain,
  http,
  parseAbi,
  type Address,
  type PublicClient,
} from "viem";

const env = import.meta.env;

/** Arc mainnet. Gas is paid in USDC: 18 decimals natively, 6 through the ERC-20 interface. */
export const arc = defineChain({
  id: Number(env.VITE_CHAIN_ID ?? 5042),
  name: "Arc",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [env.VITE_RPC ?? "https://rpc.mainnet.arc.io"] } },
  blockExplorers: { default: { name: "Arc Explorer", url: "https://explorer.arc.io" } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

export const STANDING = (env.VITE_STANDING ?? "0x0000000000000000000000000000000000000000") as Address;
export const DEPLOYED = !/^0x0+$/.test(STANDING);

/** Arc's sender-preserving batcher: subcalls see the user's wallet as msg.sender. */
export const MULTICALL3_FROM: Address = "0x522fAf9A91c41c443c66765030741e4AaCe147D0";

export type Token = { address: Address; symbol: string; sign: string; native: boolean };
export const TOKENS: Token[] = [
  { address: "0x3600000000000000000000000000000000000000", symbol: "USDC", sign: "$", native: true },
  { address: "0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1", symbol: "EURC", sign: "€", native: false },
];
export const tokenOf = (a: Address): Token =>
  TOKENS.find((t) => t.address.toLowerCase() === a.toLowerCase()) ?? {
    address: a,
    symbol: "TOKEN",
    sign: "",
    native: false,
  };

export const standingAbi = parseAbi([
  "struct Plan { address merchant; address token; uint96 amount; uint32 period; uint96 keeperTip; uint96 maxExecFee; bool active; string name; }",
  "struct Order { uint64 planId; address payer; uint40 nextDue; uint40 startedAt; uint32 payments; bool active; }",
  "function createPlan(address token, uint96 amount, uint32 period, uint96 keeperTip, uint96 maxExecFee, string name) returns (uint256)",
  "function closePlan(uint256 planId)",
  "function subscribe(uint256 planId, bytes32 ref) returns (uint256)",
  "function cancel(uint256 orderId)",
  "function execute(uint256 orderId)",
  "function executeBatch(uint256[] orderIds) returns (uint256)",
  "function planCount() view returns (uint256)",
  "function orderCount() view returns (uint256)",
  "function feeBps() view returns (uint16)",
  "function getPlan(uint256 planId) view returns (Plan)",
  "function getOrder(uint256 orderId) view returns (Order)",
  "function plansOf(address merchant) view returns (uint256[])",
  "function ordersOf(address payer) view returns (uint256[])",
  "function ordersOfPlan(uint256 planId) view returns (uint256[])",
  "function isCurrent(uint256 planId, address payer, uint32 grace) view returns (bool)",
  "function liveOrderOf(uint256 planId, address payer) view returns (bool live, uint256 orderId)",
  "function paidUntil(uint256 planId, address payer) view returns (uint40)",
  "function executable(uint256 from, uint256 count, uint256 minExecFee) view returns (uint256[])",
  "function quoteExecFee(uint256 planId, uint256 gasUsed) view returns (uint256)",
  "event PlanCreated(uint256 indexed planId, address indexed merchant, address indexed token, uint256 amount, uint32 period, string name)",
  "error NotOwner()",
  "error NotAuthorized()",
  "error BadParams()",
  "error TokenNotAllowed()",
  "error PlanInactive()",
  "error OrderInactive()",
  "error AlreadySubscribed()",
  "error NotDue(uint40 nextDue)",
  "error PullFailed()",
  "error TransferFailed()",
  "error InsufficientGas()",
]);

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

export const multicallFromAbi = parseAbi([
  "struct Call3 { address target; bool allowFailure; bytes callData; }",
  "struct Result { bool success; bytes returnData; }",
  "function aggregate3(Call3[] calls) returns (Result[])",
]);

export const client: PublicClient = createPublicClient({
  chain: arc,
  transport: http(undefined, { batch: true }),
  batch: { multicall: true },
});

export type Plan = {
  id: bigint;
  merchant: Address;
  token: Address;
  amount: bigint;
  period: number;
  keeperTip: bigint;
  maxExecFee: bigint;
  active: boolean;
  name: string;
};
export type Order = {
  id: bigint;
  planId: bigint;
  payer: Address;
  nextDue: number;
  startedAt: number;
  payments: number;
  active: boolean;
};

const read = { address: STANDING, abi: standingAbi } as const;

export async function getPlans(ids: bigint[]): Promise<Plan[]> {
  const out = await Promise.all(ids.map((id) => client.readContract({ ...read, functionName: "getPlan", args: [id] })));
  return out.map((p, i) => ({ id: ids[i], ...p }));
}

export async function getOrders(ids: bigint[]): Promise<Order[]> {
  const out = await Promise.all(ids.map((id) => client.readContract({ ...read, functionName: "getOrder", args: [id] })));
  return out.map((o, i) => ({ id: ids[i], ...o }));
}

export const range = (n: bigint): bigint[] => Array.from({ length: Number(n) }, (_, i) => BigInt(i));
